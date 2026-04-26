/*
 * Phase 4-4 USB MSC boot detect — pure helpers (no Zephyr deps).
 *
 * Split out so the sample-count → mode decision can be unit-tested
 * under native_sim without dragging in gpio_pin_get / k_msleep.
 *
 * The runtime side (wr_msc_mode.c) wraps this with the actual GPIO
 * sampling loop.
 */

#ifndef WR_MSC_MODE_LOGIC_H
#define WR_MSC_MODE_LOGIC_H

#include <stdbool.h>

/* Decide whether the boot-time button hold qualifies for MSC mode.
 *
 * high_samples      — number of samples that read HIGH.
 * total_samples     — total samples taken in the boot detection window.
 * threshold_samples — minimum HIGH samples required to flip into MSC mode.
 *
 * Returns true iff total_samples > 0 AND threshold_samples <= total_samples
 * AND high_samples >= threshold_samples. Defensive against zero-window
 * (uninitialised) and impossible-threshold configurations.
 */
bool wr_msc_mode_decide(int high_samples, int total_samples,
			int threshold_samples);

#endif /* WR_MSC_MODE_LOGIC_H */
