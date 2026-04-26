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
