/*
 * Battery Service updater (Bluetooth SIG UUID 0x180F).
 *
 * Zephyr already exposes the standard Battery Service when CONFIG_BT_BAS=y.
 * This file only feeds the latest battery-level percentage into that one
 * service so clients do not see duplicate 0x180F services.
 *
 * Battery percentage is derived from the last ADC reading already
 * maintained by wr_led_status.c (shared via wr_led_status_get_batt_pct).
 * A delayed workqueue item re-samples every WR_BATT_SVC_INTERVAL_MS
 * (60 s) and triggers a BLE notification when the value differs from
 * the last notified value.
 *
 * Call wr_battery_service_init() once during boot to arm the timer.
 */

#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdint.h>

#include "wr_battery_service.h"
#include "wr_battery.h"

LOG_MODULE_REGISTER(wr_battery_svc, CONFIG_LOG_DEFAULT_LEVEL);

/* 60-second polling interval (ms). */
#define WR_BATT_SVC_INTERVAL_MS 60000

/* ------------------------------------------------------------------ */
/* Battery level source                                                */
/* ------------------------------------------------------------------ */

/*
 * wr_led_status.c reads the SAADC and caches the result in
 * wr_led_batt_pct (updated every 10 s).  We access it through a thin
 * getter declared here; the linker will resolve it from wr_led_status.c
 * when built into the firmware image.
 *
 * In unit-test builds (native_sim) the getter is stubbed out by the
 * test harness so neither the ADC driver nor wr_led_status.c is needed.
 */
uint8_t wr_led_status_get_batt_pct(void);

/* ------------------------------------------------------------------ */
/* Notification state                                                  */
/* ------------------------------------------------------------------ */

static uint8_t wr_batt_last_pct = 0xFF; /* sentinel - force first update */

/* ------------------------------------------------------------------ */
/* Periodic update work                                                */
/* ------------------------------------------------------------------ */

static void wr_batt_update_fn(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(wr_batt_work, wr_batt_update_fn);

static void wr_batt_update_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	uint8_t pct = wr_led_status_get_batt_pct();

	if (pct != wr_batt_last_pct) {
		int err = bt_bas_set_battery_level(pct);
		if (err) {
			LOG_WRN("wr_battery_svc: BAS update failed (%d)", err);
		} else {
			LOG_DBG("wr_battery_svc: updated %u%%", pct);
		}
	}

	wr_batt_last_pct = pct;

	/* Re-arm for next interval. */
	k_work_reschedule(&wr_batt_work,
			  K_MSEC(WR_BATT_SVC_INTERVAL_MS));
}

/* ------------------------------------------------------------------ */
/* Init                                                                */
/* ------------------------------------------------------------------ */

void wr_battery_service_init(void)
{
	k_work_reschedule(&wr_batt_work, K_MSEC(1000));
	LOG_INF("wr_battery_svc: armed (interval %d s)",
		WR_BATT_SVC_INTERVAL_MS / 1000);
}
