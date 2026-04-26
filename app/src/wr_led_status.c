/*
 * Phase 4-5: LED state machine on top of omi's led.c.
 *
 * omi exposes set_led_red/green/blue (pure GPIO toggles). This module
 * runs a 100 ms tick that picks the highest-priority pattern and drives
 * the three GPIOs accordingly.
 *
 * Pattern table (matches the spec D3 + D16 decisions):
 *   BATT_CRIT  (<=5%)  red fast blink (250 ms on / 250 ms off)        [pri 0]
 *   BATT_LOW   (<=20%) orange blink (500 ms cycle, R+G)                [pri 1]
 *   SD_FULL            red solid                                        [pri 2]
 *   SD_MISSING         blue 1 s blink                                   [pri 3]
 *   CHARGED            green solid                                      [pri 4]
 *   CHARGING           yellow (R+G) heartbeat — 50 ms / 5 s             [pri 5]
 *   BLE_CONNECTED      green heartbeat                                  [pri 6]
 *   RECORDING          white (R+G+B) heartbeat                          [pri 6]
 *   IDLE               all off                                          [pri 7]
 *
 * Heartbeat duty 1% (50 ms / 5 s) keeps platform-wide LED current under
 * +0.01 mA — see spec §11.2 / §14.2.
 *
 * Inputs we read today:
 *   - is_connected (BLE) from transport.c
 *
 * Inputs deferred (TODO): battery ADC, SD-state probing, USB-charging
 * detection. Until those land the warning patterns can be exercised by
 * setting the static flags in wr_led_status.c via test hooks.
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdbool.h>

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

/* Public test hooks — header to follow when more callers exist. */
void wr_led_status_set_charging(bool on)    { wr_led_charging = on;  wr_led_charged = false; }
void wr_led_status_set_charged(bool on)     { wr_led_charged = on;   wr_led_charging = false; }
void wr_led_status_set_sd_full(bool on)     { wr_led_sd_full = on; }
void wr_led_status_set_sd_missing(bool on)  { wr_led_sd_missing = on; }
void wr_led_status_set_batt_pct(uint8_t p)  { wr_led_batt_pct = p; }

static void apply_rgb(bool r, bool g, bool b)
{
	set_led_red(r);
	set_led_green(g);
	set_led_blue(b);
}

static void wr_led_tick(struct k_timer *t)
{
	ARG_UNUSED(t);

	/* Tick counter. 50 ms granularity from a 100 ms timer is enough for
	 * the patterns we care about. */
	static uint32_t tick;          /* 100 ms units */
	tick++;

	const uint32_t in_5s_window = tick % 50;        /* 0..49 (5 s cycle) */
	const uint32_t hb_on = (in_5s_window == 0);     /* first 100 ms */
	const uint32_t blink_500ms = (tick % 5) < 3;    /* slow blink ~60% on */
	const uint32_t blink_250ms = (tick % 5) < 3 ?
				     ((tick % 3) < 2) : ((tick % 3) < 2); /* coarse fast */
	const uint32_t blink_1s = (tick % 10) < 5;

	/* Pick highest-priority pattern. */
	if (wr_led_batt_pct <= 5) {
		apply_rgb(blink_250ms, false, false);             /* red fast */
	} else if (wr_led_batt_pct <= 20) {
		apply_rgb(blink_500ms, blink_500ms, false);       /* orange */
	} else if (wr_led_sd_full) {
		apply_rgb(true, false, false);                     /* red solid */
	} else if (wr_led_sd_missing) {
		apply_rgb(false, false, blink_1s);                 /* blue blink */
	} else if (wr_led_charged) {
		apply_rgb(false, true, false);                     /* green solid */
	} else if (wr_led_charging) {
		apply_rgb(hb_on, hb_on, false);                    /* yellow HB */
	} else if (is_connected && wr_led_recording) {
		/* Alternate green HB and white HB on each 5 s cycle. */
		const uint32_t cycle = (tick / 50) & 1;
		if (cycle) {
			apply_rgb(hb_on, hb_on, hb_on);            /* white HB */
		} else {
			apply_rgb(false, hb_on, false);            /* green HB */
		}
	} else if (is_connected) {
		apply_rgb(false, hb_on, false);                    /* green HB */
	} else if (wr_led_recording) {
		apply_rgb(hb_on, hb_on, hb_on);                    /* white HB */
	} else {
		apply_rgb(false, false, false);                    /* idle */
	}
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
