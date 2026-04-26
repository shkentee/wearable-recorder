/*
 * Phase 4-5 LED state machine — pure pattern picker (no Zephyr deps).
 *
 * Compiled into both the firmware (linked into the omi app target) and
 * the host-side ztest binary under tests/firmware/wr_led/.
 */

#include "wr_led_pick.h"

struct wr_led_rgb wr_led_pick(struct wr_led_state s, uint32_t tick)
{
	struct wr_led_rgb out = { false, false, false };

	const uint32_t hb_on        = (tick % 50) == 0;       /* 100 ms / 5 s */
	const bool     blink_500ms  = (tick % 5)  < 3;        /* ~60% duty */
	const bool     blink_250ms  = (tick % 3)  < 2;        /* faster */
	const bool     blink_1s     = (tick % 10) < 5;        /* 50% duty 1 s */
	const bool     ble_rec_white = ((tick / 50) & 1u) != 0;

	if (s.batt_pct <= 5) {
		out.r = blink_250ms;                          /* red fast */
	} else if (s.batt_pct <= 20) {
		out.r = blink_500ms;
		out.g = blink_500ms;                          /* orange */
	} else if (s.sd_full) {
		out.r = true;                                  /* red solid */
	} else if (s.sd_missing) {
		out.b = blink_1s;                              /* blue blink */
	} else if (s.charged) {
		out.g = true;                                  /* green solid */
	} else if (s.charging) {
		out.r = hb_on;
		out.g = hb_on;                                 /* yellow HB */
	} else if (s.ble_connected && s.recording) {
		if (ble_rec_white) {
			out.r = hb_on;
			out.g = hb_on;
			out.b = hb_on;                         /* white HB */
		} else {
			out.g = hb_on;                         /* green HB */
		}
	} else if (s.ble_connected) {
		out.g = hb_on;                                 /* green HB */
	} else if (s.recording) {
		out.r = hb_on;
		out.g = hb_on;
		out.b = hb_on;                                 /* white HB */
	}
	/* otherwise: idle, all off */

	return out;
}
