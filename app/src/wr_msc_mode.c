/*
 * Phase 4-4 (MVP): USB Mass Storage mode-switch detected at boot.
 *
 * The plan (D9): boot in normal recording mode by default; if the user
 * holds the omi button (D5 input, energised by D4 output) for at least
 * 1 second during the first ~1.5 s of boot, we flip into MSC mode and
 * expose the SD card as a USB drive instead of recording.
 *
 * This first cut just lands the build-side pieces and the boot-time
 * detection; runtime gating of recording / wr_chunk / wr_fifo and the
 * actual usb_enable() handoff comes in a follow-up once we've confirmed
 * on real hardware that the MSC stack fits the FLASH/RAM budget.
 *
 * Boot button circuit (omi standard, D2 confirmed):
 *   D4 (P0.04) — drive HIGH so the tact switch has a 3V3 source.
 *   D5 (P0.05) — read; HIGH means button is closed.
 *
 * We can't reuse omi's button.c structures because button_init() runs
 * inside main(), which is after our SYS_INIT. So we do raw GPIO init
 * here, sample for ~1 s, then back off so omi's button_init() can take
 * over and treat D5 as a runtime button source.
 */

#include <zephyr/drivers/gpio.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdbool.h>

#include "wr_msc_mode_logic.h"

LOG_MODULE_REGISTER(wr_msc_mode, CONFIG_LOG_DEFAULT_LEVEL);

#define WR_MSC_BOOT_PIN_OUT 4   /* D4 */
#define WR_MSC_BOOT_PIN_IN  5   /* D5 */
#define WR_MSC_BOOT_SAMPLE_MS 10
#define WR_MSC_BOOT_SAMPLE_COUNT 100  /* 1 s total */
#define WR_MSC_BOOT_HIGH_THRESHOLD 80 /* 80 of 100 samples => held */

static bool wr_msc_mode_flag;

bool wr_msc_mode_is_active(void)
{
	return wr_msc_mode_flag;
}

static int wr_msc_mode_boot_detect(void)
{
	const struct device *gpio0 = DEVICE_DT_GET(DT_NODELABEL(gpio0));

	if (!device_is_ready(gpio0)) {
		LOG_WRN("wr_msc_mode: gpio0 not ready, defaulting to recording mode");
		return 0;
	}

	/* Energise the button circuit. */
	int err = gpio_pin_configure(gpio0, WR_MSC_BOOT_PIN_OUT,
				     GPIO_OUTPUT_ACTIVE);
	if (err) {
		LOG_WRN("wr_msc_mode: D4 configure failed (%d)", err);
		return 0;
	}
	gpio_pin_set(gpio0, WR_MSC_BOOT_PIN_OUT, 1);

	err = gpio_pin_configure(gpio0, WR_MSC_BOOT_PIN_IN, GPIO_INPUT);
	if (err) {
		LOG_WRN("wr_msc_mode: D5 configure failed (%d)", err);
		return 0;
	}

	/* Brief settle. */
	k_busy_wait(5000);

	/* Sample over WR_MSC_BOOT_SAMPLE_COUNT * WR_MSC_BOOT_SAMPLE_MS ms. */
	int high = 0;
	for (int i = 0; i < WR_MSC_BOOT_SAMPLE_COUNT; i++) {
		if (gpio_pin_get(gpio0, WR_MSC_BOOT_PIN_IN) == 1) {
			high++;
		}
		k_msleep(WR_MSC_BOOT_SAMPLE_MS);
	}

	if (wr_msc_mode_decide(high, WR_MSC_BOOT_SAMPLE_COUNT,
			       WR_MSC_BOOT_HIGH_THRESHOLD)) {
		wr_msc_mode_flag = true;
		LOG_INF("wr_msc_mode: button held at boot (%d/%d) — MSC MODE",
			high, WR_MSC_BOOT_SAMPLE_COUNT);
	} else {
		LOG_INF("wr_msc_mode: recording mode (%d/%d high)",
			high, WR_MSC_BOOT_SAMPLE_COUNT);
	}

	return 0;
}

/* Run after kernel init but before main() and our other application
 * SYS_INITs so wr_chunk / wr_fifo / wr_led can read the flag during
 * their own setup. */
SYS_INIT(wr_msc_mode_boot_detect, APPLICATION, 50);
