/*
 * D7 wiring: time-sync GATT characteristic for wr-recorder.
 *
 * Registers a secondary BLE GATT service (separate from omi's audio service)
 * with UUID 19B10005-E8F2-537E-4F6C-D104768A1214.
 *
 * Characteristic: WR_TIME_SYNC (UUID 19B10005-...)
 *   - WRITE NO RESPONSE, 8 bytes = LE64 Unix timestamp in seconds
 *   - On write: calls wr_chunk_set_sync_time(unix_secs) which stores the
 *     value and marks is_synced = true in wr_chunk.c
 *
 * Zephyr allows multiple BT_GATT_SERVICE_DEFINE macros across translation
 * units; this file adds the wearable-recorder service without touching
 * anything in third_party/omi/.
 */

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdint.h>

LOG_MODULE_REGISTER(wr_time_sync, CONFIG_LOG_DEFAULT_LEVEL);

/* Forward declaration — implemented in wr_chunk.c. */
void wr_chunk_set_sync_time(uint64_t unix_secs);

/*
 * Service UUID:       19B10005-E8F2-537E-4F6C-D104768A1214
 * Characteristic UUID: 19B10005-E8F2-537E-4F6C-D104768A1214
 * (single-characteristic service; service UUID doubles as char UUID per spec)
 */
#define WR_TIME_SYNC_SERVICE_UUID \
	BT_UUID_128_ENCODE(0x19B10005, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)
#define WR_TIME_SYNC_CHAR_UUID \
	BT_UUID_128_ENCODE(0x19B10005, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)

static struct bt_uuid_128 wr_time_sync_svc_uuid =
	BT_UUID_INIT_128(WR_TIME_SYNC_SERVICE_UUID);
static struct bt_uuid_128 wr_time_sync_char_uuid =
	BT_UUID_INIT_128(WR_TIME_SYNC_CHAR_UUID);

static ssize_t wr_time_sync_write(struct bt_conn *conn,
				  const struct bt_gatt_attr *attr,
				  const void *buf, uint16_t len,
				  uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len != sizeof(uint64_t)) {
		LOG_WRN("wr_time_sync: expected 8 bytes, got %u", len);
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	uint64_t unix_secs;
	memcpy(&unix_secs, buf, sizeof(unix_secs));

	LOG_INF("wr_time_sync: received epoch %" PRIu64 " s", unix_secs);

	wr_chunk_set_sync_time(unix_secs);

	return (ssize_t)len;
}

BT_GATT_SERVICE_DEFINE(wr_time_sync_svc,
	BT_GATT_PRIMARY_SERVICE(&wr_time_sync_svc_uuid),
	BT_GATT_CHARACTERISTIC(&wr_time_sync_char_uuid.uuid,
			       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE,
			       NULL,
			       wr_time_sync_write,
			       NULL),
);
