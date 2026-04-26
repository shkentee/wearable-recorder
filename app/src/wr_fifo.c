/*
 * Phase 4-3: FIFO auto-delete on the SD card.
 *
 * Once a minute we check free space on /SD: and, if it has dropped below
 * the threshold percent (D8 = 10%), unlink the oldest chunk_*.opus file
 * we can find. The currently-recording file (a01.txt) is never touched.
 *
 * Files we manage are produced by wr_chunk.c using the chunk_<NNNNN>.opus
 * naming convention; this module just deletes the lexicographically
 * smallest one each pass — that is good enough since wr_chunk.c emits
 * monotonically increasing sequence numbers.
 *
 * Future work (deferred along with wr_chunk.c full implementation):
 *   - delete by mtime instead of name once epoch-based naming lands
 *   - smarter: batch-delete to recover N chunks if catastrophically full
 */

#include <zephyr/fs/fs.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <string.h>

#include "wr_fifo_logic.h"
#include "wr_msc_mode_logic.h"

/* Owned by wr_msc_mode.c (no public header today — see Phase 6 plan). */
extern bool wr_msc_mode_is_active(void);

LOG_MODULE_REGISTER(wr_fifo, CONFIG_LOG_DEFAULT_LEVEL);

extern struct k_mutex write_sdcard_mutex;

#define WR_FIFO_DIR "/SD:/audio"
#define WR_FIFO_MOUNT "/SD:"
#define WR_FIFO_PERIOD_MS (60 * 1000)
#define WR_FIFO_THRESHOLD_PCT 10
#define WR_FIFO_ACTIVE_NAME "a01.txt"

static struct k_timer wr_fifo_timer;
static struct k_work wr_fifo_work;

/* Returns true and fills *oldest_name (max name_size bytes including '\0')
 * if any deletable chunk_*.opus is found. */
static bool wr_fifo_find_oldest(char *oldest_name, size_t name_size)
{
	struct fs_dir_t dir;
	fs_dir_t_init(&dir);
	if (fs_opendir(&dir, WR_FIFO_DIR) != 0) {
		return false;
	}

	bool found = false;
	struct fs_dirent ent;

	while (fs_readdir(&dir, &ent) == 0 && ent.name[0] != '\0') {
		if (ent.type == FS_DIR_ENTRY_DIR) {
			continue;
		}
		/* Skip the active recording file regardless of kind. */
		if (strcmp(ent.name, WR_FIFO_ACTIVE_NAME) == 0) {
			continue;
		}
		/* Phase 6: classify into LEGACY / UNSYNCED / EPOCH; UNKNOWN
		 * (foreign files) is skipped. Priority order ensures legacy
		 * chunk_*.opus is purged first, then unsynced pre-time-sync
		 * names, and only then real epoch-named chunks. */
		if (wr_fifo_classify(ent.name) == WR_FIFO_KIND_UNKNOWN) {
			continue;
		}
		if (!found || wr_fifo_compare_priority(ent.name, oldest_name) < 0) {
			strncpy(oldest_name, ent.name, name_size - 1);
			oldest_name[name_size - 1] = '\0';
			found = true;
		}
	}

	fs_closedir(&dir);
	return found;
}

static void wr_fifo_check(struct k_work *w)
{
	ARG_UNUSED(w);

	/* Phase 6: in USB MSC mode the host owns the FAT volume, so we
	 * must not unlink anything underneath it. Single source of truth
	 * lives in wr_msc_mode_logic. */
	if (!wr_msc_should_enable_fifo_pruning(
		    wr_msc_runtime_mode(wr_msc_mode_is_active()))) {
		LOG_INF("wr_fifo: MSC mode — pruning suppressed");
		return;
	}

	struct fs_statvfs stat;
	if (fs_statvfs(WR_FIFO_MOUNT, &stat) != 0) {
		LOG_WRN("wr_fifo: statvfs failed, skipping");
		return;
	}

	uint64_t total = (uint64_t)stat.f_blocks * stat.f_frsize;
	uint64_t free = (uint64_t)stat.f_bfree * stat.f_frsize;

	if (!wr_fifo_should_prune(free, total, WR_FIFO_THRESHOLD_PCT)) {
		return;
	}

	LOG_INF("wr_fifo: free %llu / %llu B (< %d%%), pruning oldest",
		(unsigned long long)free,
		(unsigned long long)total,
		WR_FIFO_THRESHOLD_PCT);

	char oldest[48];
	if (!wr_fifo_find_oldest(oldest, sizeof(oldest))) {
		LOG_WRN("wr_fifo: nothing to delete (no chunk_*.opus files)");
		return;
	}

	char full_path[64];
	snprintf(full_path, sizeof(full_path), "%s/%s", WR_FIFO_DIR, oldest);

	k_mutex_lock(&write_sdcard_mutex, K_FOREVER);
	int ret = fs_unlink(full_path);
	k_mutex_unlock(&write_sdcard_mutex);

	if (ret == 0) {
		LOG_INF("wr_fifo: deleted %s", full_path);
	} else {
		LOG_ERR("wr_fifo: fs_unlink %s failed (%d)", full_path, ret);
	}
}

static void wr_fifo_timer_handler(struct k_timer *t)
{
	ARG_UNUSED(t);
	k_work_submit(&wr_fifo_work);
}

static int wr_fifo_init(void)
{
	k_work_init(&wr_fifo_work, wr_fifo_check);
	k_timer_init(&wr_fifo_timer, wr_fifo_timer_handler, NULL);
	k_timer_start(&wr_fifo_timer,
		      K_MSEC(WR_FIFO_PERIOD_MS),
		      K_MSEC(WR_FIFO_PERIOD_MS));
	LOG_INF("wr_fifo: armed, period %d ms, threshold %d%%",
		WR_FIFO_PERIOD_MS, WR_FIFO_THRESHOLD_PCT);
	return 0;
}

SYS_INIT(wr_fifo_init, APPLICATION, 91);
