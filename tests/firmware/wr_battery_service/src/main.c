/*
 * Unit tests for wr_battery_service helper logic.
 *
 * The GATT table, workqueue, and bt_gatt_notify() calls in
 * wr_battery_service.c all depend on the Zephyr BLE stack which is
 * not available on native_sim without heavy stubs.  We therefore test
 * the underlying pure-C helpers directly:
 *
 *   1. mV → percent conversion (wr_battery_mv_to_pct / wr_battery_raw_to_mv)
 *      — these are the values that the GATT READ handler returns.
 *
 *   2. "Notify on change" predicate — the service only calls
 *      bt_gatt_notify() when pct != last_pct.  We verify the comparison
 *      logic with a minimal inline simulation.
 *
 * Both test groups run on native_sim and need no ADC / BLE hardware.
 */

#include <zephyr/ztest.h>
#include "wr_battery.h"

/* ------------------------------------------------------------------ */
/* Stub: wr_led_status_get_batt_pct (replaces the real impl)          */
/* ------------------------------------------------------------------ */

static uint8_t stub_pct = 50;

uint8_t wr_led_status_get_batt_pct(void)
{
	return stub_pct;
}

/* ------------------------------------------------------------------ */
/* Test suite                                                          */
/* ------------------------------------------------------------------ */

ZTEST_SUITE(wr_battery_service, NULL, NULL, NULL, NULL, NULL);

/* --- mV → % values served by the GATT READ handler ---------------  */

ZTEST(wr_battery_service, test_read_full_charge)
{
	/* 4200 mV raw path: raw=3584 → 4200 mV → 100 % */
	uint8_t pct = wr_battery_mv_to_pct(wr_battery_raw_to_mv(3584));
	zassert_equal(pct, 100, "raw=3584 should give 100%% (got %u)", pct);
}

ZTEST(wr_battery_service, test_read_empty)
{
	/* 3000 mV raw path: raw=2560 → 3000 mV → 0 % */
	uint8_t pct = wr_battery_mv_to_pct(wr_battery_raw_to_mv(2560));
	zassert_equal(pct, 0, "raw=2560 should give 0%% (got %u)", pct);
}

ZTEST(wr_battery_service, test_read_midpoint)
{
	/* 3600 mV: raw=3072 → 3600 mV → 50 % */
	uint8_t pct = wr_battery_mv_to_pct(wr_battery_raw_to_mv(3072));
	zassert_equal(pct, 50, "raw=3072 should give 50%% (got %u)", pct);
}

/* --- stub getter --------------------------------------------------- */

ZTEST(wr_battery_service, test_stub_getter_default)
{
	stub_pct = 75;
	zassert_equal(wr_led_status_get_batt_pct(), 75,
		      "stub getter should return 75%%");
}

/* --- notify-on-change predicate ------------------------------------ */

/*
 * Inline simulation of the service update logic:
 *
 *   if (notify_enabled && pct != last_pct) { notify(); last_pct = pct; }
 *
 * We count how many times notify() would fire.
 */
static int notify_count;

static void simulate_update(uint8_t new_pct, uint8_t *last_pct,
			     bool notify_enabled)
{
	if (notify_enabled && new_pct != *last_pct) {
		notify_count++;
	}
	*last_pct = new_pct;
}

ZTEST(wr_battery_service, test_notify_fires_on_change)
{
	notify_count = 0;
	uint8_t last = 0xFF; /* sentinel initial value */

	simulate_update(80, &last, true);
	zassert_equal(notify_count, 1, "first update (sentinel→80) should notify");

	simulate_update(80, &last, true);
	zassert_equal(notify_count, 1, "same value should NOT re-notify");

	simulate_update(79, &last, true);
	zassert_equal(notify_count, 2, "value change 80→79 should notify");
}

ZTEST(wr_battery_service, test_notify_suppressed_when_disabled)
{
	notify_count = 0;
	uint8_t last = 50;

	simulate_update(60, &last, false); /* notifications off */
	zassert_equal(notify_count, 0,
		      "notify should be suppressed when not enabled");
	zassert_equal(last, 60, "last_pct should still be updated");
}

ZTEST(wr_battery_service, test_notify_boundary_clamp)
{
	/* Values outside [0,100] are clamped by wr_battery_mv_to_pct.
	 * Confirm the clamp so the GATT value is always a valid percent. */
	zassert_equal(wr_battery_mv_to_pct(5000), 100,
		      "overvoltage must clamp to 100%%");
	zassert_equal(wr_battery_mv_to_pct(2000), 0,
		      "undervoltage must clamp to 0%%");
}
