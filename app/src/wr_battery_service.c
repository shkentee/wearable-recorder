/*
 * Battery GATT Service (Bluetooth SIG UUID 0x180F).
 *
 * Exposes a Battery Level characteristic (UUID 0x2A19):
 *   - READ:   returns current battery-level percentage [0–100]
 *   - NOTIFY: sends a notification whenever the level changes
 *
 * Battery percentage is derived from the last ADC reading already
 * maintained by wr_led_status.c (shared via wr_led_status_get_batt_pct).
 * A delayed workqueue item re-samples every WR_BATT_SVC_INTERVAL_MS
 * (60 s) and triggers a BLE notification when the value differs from
 * the last notified value.
 *
 * The GATT table is registered at link time via BT_GATT_SERVICE_DEFINE;
 * call wr_battery_service_init() once during boot to arm the timer.
 */

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
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

static uint8_t wr_batt_last_pct = 0xFF; /* sentinel — force first notify */
static bool    wr_batt_notify_enabled;

/* ------------------------------------------------------------------ */
/* GATT service definition                                             */
/*                                                                     */
/* attrs layout:                                                       */
/*   [0] Primary Service  (0x180F)                                     */
/*   [1] Battery Level declaration                                     */
/*   [2] Battery Level value  (0x2A19)  ← used with bt_gatt_notify()  */
/*   [3] CCC descriptor                                                */
/* ------------------------------------------------------------------ */

static ssize_t wr_batt_read(struct bt_conn *conn,
			    const struct bt_gatt_attr *attr,
			    void *buf, uint16_t len, uint16_t offset)
{
	uint8_t pct = wr_led_status_get_batt_pct();

	return bt_gatt_attr_read(conn, attr, buf, len, offset,
				 &pct, sizeof(pct));
}

static void wr_batt_ccc_changed(const struct bt_gatt_attr *attr,
				uint16_t value)
{
	wr_batt_notify_enabled = (value & BT_GATT_CCC_NOTIFY) != 0;
	LOG_INF("wr_battery_svc: notifications %s",
		wr_batt_notify_enabled ? "enabled" : "disabled");
}

BT_GATT_SERVICE_DEFINE(wr_battery_svc,
	BT_GATT_PRIMARY_SERVICE(BT_UUID_BAS),
	BT_GATT_CHARACTERISTIC(BT_UUID_BAS_BATTERY_LEVEL,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ,
			       wr_batt_read, NULL, NULL),
	BT_GATT_CCC(wr_batt_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* ------------------------------------------------------------------ */
/* Periodic update work                                                */
/* ------------------------------------------------------------------ */

static void wr_batt_update_fn(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(wr_batt_work, wr_batt_update_fn);

static void wr_batt_update_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	uint8_t pct = wr_led_status_get_batt_pct();

	if (wr_batt_notify_enabled && pct != wr_batt_last_pct) {
		/* attrs[2] is the Battery Level value attribute. */
		int err = bt_gatt_notify(NULL, &wr_battery_svc.attrs[2],
					 &pct, sizeof(pct));
		if (err && err != -ENOTCONN) {
			LOG_WRN("wr_battery_svc: notify failed (%d)", err);
		} else {
			LOG_DBG("wr_battery_svc: notified %u%%", pct);
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
	/* Kick off the first update after one full interval so the BLE
	 * stack has time to come up and a connection can form. */
	k_work_reschedule(&wr_batt_work, K_MSEC(WR_BATT_SVC_INTERVAL_MS));
	LOG_INF("wr_battery_svc: armed (interval %d s)",
		WR_BATT_SVC_INTERVAL_MS / 1000);
}
