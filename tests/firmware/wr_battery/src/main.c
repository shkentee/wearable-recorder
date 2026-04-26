/*
 * Unit tests for wr_battery pure ADC helpers.
 *
 * Hardware target: XIAO Sense (nRF52840), VBATT/2 divider → P0.31 →
 * SAADC (gain=1/4, Vref=0.6V, 12-bit).  All functions are pure C and
 * run on native_sim via Twister.
 */

#include <zephyr/ztest.h>
#include "wr_battery.h"

ZTEST_SUITE(wr_battery, NULL, NULL, NULL, NULL, NULL);

/* --- wr_battery_raw_to_mv ------------------------------------------------ */

ZTEST(wr_battery, test_raw_to_mv_zero)
{
	zassert_equal(wr_battery_raw_to_mv(0), 0, "raw=0 should give 0 mV");
}

ZTEST(wr_battery, test_raw_to_mv_negative_clamped)
{
	/* Negative SAADC readings can occur on ground-referenced inputs. */
	zassert_equal(wr_battery_raw_to_mv(-1), 0, "negative raw should give 0 mV");
}

ZTEST(wr_battery, test_raw_to_mv_fullscale)
{
	/* raw=4096 is just above the 12-bit range, but the formula gives 4800 mV.
	 * Actual max raw is 4095 → 4799 mV (within 1 mV of full scale). */
	uint16_t mv = wr_battery_raw_to_mv(4095);
	zassert_within(mv, 4800, 2, "raw=4095 should give ~4799 mV (got %u)", mv);
}

ZTEST(wr_battery, test_raw_to_mv_midpoint)
{
	/* raw=2048 → 2048*4800/4096 = 2400 mV */
	uint16_t mv = wr_battery_raw_to_mv(2048);
	zassert_equal(mv, 2400, "raw=2048 should give 2400 mV (got %u)", mv);
}

ZTEST(wr_battery, test_raw_to_mv_lipo_empty)
{
	/* raw=2560 → 2560*4800/4096 = 3000 mV (LiPo cutoff). */
	uint16_t mv = wr_battery_raw_to_mv(2560);
	zassert_equal(mv, 3000, "raw=2560 should give 3000 mV (got %u)", mv);
}

ZTEST(wr_battery, test_raw_to_mv_lipo_full)
{
	/* raw=3584 → 3584*4800/4096 = 4200 mV (LiPo charged). */
	uint16_t mv = wr_battery_raw_to_mv(3584);
	zassert_equal(mv, 4200, "raw=3584 should give 4200 mV (got %u)", mv);
}

/* --- wr_battery_mv_to_pct ------------------------------------------------ */

ZTEST(wr_battery, test_mv_to_pct_full)
{
	zassert_equal(wr_battery_mv_to_pct(4200), 100, "4200 mV should be 100%%");
}

ZTEST(wr_battery, test_mv_to_pct_empty)
{
	zassert_equal(wr_battery_mv_to_pct(3000), 0, "3000 mV should be 0%%");
}

ZTEST(wr_battery, test_mv_to_pct_mid)
{
	/* 3600 mV is exactly halfway between 3000 and 4200. */
	zassert_equal(wr_battery_mv_to_pct(3600), 50, "3600 mV should be 50%%");
}

ZTEST(wr_battery, test_mv_to_pct_clamp_over)
{
	zassert_equal(wr_battery_mv_to_pct(4300), 100, "overvoltage should clamp to 100%%");
	zassert_equal(wr_battery_mv_to_pct(5000), 100, "overvoltage should clamp to 100%%");
}

ZTEST(wr_battery, test_mv_to_pct_clamp_under)
{
	zassert_equal(wr_battery_mv_to_pct(2900), 0, "undervoltage should clamp to 0%%");
	zassert_equal(wr_battery_mv_to_pct(0),    0, "zero voltage should clamp to 0%%");
}

/* --- pipeline: raw → percent --------------------------------------------- */

ZTEST(wr_battery, test_pipeline_charged)
{
	/* raw=3584 → 4200 mV → 100% */
	zassert_equal(wr_battery_mv_to_pct(wr_battery_raw_to_mv(3584)), 100,
		      "pipeline: raw=3584 should give 100%%");
}

ZTEST(wr_battery, test_pipeline_empty)
{
	/* raw=2560 → 3000 mV → 0% */
	zassert_equal(wr_battery_mv_to_pct(wr_battery_raw_to_mv(2560)), 0,
		      "pipeline: raw=2560 should give 0%%");
}

ZTEST(wr_battery, test_pipeline_half)
{
	/* raw=3072 → 3600 mV → 50% */
	zassert_equal(wr_battery_mv_to_pct(wr_battery_raw_to_mv(3072)), 50,
		      "pipeline: raw=3072 should give 50%%");
}
