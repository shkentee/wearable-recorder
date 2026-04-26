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

/* Format <unix_secs>.opus into buf as a 10-digit zero-padded decimal,
 * e.g. /SD:/audio/0000001234.opus. Wraps at 1e10 (~year 2286), which
 * is out of scope for this device. Returns strlen on success, or -1 on
 * NULL/zero buf or buffer-too-small.
 */
int wr_chunk_format_epoch_name(uint64_t unix_secs, char *buf, size_t buf_size);

/* Derive a per-boot ID from the boot-time cycle counter and a hwrng
 * sample. Cheap, doesn't have to be cryptographically random — it just
 * needs to make pre-time-sync chunks from successive boots distinct on
 * disk. Returns 0 only when both inputs are 0 (caller may treat that
 * as "regenerate").
 */
uint32_t wr_chunk_make_boot_id(uint64_t cycles_since_boot, uint32_t hwrng_value);

/* Format unsynced_<bootid8hex>_<seq5>.opus, e.g.
 * /SD:/audio/unsynced_0a1b2c3d_00042.opus. seq is taken mod 100000
 * to keep the field at 5 digits. Returns strlen on success, or -1 on
 * NULL/zero buf or buffer-too-small.
 */
int wr_chunk_format_unsynced_name(uint32_t boot_id, uint32_t seq,
				  char *buf, size_t buf_size);

/* Size-based rotation gate: true when current_file_size has reached
 * threshold_bytes. threshold_bytes == 0 disables the feature (returns
 * false) so callers can safely pass a runtime-disabled threshold.
 */
bool wr_chunk_should_rotate_size(uint64_t current_file_size,
				 uint64_t threshold_bytes);

#endif /* WR_CHUNK_LOGIC_H */
