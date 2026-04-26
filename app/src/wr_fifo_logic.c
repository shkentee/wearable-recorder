/*
 * Phase 4-3 FIFO auto-delete — pure helpers (no Zephyr deps).
 *
 * Compiled into both the firmware (linked into the omi app target) and
 * the host-side ztest binary under tests/firmware/wr_fifo/.
 */

#include "wr_fifo_logic.h"
#include <string.h>

bool wr_fifo_should_prune(uint64_t free_bytes, uint64_t total_bytes,
			  uint8_t threshold_pct)
{
	if (total_bytes == 0 || threshold_pct == 0) {
		return false;
	}
	/* free * 100 < total * threshold => free fraction < threshold. */
	return free_bytes * 100ULL < total_bytes * (uint64_t)threshold_pct;
}

bool wr_fifo_is_managed_chunk(const char *name, const char *active_name)
{
	if (name == NULL || name[0] == '\0') {
		return false;
	}
	if (active_name != NULL && strcmp(name, active_name) == 0) {
		return false;
	}
	/* Only chunk_*.opus files are ours to delete. */
	if (strncmp(name, "chunk_", 6) != 0) {
		return false;
	}
	return true;
}

int wr_fifo_compare_chunk(const char *a, const char *b)
{
	if (a == NULL && b == NULL) {
		return 0;
	}
	if (a == NULL) {
		return 1;
	}
	if (b == NULL) {
		return -1;
	}
	return strcmp(a, b);
}
