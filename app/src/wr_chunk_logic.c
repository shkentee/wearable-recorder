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
