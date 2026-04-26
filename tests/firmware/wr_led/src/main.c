/*
 * Phase 4-5 LED state machine — unit tests for the priority/pattern picker.
 *
 * wr_led_pick() is pure C with no Zephyr dependencies, so we link it
 * straight into a native_sim ztest binary and verify each priority case
 * + the heartbeat phase math by stepping a virtual tick counter.
 */

#include <zephyr/ztest.h>
#include "wr_led_pick.h"

/* Helpers */
#define ASSERT_RGB(rgb, R_, G_, B_) do { \
	zassert_equal((rgb).r, (R_), "r mismatch: got %d want %d", (int)(rgb).r, (int)(R_)); \
	zassert_equal((rgb).g, (G_), "g mismatch: got %d want %d", (int)(rgb).g, (int)(G_)); \
	zassert_equal((rgb).b, (B_), "b mismatch: got %d want %d", (int)(rgb).b, (int)(B_)); \
} while (0)

ZTEST_SUITE(wr_led_pick, NULL, NULL, NULL, NULL, NULL);

/* ========================================================================== */
/* Priority: warning patterns trump everything else                            */
/* ========================================================================== */

ZTEST(wr_led_pick, test_batt_crit_overrides_everything)
{
	/* tick=0 puts blink_250ms = (0 % 3) < 2 = true → red expected on. */
	struct wr_led_state s = {
		.batt_pct = 5,
		.recording = true,
		.ble_connected = true,
		.charging = true,
		.charged = true,
		.sd_full = true,
		.sd_missing = true,
	};
	struct wr_led_rgb out = wr_led_pick(s, 0);
	ASSERT_RGB(out, true, false, false);
}

ZTEST(wr_led_pick, test_batt_crit_blink_phase)
{
	struct wr_led_state s = { .batt_pct = 5 };
	/* blink_250ms = (tick % 3) < 2 → ticks 0,1 on; tick 2 off. */
	ASSERT_RGB(wr_led_pick(s, 0), true,  false, false);
	ASSERT_RGB(wr_led_pick(s, 1), true,  false, false);
	ASSERT_RGB(wr_led_pick(s, 2), false, false, false);
	ASSERT_RGB(wr_led_pick(s, 3), true,  false, false);
}

ZTEST(wr_led_pick, test_batt_low_orange)
{
	struct wr_led_state s = { .batt_pct = 20, .recording = true };
	/* blink_500ms = (tick % 5) < 3 → ticks 0,1,2 on. */
	struct wr_led_rgb out = wr_led_pick(s, 0);
	ASSERT_RGB(out, true, true, false);
	out = wr_led_pick(s, 4);
	ASSERT_RGB(out, false, false, false);
}

ZTEST(wr_led_pick, test_sd_full_red_solid)
{
	struct wr_led_state s = {
		.batt_pct = 50,
		.sd_full = true,
		.recording = true,
		.ble_connected = true,
	};
	struct wr_led_rgb out = wr_led_pick(s, 7);
	ASSERT_RGB(out, true, false, false);
}

ZTEST(wr_led_pick, test_sd_missing_blue_blink)
{
	struct wr_led_state s = { .batt_pct = 50, .sd_missing = true };
	/* blink_1s = (tick % 10) < 5 → ticks 0..4 on, 5..9 off. */
	ASSERT_RGB(wr_led_pick(s, 0), false, false, true);
	ASSERT_RGB(wr_led_pick(s, 5), false, false, false);
}

/* ========================================================================== */
/* Charging precedence                                                         */
/* ========================================================================== */

ZTEST(wr_led_pick, test_charged_solid_green)
{
	struct wr_led_state s = {
		.batt_pct = 100,
		.charged = true,
		.recording = true,
		.ble_connected = true,
	};
	ASSERT_RGB(wr_led_pick(s, 12345), false, true, false);
}

ZTEST(wr_led_pick, test_charging_yellow_heartbeat)
{
	struct wr_led_state s = { .batt_pct = 75, .charging = true };
	/* hb_on = (tick % 50) == 0 — only on at tick 0, 50, 100, ... */
	ASSERT_RGB(wr_led_pick(s, 0),  true,  true,  false);
	ASSERT_RGB(wr_led_pick(s, 1),  false, false, false);
	ASSERT_RGB(wr_led_pick(s, 50), true,  true,  false);
}

/* ========================================================================== */
/* Normal-state combinations                                                   */
/* ========================================================================== */

ZTEST(wr_led_pick, test_ble_only_green_hb)
{
	struct wr_led_state s = {
		.batt_pct = 80,
		.ble_connected = true,
		.recording = false,
	};
	ASSERT_RGB(wr_led_pick(s, 0),   false, true,  false);
	ASSERT_RGB(wr_led_pick(s, 25),  false, false, false);
	ASSERT_RGB(wr_led_pick(s, 50),  false, true,  false);
}

ZTEST(wr_led_pick, test_recording_only_white_hb)
{
	struct wr_led_state s = {
		.batt_pct = 80,
		.recording = true,
		.ble_connected = false,
	};
	ASSERT_RGB(wr_led_pick(s, 0),  true,  true,  true);
	ASSERT_RGB(wr_led_pick(s, 1),  false, false, false);
	ASSERT_RGB(wr_led_pick(s, 50), true,  true,  true);
}

ZTEST(wr_led_pick, test_ble_and_recording_alternates_per_5s)
{
	struct wr_led_state s = {
		.batt_pct = 80,
		.ble_connected = true,
		.recording = true,
	};
	/* tick / 50 toggles every 5 s. Even cycles → green HB, odd → white HB.
	 * hb_on only true at the start of each 5 s window. */

	/* Tick 0: cycle 0 (green HB), hb_on. */
	ASSERT_RGB(wr_led_pick(s, 0),  false, true,  false);

	/* Tick 50: cycle 1 (white HB), hb_on. */
	ASSERT_RGB(wr_led_pick(s, 50), true,  true,  true);

	/* Tick 100: cycle 2 = even (green HB), hb_on. */
	ASSERT_RGB(wr_led_pick(s, 100), false, true, false);

	/* Tick 25: still cycle 0, hb_on=false → all off. */
	ASSERT_RGB(wr_led_pick(s, 25), false, false, false);
}

ZTEST(wr_led_pick, test_idle_all_off)
{
	struct wr_led_state s = { .batt_pct = 80 };
	ASSERT_RGB(wr_led_pick(s, 0),    false, false, false);
	ASSERT_RGB(wr_led_pick(s, 999),  false, false, false);
}

/* ========================================================================== */
/* Boundary conditions on battery thresholds                                   */
/* ========================================================================== */

ZTEST(wr_led_pick, test_batt_6pct_is_low_not_crit)
{
	/* 6% > 5%, should fall through to BATT_LOW (orange). */
	struct wr_led_state s = { .batt_pct = 6 };
	struct wr_led_rgb out = wr_led_pick(s, 0);
	ASSERT_RGB(out, true, true, false);  /* orange = R+G */
}

ZTEST(wr_led_pick, test_batt_21pct_is_normal)
{
	/* 21% > 20%, no warning pattern. With no other state it's idle. */
	struct wr_led_state s = { .batt_pct = 21 };
	struct wr_led_rgb out = wr_led_pick(s, 0);
	ASSERT_RGB(out, false, false, false);
}
