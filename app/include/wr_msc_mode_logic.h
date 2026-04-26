/*
 * Phase 4-4 USB MSC boot detect — pure helpers (no Zephyr deps).
 *
 * Split out so the sample-count → mode decision can be unit-tested
 * under native_sim without dragging in gpio_pin_get / k_msleep.
 *
 * The runtime side (wr_msc_mode.c) wraps this with the actual GPIO
 * sampling loop.
 *
 * Phase 6 additions (runtime mode decision):
 *   wr_msc_runtime_mode() and the should_xxx / led_hint_for helpers
 *   centralise the "what does the firmware do this boot?" branching so
 *   wr_chunk / wr_fifo (and any future caller) can short-circuit
 *   themselves without each re-deriving the rule. All pure, all ztest-
 *   covered under tests/firmware/wr_msc_mode/.
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

/* Runtime mode the firmware should operate in for this boot. */
typedef enum {
	WR_MSC_RUNTIME_RECORDING = 0, /* normal: PDM/codec/transport active */
	WR_MSC_RUNTIME_MSC,           /* USB MSC enabled, recording suppressed */
} wr_msc_runtime_mode_t;

/* Map the boot-time MSC flag (as produced by wr_msc_mode_decide() and
 * cached by wr_msc_mode.c) to a runtime mode. Kept as a function rather
 * than a macro so we can later layer in runtime-switch sources (e.g. a
 * BLE command, a long-press at runtime) without touching every call
 * site. */
wr_msc_runtime_mode_t wr_msc_runtime_mode(bool boot_msc_flag);

/* Sub-decisions, all pure: callers in wr_chunk.c / wr_fifo.c / future
 * transport gating use these so the policy lives in one place.
 *
 *   should_suppress_recording   — true in MSC mode (PDM / codec / SD
 *                                 writes must idle so the host owns
 *                                 the FAT volume).
 *   should_enable_usb_msc       — true in MSC mode (firmware must call
 *                                 usb_enable() with the MSC class).
 *   should_enable_chunk_rotation — true only in RECORDING mode.
 *   should_enable_fifo_pruning   — true only in RECORDING mode.
 */
bool wr_msc_should_suppress_recording(wr_msc_runtime_mode_t mode);
bool wr_msc_should_enable_usb_msc(wr_msc_runtime_mode_t mode);
bool wr_msc_should_enable_chunk_rotation(wr_msc_runtime_mode_t mode);
bool wr_msc_should_enable_fifo_pruning(wr_msc_runtime_mode_t mode);

/* LED hint for the chosen mode: in MSC we want a slow blue blink to
 * make it obvious the device isn't recording. any_warning is reserved
 * for future use (e.g. SD missing while MSC requested) and is always
 * false today. */
typedef struct {
	bool slow_blue_blink;
	bool any_warning;
} wr_msc_led_hint_t;

wr_msc_led_hint_t wr_msc_led_hint_for(wr_msc_runtime_mode_t mode);

#endif /* WR_MSC_MODE_LOGIC_H */
