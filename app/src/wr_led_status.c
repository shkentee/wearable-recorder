/*
 * Phase 4-5: LED state machine on top of omi's led.c.
 *
 * Pure pattern logic lives in wr_led_pick.c — this file is just the
 * Zephyr glue: a 100 ms timer that gathers state into a wr_led_state,
 * calls wr_led_pick() to get the desired RGB triplet, and drives omi's
 * set_led_red/green/blue.
 *
 * Heartbeat duty 1% (50 ms / 5 s) keeps platform-wide LED current under
 * +0.01 mA — see spec §11.2 / §14.2.
 *
 * Inputs we read today:
 *   - is_connected (BLE) from transport.c
 *   - test-hook setters for battery / SD / charging
 *
 * Inputs deferred (TODO): battery ADC, SD-state probing, USB-charging
 * detection. Until those land the warning patterns can be exercised by
 * setting the static flags via wr_led_status_set_*().
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdbool.h>

#include "wr_led_pick.h"

LOG_MODULE_REGISTER(wr_led_status, CONFIG_LOG_DEFAULT_LEVEL);

/* omi's led.c API */
void set_led_red(bool on);
void set_led_green(bool on);
void set_led_blue(bool on);

/* From transport.c — true while a Central is connected. */
extern bool is_connected;

#define WR_LED_TICK_MS 100

/* Inputs (external setters can plug into these as more signals come online). */
static volatile bool wr_led_recording = true;       /* always-on for MVP */
static volatile bool wr_led_charging  = false;
static volatile bool wr_led_charged   = false;
static volatile bool wr_led_sd_full   = false;
static volatile bool wr_led_sd_missing = false;
static volatile uint8_t wr_led_batt_pct = 100;

/* Public test hooks. */
void wr_led_status_set_charging(bool on)    { wr_led_charging = on;  wr_led_charged = false; }
void wr_led_status_set_charged(bool on)     { wr_led_charged = on;   wr_led_charging = false; }
void wr_led_status_set_sd_full(bool on)     { wr_led_sd_full = on; }
void wr_led_status_set_sd_missing(bool on)  { wr_led_sd_missing = on; }
void wr_led_status_set_batt_pct(uint8_t p)  { wr_led_batt_pct = p; }

static void wr_led_tick(struct k_timer *t)
{
	ARG_UNUSED(t);

	static uint32_t tick;          /* 100 ms units */
	tick++;

	struct wr_led_state s = {
		.batt_pct      = wr_led_batt_pct,
		.sd_full       = wr_led_sd_full,
		.sd_missing    = wr_led_sd_missing,
		.charged       = wr_led_charged,
		.charging      = wr_led_charging,
		.ble_connected = is_connected,
		.recording     = wr_led_recording,
	};

	struct wr_led_rgb out = wr_led_pick(s, tick);
	set_led_red(out.r);
	set_led_green(out.g);
	set_led_blue(out.b);
}

static struct k_timer wr_led_timer;

static int wr_led_status_init(void)
{
	k_timer_init(&wr_led_timer, wr_led_tick, NULL);
	/* Hold off the first tick by 2 s so omi's main() has a chance to
	 * call led_start() (which configures the GPIOs). Without the
	 * delay our first set_led_red() etc fire against an un-configured
	 * port and silently no-op, leaving the LEDs in an undefined state
	 * until the next full cycle. */
	k_timer_start(&wr_led_timer,
		      K_MSEC(2000),
		      K_MSEC(WR_LED_TICK_MS));
	LOG_INF("wr_led_status: armed (first tick in 2 s, period %d ms)",
		WR_LED_TICK_MS);
	return 0;
}

/* SYS_INIT runs before main(); the timer's initial delay handles the
 * race against omi's led_start(). */
SYS_INIT(wr_led_status_init, APPLICATION, 95);
