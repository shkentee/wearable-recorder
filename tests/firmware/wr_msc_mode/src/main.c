/*
 * Phase 4-6+ wr_msc_mode_logic — unit tests for the boot-button decision.
 */

#include <zephyr/ztest.h>
#include "wr_msc_mode_logic.h"

ZTEST_SUITE(wr_msc_mode_logic, NULL, NULL, NULL, NULL, NULL);

/* Production config: 100 samples × 10 ms = 1 s window, 80% threshold. */
#define PROD_TOTAL     100
#define PROD_THRESHOLD 80

ZTEST(wr_msc_mode_logic, test_held_above_threshold)
{
	zassert_true(wr_msc_mode_decide(95, PROD_TOTAL, PROD_THRESHOLD),
		     "95/100 highs at 80%% should enter MSC mode");
}

ZTEST(wr_msc_mode_logic, test_exactly_at_threshold)
{
	/* Predicate is >= so exactly threshold should pass. */
	zassert_true(wr_msc_mode_decide(80, PROD_TOTAL, PROD_THRESHOLD),
		     "80/100 highs at 80%% threshold should pass");
}

ZTEST(wr_msc_mode_logic, test_one_below_threshold)
{
	zassert_false(wr_msc_mode_decide(79, PROD_TOTAL, PROD_THRESHOLD),
		      "79/100 highs at 80%% threshold should fail");
}

ZTEST(wr_msc_mode_logic, test_button_never_pressed)
{
	zassert_false(wr_msc_mode_decide(0, PROD_TOTAL, PROD_THRESHOLD),
		      "0 highs → recording mode");
}

ZTEST(wr_msc_mode_logic, test_button_held_full_window)
{
	zassert_true(wr_msc_mode_decide(100, PROD_TOTAL, PROD_THRESHOLD),
		     "all highs → MSC mode");
}

ZTEST(wr_msc_mode_logic, test_zero_total_safe)
{
	/* GPIO never sampled — must not flip into MSC. */
	zassert_false(wr_msc_mode_decide(0, 0, 80),
		      "uninitialized total=0 → recording (no surprise MSC)");
	zassert_false(wr_msc_mode_decide(50, 0, 80),
		      "garbage high count with total=0 still recording");
}

ZTEST(wr_msc_mode_logic, test_negative_total_safe)
{
	zassert_false(wr_msc_mode_decide(50, -1, 80),
		      "negative total → recording");
}

ZTEST(wr_msc_mode_logic, test_zero_threshold_safe)
{
	/* threshold=0 would mean any sample wins — defensive disable. */
	zassert_false(wr_msc_mode_decide(0, 100, 0),
		      "threshold=0 disables MSC detection");
}

ZTEST(wr_msc_mode_logic, test_threshold_exceeds_total_safe)
{
	/* Misconfiguration: threshold > total can never be met. */
	zassert_false(wr_msc_mode_decide(50, 100, 200),
		      "threshold>total → impossible, recording");
}

ZTEST(wr_msc_mode_logic, test_negative_high_safe)
{
	zassert_false(wr_msc_mode_decide(-1, 100, 80),
		      "negative high count → recording");
}

/* ---------------------------------------------------------------------
 * Phase 6: runtime-mode decision + per-subsystem gating predicates.
 * ------------------------------------------------------------------ */

ZTEST(wr_msc_mode_logic, test_runtime_mode_flag_false_is_recording)
{
	zassert_equal(wr_msc_runtime_mode(false), WR_MSC_RUNTIME_RECORDING,
		      "boot flag false → RECORDING");
}

ZTEST(wr_msc_mode_logic, test_runtime_mode_flag_true_is_msc)
{
	zassert_equal(wr_msc_runtime_mode(true), WR_MSC_RUNTIME_MSC,
		      "boot flag true → MSC");
}

ZTEST(wr_msc_mode_logic, test_should_suppress_recording_msc)
{
	zassert_true(wr_msc_should_suppress_recording(WR_MSC_RUNTIME_MSC),
		     "MSC mode must suppress recording");
}

ZTEST(wr_msc_mode_logic, test_should_suppress_recording_recording)
{
	zassert_false(wr_msc_should_suppress_recording(WR_MSC_RUNTIME_RECORDING),
		      "RECORDING mode must not suppress recording");
}

ZTEST(wr_msc_mode_logic, test_should_enable_usb_msc_msc)
{
	zassert_true(wr_msc_should_enable_usb_msc(WR_MSC_RUNTIME_MSC),
		     "MSC mode must enable USB MSC class");
}

ZTEST(wr_msc_mode_logic, test_should_enable_usb_msc_recording)
{
	zassert_false(wr_msc_should_enable_usb_msc(WR_MSC_RUNTIME_RECORDING),
		      "RECORDING mode must not enable USB MSC class");
}

ZTEST(wr_msc_mode_logic, test_should_enable_chunk_rotation_recording)
{
	zassert_true(wr_msc_should_enable_chunk_rotation(WR_MSC_RUNTIME_RECORDING),
		     "RECORDING mode must allow wr_chunk rotation");
}

ZTEST(wr_msc_mode_logic, test_should_enable_chunk_rotation_msc)
{
	zassert_false(wr_msc_should_enable_chunk_rotation(WR_MSC_RUNTIME_MSC),
		      "MSC mode must suspend wr_chunk rotation");
}

ZTEST(wr_msc_mode_logic, test_should_enable_fifo_pruning_recording)
{
	zassert_true(wr_msc_should_enable_fifo_pruning(WR_MSC_RUNTIME_RECORDING),
		     "RECORDING mode must allow wr_fifo pruning");
}

ZTEST(wr_msc_mode_logic, test_should_enable_fifo_pruning_msc)
{
	zassert_false(wr_msc_should_enable_fifo_pruning(WR_MSC_RUNTIME_MSC),
		      "MSC mode must suspend wr_fifo pruning (host owns FAT)");
}

ZTEST(wr_msc_mode_logic, test_led_hint_msc_slow_blue)
{
	wr_msc_led_hint_t h = wr_msc_led_hint_for(WR_MSC_RUNTIME_MSC);

	zassert_true(h.slow_blue_blink, "MSC mode → slow blue blink");
	zassert_false(h.any_warning, "MSC mode → no warning today");
}

ZTEST(wr_msc_mode_logic, test_led_hint_recording_no_blink)
{
	wr_msc_led_hint_t h = wr_msc_led_hint_for(WR_MSC_RUNTIME_RECORDING);

	zassert_false(h.slow_blue_blink,
		      "RECORDING mode → no MSC-indicator blink");
	zassert_false(h.any_warning, "RECORDING mode → no warning today");
}

ZTEST(wr_msc_mode_logic, test_runtime_mode_round_trip_consistency)
{
	/* Composing wr_msc_runtime_mode() with the gating predicates must
	 * agree with calling them on the constant directly — guards against
	 * accidental swap of enum values. */
	wr_msc_runtime_mode_t rec  = wr_msc_runtime_mode(false);
	wr_msc_runtime_mode_t msc  = wr_msc_runtime_mode(true);

	zassert_false(wr_msc_should_suppress_recording(rec), NULL);
	zassert_true(wr_msc_should_suppress_recording(msc), NULL);
	zassert_true(wr_msc_should_enable_chunk_rotation(rec), NULL);
	zassert_false(wr_msc_should_enable_chunk_rotation(msc), NULL);
	zassert_true(wr_msc_should_enable_fifo_pruning(rec), NULL);
	zassert_false(wr_msc_should_enable_fifo_pruning(msc), NULL);
}
