/*
 * Phase 4-4 USB MSC boot detect — pure helpers (no Zephyr deps).
 *
 * Compiled into both the firmware (linked into the omi app target) and
 * the host-side ztest binary under tests/firmware/wr_msc_mode/.
 *
 * Phase 6: runtime mode decision (RECORDING vs MSC) and per-subsystem
 * gating predicates were added so wr_chunk / wr_fifo / LED status can
 * short-circuit consistently from a single source of truth.
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

wr_msc_runtime_mode_t wr_msc_runtime_mode(bool boot_msc_flag)
{
	return boot_msc_flag ? WR_MSC_RUNTIME_MSC : WR_MSC_RUNTIME_RECORDING;
}

bool wr_msc_should_suppress_recording(wr_msc_runtime_mode_t mode)
{
	return mode == WR_MSC_RUNTIME_MSC;
}

bool wr_msc_should_enable_usb_msc(wr_msc_runtime_mode_t mode)
{
	return mode == WR_MSC_RUNTIME_MSC;
}

bool wr_msc_should_enable_chunk_rotation(wr_msc_runtime_mode_t mode)
{
	return mode == WR_MSC_RUNTIME_RECORDING;
}

bool wr_msc_should_enable_fifo_pruning(wr_msc_runtime_mode_t mode)
{
	return mode == WR_MSC_RUNTIME_RECORDING;
}

wr_msc_led_hint_t wr_msc_led_hint_for(wr_msc_runtime_mode_t mode)
{
	wr_msc_led_hint_t hint = { false, false };

	if (mode == WR_MSC_RUNTIME_MSC) {
		hint.slow_blue_blink = true;
	}
	return hint;
}
