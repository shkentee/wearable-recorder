/*
 * D7 (Phase 6): file rotation with epoch/unsynced filename at runtime.
 *
 * Rotation triggers (whichever fires first):
 *   - 10-minute periodic timer
 *   - active file size reaches WR_CHUNK_SIZE_LIMIT_BYTES (2 MB)
 *
 * On trigger we lock omi's write_sdcard_mutex, fs_rename a01.txt to
 * the appropriate target name, and recreate an empty a01.txt so omi
 * can keep appending without changes.
 *
 * Filename selection (D7):
 *   - Before wr_chunk_set_sync_time() is called:
 *       unsynced_<bootid8hex>_<seq5>.opus
 *     where boot_id is generated once at init from k_cycle_get_32()
 *     XOR sys_rand32_get() via wr_chunk_make_boot_id().
 *   - After wr_chunk_set_sync_time(unix_secs) is called:
 *       <unix_secs + elapsed_since_sync>.opus  (10-digit zero-padded)
 */

#include <zephyr/fs/fs.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/random/random.h>
#include <stdio.h>
#include <stdint.h>

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

/* D7: time-sync state.
 *
 * sync_time_secs    — Unix epoch value received via wr_chunk_set_sync_time().
 * sync_uptime_ms    — k_uptime_get() at the moment sync was received; used to
 *                     compute elapsed time for subsequent chunks.
 * is_synced         — true once wr_chunk_set_sync_time() has been called.
 * boot_id           — derived once at init; distinguishes pre-sync files from
 *                     successive boots.
 */
static struct {
	uint64_t sync_time_secs;
	int64_t  sync_uptime_ms;
	bool     is_synced;
	uint32_t boot_id;
} wr_chunk_sync;

/*
 * Called by wr_time_sync.c's GATT write handler when the phone sends the
 * current Unix epoch over BLE.  Stores the value so that the next
 * wr_chunk_rotate() call can name the file with the correct timestamp.
 */
void wr_chunk_set_sync_time(uint64_t unix_secs)
{
	wr_chunk_sync.sync_time_secs = unix_secs;
	wr_chunk_sync.sync_uptime_ms = k_uptime_get();
	wr_chunk_sync.is_synced      = true;
	LOG_INF("wr_chunk: time synced to %" PRIu64 " s", unix_secs);
}

/* Build the target filename for the chunk that is about to be rotated. */
static int wr_chunk_build_target(char *buf, size_t buf_size)
{
	if (wr_chunk_sync.is_synced) {
		int64_t elapsed_ms = k_uptime_get() - wr_chunk_sync.sync_uptime_ms;
		uint64_t elapsed_s = (uint64_t)(elapsed_ms / 1000);
		uint64_t epoch = wr_chunk_sync.sync_time_secs + elapsed_s;
		return wr_chunk_format_epoch_name(epoch, buf, buf_size);
	} else {
		return wr_chunk_format_unsynced_name(wr_chunk_sync.boot_id,
						     wr_chunk_seq, buf, buf_size);
	}
}

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

	/* Build the target filename using epoch or unsynced naming (D7).
	 * For unsynced names we probe forward on collision; epoch names
	 * use the current timestamp so collision is very unlikely, but we
	 * also probe to be safe. */
	char target[64];
	int ret;
	struct fs_dirent dirent;

	for (int attempt = 0; attempt < 1000; attempt++) {
		int n = wr_chunk_build_target(target, sizeof(target));
		if (n < 0) {
			LOG_ERR("wr_chunk: failed to build target name");
			return;
		}
		if (fs_stat(target, &dirent) != 0) {
			break;
		}
		/* Collision: advance seq so unsynced names step forward;
		 * epoch names are time-based so a 1-second nudge is fine. */
		wr_chunk_seq++;
		if (wr_chunk_sync.is_synced) {
			wr_chunk_sync.sync_time_secs++;
		}
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
	/* D7: generate a per-boot ID so pre-sync chunks are distinct across
	 * reboots.  k_cycle_get_32() diverges quickly between boots; the
	 * hwrng sample adds entropy even when the cycle counter is 0. */
	uint32_t boot_id = wr_chunk_make_boot_id(
		(uint64_t)k_cycle_get_32(), sys_rand32_get());
	if (boot_id == 0) {
		/* Both inputs were 0 — extremely unlikely; use a fixed canary
		 * so the filename is still non-zero. */
		boot_id = 0xDEADC0DEU;
	}
	wr_chunk_sync.boot_id = boot_id;
	LOG_INF("wr_chunk: boot_id = %08x", boot_id);

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
