/*
 * Phase 4-2 MVP: file rotation on top of omi's single-file SD design
 * (which writes everything to /SD:/audio/a01.txt).
 *
 * Rotation triggers (whichever fires first):
 *   - 10-minute periodic timer
 *   - active file size reaches WR_CHUNK_SIZE_LIMIT_BYTES (2 MB)
 *
 * On trigger we lock omi's write_sdcard_mutex, fs_rename a01.txt to
 * chunk_<seq>.opus, and recreate an empty a01.txt so omi can keep
 * appending without changes.
 *
 * Not implemented yet (deferred along with proper BLE storage sync
 * redesign):
 *   - UNIX_epoch.opus naming (needs RTC time-sync awareness)
 *   - unsynced_<bootid>_<seq>.opus fallback when not yet time-synced
 *   - persistent boot ID
 * The pure helpers for these already live in wr_chunk_logic.{c,h} and
 * have ztest coverage.
 */

#include <zephyr/fs/fs.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdio.h>

#include "wr_chunk_logic.h"
#include "wr_msc_mode_logic.h"

/* Owned by wr_msc_mode.c (no public header today — see Phase 6 plan). */
extern bool wr_msc_mode_is_active(void);

LOG_MODULE_REGISTER(wr_chunk, CONFIG_LOG_DEFAULT_LEVEL);

/* Mutex shared with transport.c's write_to_storage(). */
extern struct k_mutex write_sdcard_mutex;

#define WR_CHUNK_PERIOD_MS         (10 * 60 * 1000)
#define WR_CHUNK_SIZE_POLL_MS      (30 * 1000) /* sample size every 30 s */
#define WR_CHUNK_ACTIVE_PATH       "/SD:/audio/a01.txt"
#define WR_CHUNK_SIZE_LIMIT_BYTES  (2ULL * 1024ULL * 1024ULL) /* 2 MB */

static struct k_timer wr_chunk_timer;
static struct k_timer wr_chunk_size_timer;
static struct k_work  wr_chunk_work;
static struct k_work  wr_chunk_size_check_work;
static uint32_t       wr_chunk_seq;

static void wr_chunk_rotate(struct k_work *w)
{
	ARG_UNUSED(w);

	/* Phase 6: in USB MSC mode the host owns the FAT volume, so any
	 * fs_rename / fs_open from us would race the mass-storage stack.
	 * Centralised decision lives in wr_msc_mode_logic so wr_fifo /
	 * future gates stay consistent. */
	if (!wr_msc_should_enable_chunk_rotation(
		    wr_msc_runtime_mode(wr_msc_mode_is_active()))) {
		LOG_INF("wr_chunk: MSC mode — rotation suppressed");
		return;
	}

	/* Find a name that doesn't collide. We don't track the last seq
	 * across reboots yet; just probe forward. */
	char target[48];
	int ret;
	struct fs_dirent dirent;

	for (int attempt = 0; attempt < 1000; attempt++) {
		(void)wr_chunk_format_name(wr_chunk_seq, target, sizeof(target));
		if (fs_stat(target, &dirent) != 0) {
			break;
		}
		wr_chunk_seq++;
	}

	k_mutex_lock(&write_sdcard_mutex, K_FOREVER);

	ret = fs_stat(WR_CHUNK_ACTIVE_PATH, &dirent);
	if (!wr_chunk_should_rotate(ret, dirent.size)) {
		LOG_INF("wr_chunk: skip rotation (active file missing or empty)");
		goto unlock;
	}

	if (wr_chunk_should_rotate_size(dirent.size, WR_CHUNK_SIZE_LIMIT_BYTES)) {
		LOG_INF("wr_chunk: size threshold %llu B reached (file=%llu B)",
			(unsigned long long)WR_CHUNK_SIZE_LIMIT_BYTES,
			(unsigned long long)dirent.size);
	}

	ret = fs_rename(WR_CHUNK_ACTIVE_PATH, target);
	if (ret != 0) {
		LOG_ERR("wr_chunk: fs_rename %s -> %s failed (%d)",
			WR_CHUNK_ACTIVE_PATH, target, ret);
		goto unlock;
	}

	/* Recreate an empty a01.txt so the next omi append succeeds. */
	struct fs_file_t f;
	fs_file_t_init(&f);
	ret = fs_open(&f, WR_CHUNK_ACTIVE_PATH, FS_O_WRITE | FS_O_CREATE);
	if (ret == 0) {
		fs_close(&f);
		LOG_INF("wr_chunk: rotated to %s, fresh a01.txt opened",
			target);
		wr_chunk_seq++;
	} else {
		LOG_ERR("wr_chunk: failed to recreate %s (%d)",
			WR_CHUNK_ACTIVE_PATH, ret);
	}

unlock:
	k_mutex_unlock(&write_sdcard_mutex);
}

/* Periodically inspect the active file's size and submit the rotate
 * work item when the size threshold is reached. Runs off-ISR so we can
 * safely call fs_stat. */
static void wr_chunk_size_check(struct k_work *w)
{
	ARG_UNUSED(w);

	struct fs_dirent dirent;
	int ret = fs_stat(WR_CHUNK_ACTIVE_PATH, &dirent);

	if (ret == 0 &&
	    wr_chunk_should_rotate_size(dirent.size, WR_CHUNK_SIZE_LIMIT_BYTES)) {
		k_work_submit(&wr_chunk_work);
	}
}

static void wr_chunk_timer_handler(struct k_timer *t)
{
	ARG_UNUSED(t);
	k_work_submit(&wr_chunk_work);
}

static void wr_chunk_size_timer_handler(struct k_timer *t)
{
	ARG_UNUSED(t);
	k_work_submit(&wr_chunk_size_check_work);
}

static int wr_chunk_init(void)
{
	k_work_init(&wr_chunk_work, wr_chunk_rotate);
	k_work_init(&wr_chunk_size_check_work, wr_chunk_size_check);

	k_timer_init(&wr_chunk_timer, wr_chunk_timer_handler, NULL);
	k_timer_start(&wr_chunk_timer,
		      K_MSEC(WR_CHUNK_PERIOD_MS),
		      K_MSEC(WR_CHUNK_PERIOD_MS));

	k_timer_init(&wr_chunk_size_timer, wr_chunk_size_timer_handler, NULL);
	k_timer_start(&wr_chunk_size_timer,
		      K_MSEC(WR_CHUNK_SIZE_POLL_MS),
		      K_MSEC(WR_CHUNK_SIZE_POLL_MS));

	LOG_INF("wr_chunk: armed, period %d ms, size limit %llu B (poll %d ms)",
		WR_CHUNK_PERIOD_MS,
		(unsigned long long)WR_CHUNK_SIZE_LIMIT_BYTES,
		WR_CHUNK_SIZE_POLL_MS);
	return 0;
}

SYS_INIT(wr_chunk_init, APPLICATION, 90);
