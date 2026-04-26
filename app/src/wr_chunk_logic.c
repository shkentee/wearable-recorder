/*
 * Phase 4-2 chunk rotation — pure helpers (no Zephyr deps).
 *
 * Compiled into both the firmware (linked into the omi app target) and
 * the host-side ztest binary under tests/firmware/wr_chunk/.
 */

#include "wr_chunk_logic.h"
#include <stdio.h>

#define WR_CHUNK_DIR "/SD:/audio"

int wr_chunk_format_name(uint32_t seq, char *buf, size_t buf_size)
{
	if (buf == NULL || buf_size == 0) {
		return -1;
	}

	/* Cap at 5 digits so the formatted name always fits in our 48 B
	 * runtime buffer; the wraparound after 100k chunks is fine because
	 * the runtime probes for collisions. */
	int n = snprintf(buf, buf_size, WR_CHUNK_DIR "/chunk_%05u.opus",
			 (unsigned)(seq % 100000U));
	if (n < 0 || (size_t)n >= buf_size) {
		return -1;
	}
	return n;
}

bool wr_chunk_should_rotate(int stat_ret, uint64_t file_size)
{
	return stat_ret == 0 && file_size > 0;
}

int wr_chunk_format_epoch_name(uint64_t unix_secs, char *buf, size_t buf_size)
{
	if (buf == NULL || buf_size == 0) {
		return -1;
	}

	/* 10 digits covers up to 9999999999 (~year 2286); wrap silently. */
	uint64_t secs = unix_secs % 10000000000ULL;
	int n = snprintf(buf, buf_size, WR_CHUNK_DIR "/%010llu.opus",
			 (unsigned long long)secs);
	if (n < 0 || (size_t)n >= buf_size) {
		return -1;
	}
	return n;
}

uint32_t wr_chunk_make_boot_id(uint64_t cycles_since_boot, uint32_t hwrng_value)
{
	/* Cheap mix: shifted cycle counter XOR hwrng. Both-zero stays 0. */
	return (uint32_t)(cycles_since_boot >> 16) ^ hwrng_value;
}

int wr_chunk_format_unsynced_name(uint32_t boot_id, uint32_t seq,
				  char *buf, size_t buf_size)
{
	if (buf == NULL || buf_size == 0) {
		return -1;
	}

	int n = snprintf(buf, buf_size,
			 WR_CHUNK_DIR "/unsynced_%08x_%05u.opus",
			 (unsigned)boot_id, (unsigned)(seq % 100000U));
	if (n < 0 || (size_t)n >= buf_size) {
		return -1;
	}
	return n;
}

bool wr_chunk_should_rotate_size(uint64_t current_file_size,
				 uint64_t threshold_bytes)
{
	if (threshold_bytes == 0) {
		return false;
	}
	return current_file_size >= threshold_bytes;
}
