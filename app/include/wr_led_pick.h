/*
 * Phase 4-5 LED state machine — pure pattern picker.
 *
 * Split out so the priority-and-pattern logic can be unit-tested under
 * native_sim without dragging in GPIO / k_timer / `is_connected`.
 *
 * The runtime side (wr_led_status.c) gathers state into a wr_led_state
 * struct, calls wr_led_pick() to get the LED triplet for the current
 * tick, and then drives set_led_red/green/blue.
 */

#ifndef WR_LED_PICK_H
#define WR_LED_PICK_H

#include <stdbool.h>
#include <stdint.h>

struct wr_led_state {
	uint8_t batt_pct;       /* 0..100 */
	bool    sd_full;
	bool    sd_missing;
	bool    charged;        /* USB plugged + battery topped up */
	bool    charging;       /* USB plugged + still charging */
	bool    ble_connected;
	bool    recording;
};

struct wr_led_rgb {
	bool r;
	bool g;
	bool b;
};

/* Pure: determine which RGB triplet should be lit on this tick.
 *
 * tick is a monotonic counter in WR_LED_TICK_MS (100 ms) units. The
 * pattern engine derives heartbeat/blink phases from it, so callers can
 * step a virtual clock for tests.
 */
struct wr_led_rgb wr_led_pick(struct wr_led_state state, uint32_t tick);

#endif /* WR_LED_PICK_H */
