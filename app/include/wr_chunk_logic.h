/*
 * Phase 4-2 chunk rotation — pure helpers (no Zephyr deps).
 *
 * Split out so the formatting + rotation-gate logic can be unit-tested
 * under native_sim without dragging in fs_*, k_timer, or k_work.
 *
 * The runtime side (wr_chunk.c) wraps these with the actual fs_* calls
 * and SD-mutex handling.
 */

#ifndef WR_CHUNK_LOGIC_H
#define WR_CHUNK_LOGIC_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/* Format chunk_NNNNN.opus into buf. Returns the strlen of the formatted
 * name (excluding NUL), or -1 if buf_size is too small. seq is taken
 * mod 100000 so the field always fits in 5 digits.
 */
int wr_chunk_format_name(uint32_t seq, char *buf, size_t buf_size);

/* Decide whether the active recording file is worth rotating.
 *
 * stat_ret  — return code of fs_stat() on the active file (0 == found).
 * file_size — bytes reported by fs_stat() (only meaningful when found).
 *
 * Returns true only when the file exists AND has data. This matches
 * the omi behavior where the file is recreated empty after each
 * rotation, and we want to skip no-op rotations on idle periods.
 */
bool wr_chunk_should_rotate(int stat_ret, uint64_t file_size);

#endif /* WR_CHUNK_LOGIC_H */
