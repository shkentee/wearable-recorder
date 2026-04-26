/*
 * Phase 4-4 USB MSC boot detect — pure helpers (no Zephyr deps).
 *
 * Compiled into both the firmware (linked into the omi app target) and
 * the host-side ztest binary under tests/firmware/wr_msc_mode/.
 */

#include "wr_msc_mode_logic.h"

bool wr_msc_mode_decide(int high_samples, int total_samples,
			int threshold_samples)
{
	if (total_samples <= 0) {
		return false;
	}
	if (threshold_samples <= 0 || threshold_samples > total_samples) {
		return false;
	}
	if (high_samples < 0) {
		return false;
	}
	return high_samples >= threshold_samples;
}
