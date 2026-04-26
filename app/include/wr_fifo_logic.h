/*
 * Phase 4-3 FIFO auto-delete — pure helpers (no Zephyr deps).
 *
 * Split out so the prune-trigger predicate, the file-name filter, and
 * the "is one name older than another" comparison can be unit-tested
 * under native_sim without dragging in fs_*, statvfs, or k_timer.
 *
 * The runtime side (wr_fifo.c) wraps these with the actual fs_ / statvfs
 * calls and SD-mutex handling.
 */

#ifndef WR_FIFO_LOGIC_H
#define WR_FIFO_LOGIC_H

#include <stdbool.h>
#include <stdint.h>

/* Decide whether to prune based on free / total bytes and threshold.
 *
 * Returns true when free * 100 < total * threshold_pct, i.e. free
 * fraction has dropped below threshold_pct. Any zero input returns
 * false (no division-by-zero, no surprise prune on a fresh card).
 */
bool wr_fifo_should_prune(uint64_t free_bytes, uint64_t total_bytes,
			  uint8_t threshold_pct);

/* Returns true if the directory entry is a chunk we manage and is safe
 * to delete (i.e. not the active-recording file).
 *
 * name        — the readdir entry name (just the basename).
 * active_name — the active-recording file name to skip (e.g. "a01.txt").
 */
bool wr_fifo_is_managed_chunk(const char *name, const char *active_name);

/* Returns negative if a is "older" (lex-smaller) than b, positive if
 * "newer", zero if equal. With wr_chunk.c emitting monotonically
 * increasing chunk_NNNNN.opus the lex ordering matches creation order.
 */
int wr_fifo_compare_chunk(const char *a, const char *b);

#endif /* WR_FIFO_LOGIC_H */
