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

/* Helper: returns true if s consists of exactly n decimal digits
 * (no sign, no leading whitespace). Used to detect epoch-style names.
 */
static bool wr_fifo_all_digits(const char *s, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		char c = s[i];
		if (c < '0' || c > '9') {
			return false;
		}
	}
	return true;
}

wr_fifo_kind_t wr_fifo_classify(const char *name)
{
	if (name == NULL || name[0] == '\0') {
		return WR_FIFO_KIND_UNKNOWN;
	}

	size_t len = strlen(name);

	/* LEGACY: chunk_*.opus from Phase 4-2 sequential naming. */
	if (strncmp(name, "chunk_", 6) == 0) {
		return WR_FIFO_KIND_LEGACY;
	}

	/* UNSYNCED: unsynced_<bootid8hex>_<seq5>.opus pre-time-sync names. */
	if (strncmp(name, "unsynced_", 9) == 0) {
		return WR_FIFO_KIND_UNSYNCED;
	}

	/* EPOCH: exactly 10 decimal digits followed by ".opus". */
	const char *suffix = ".opus";
	const size_t suffix_len = 5;
	const size_t epoch_digits = 10;
	if (len == epoch_digits + suffix_len &&
	    wr_fifo_all_digits(name, epoch_digits) &&
	    strcmp(name + epoch_digits, suffix) == 0) {
		return WR_FIFO_KIND_EPOCH;
	}

	return WR_FIFO_KIND_UNKNOWN;
}

int wr_fifo_compare_priority(const char *a, const char *b)
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

	wr_fifo_kind_t ka = wr_fifo_classify(a);
	wr_fifo_kind_t kb = wr_fifo_classify(b);

	if (ka != kb) {
		/* Lower kind value = older / higher delete priority.
		 * LEGACY (1) < UNSYNCED (2) < EPOCH (3). UNKNOWN (0)
		 * sorts before everything but should be filtered out by
		 * the caller via wr_fifo_classify before we get here. */
		return (int)ka - (int)kb;
	}

	return strcmp(a, b);
}
