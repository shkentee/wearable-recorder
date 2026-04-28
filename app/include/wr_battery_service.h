/*
 * Battery GATT Service public API.
 *
 * Registers Bluetooth SIG Battery Service (UUID 0x180F) with a
 * Battery Level characteristic (UUID 0x2A19) that supports READ and
 * NOTIFY.  A workqueue item fires every 60 seconds to poll the current
 * level and send a notification when the value changes.
 *
 * The GATT service table is registered via BT_GATT_SERVICE_DEFINE
 * (no explicit init call required for the BLE registration itself).
 * Call wr_battery_service_init() once during boot to arm the 60-second
 * polling timer.
 */

#pragma once

void wr_battery_service_init(void);
