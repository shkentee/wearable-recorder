/*
 * Storage GATT service — BLE-based file transfer from SD card.
 *
 * Service UUID: 30295780-4301-EABD-2904-2849ADFEAE43
 *
 *   storageStream  (30295781, NOTIFY):
 *     [0x01][name_bytes]  FILE_ENTRY — one file per notify during LIST
 *     [0x02][data_bytes]  DATA       — raw file chunk during FETCH
 *     [0x03]              END        — end of listing or end of file
 *     [0xFF]              ERROR      — file not found or I/O error
 *
 *   storageReadControl (30295782, WRITE_WITHOUT_RESP):
 *     [0x00]              LIST   — enumerate completed .opus files
 *     [0x01][name...]     FETCH  — stream named file to client
 *     [0xFF]              ABORT  — cancel ongoing transfer
 *
 * Transfers run on the system work queue to avoid blocking the BLE stack.
 * The active recording file ("a01.txt") is excluded from listings.
 * Completed files are safe to read concurrently with wr_chunk writes
 * because FAT32 allows concurrent read-only opens and we never rename
 * or delete during a transfer.
 *
 * Backpressure: bt_gatt_notify() returns -ENOMEM when the TX queue is
 * full; we spin-yield up to WR_STORAGE_NOTIFY_RETRIES times to let the
 * BLE stack drain before giving up.
 */

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <string.h>

LOG_MODULE_REGISTER(wr_storage, CONFIG_LOG_DEFAULT_LEVEL);

/* SD audio directory — same root as wr_chunk.c */
#define WR_STORAGE_DIR       "/SD:/audio"
#define WR_STORAGE_ACTIVE    "a01.txt"   /* exclude the live recording file */

/* Protocol bytes */
#define WR_NOTIF_FILE_ENTRY  0x01
#define WR_NOTIF_DATA        0x02
#define WR_NOTIF_END         0x03
#define WR_NOTIF_ERROR       0xFF

#define WR_CMD_LIST    0x00
#define WR_CMD_FETCH   0x01
#define WR_CMD_ABORT   0xFF

/*
 * Data payload per notify.
 * omi prj.conf: CONFIG_BT_L2CAP_TX_MTU=498 → ATT payload = 498 - 3 = 495.
 * We reserve 1 byte for the type prefix → 494 bytes of user data.
 */
#define WR_STORAGE_CHUNK_SIZE    494
#define WR_STORAGE_NOTIFY_RETRIES 10
#define WR_STORAGE_RETRY_MS       20

/* ------------------------------------------------------------------ */
/* UUID definitions                                                    */
/* ------------------------------------------------------------------ */

#define WR_STORAGE_SVC_UUID_INIT \
	BT_UUID_128_ENCODE(0x30295780, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43)
#define WR_STORAGE_STREAM_UUID_INIT \
	BT_UUID_128_ENCODE(0x30295781, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43)
#define WR_STORAGE_CTRL_UUID_INIT \
	BT_UUID_128_ENCODE(0x30295782, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43)

static struct bt_uuid_128 wr_storage_svc_uuid =
	BT_UUID_INIT_128(WR_STORAGE_SVC_UUID_INIT);
static struct bt_uuid_128 wr_storage_stream_uuid =
	BT_UUID_INIT_128(WR_STORAGE_STREAM_UUID_INIT);
static struct bt_uuid_128 wr_storage_ctrl_uuid =
	BT_UUID_INIT_128(WR_STORAGE_CTRL_UUID_INIT);

/* ------------------------------------------------------------------ */
/* Transfer state                                                      */
/* ------------------------------------------------------------------ */

static enum {
	WR_ST_IDLE,
	WR_ST_LISTING,
	WR_ST_FETCHING,
} wr_state = WR_ST_IDLE;

/* Filename requested by a FETCH command (null-terminated). */
static char wr_fetch_name[64];

/* Connection that subscribed to storageStream notifications. */
static struct bt_conn *wr_sub_conn;

/* ------------------------------------------------------------------ */
/* CCC                                                                 */
/* ------------------------------------------------------------------ */

static void wr_storage_ccc_changed(const struct bt_gatt_attr *attr,
				   uint16_t value)
{
	if (value & BT_GATT_CCC_NOTIFY) {
		LOG_INF("wr_storage: client subscribed");
	} else {
		LOG_INF("wr_storage: client unsubscribed — aborting transfer");
		wr_state = WR_ST_IDLE;
		wr_sub_conn = NULL;
	}
}

/* ------------------------------------------------------------------ */
/* GATT service definition                                             */
/*                                                                     */
/* attrs layout:                                                       */
/*   [0] Primary Service                                               */
/*   [1] storageStream declaration                                     */
/*   [2] storageStream value      ← used with bt_gatt_notify()        */
/*   [3] CCC descriptor                                                */
/*   [4] storageReadControl declaration                                */
/*   [5] storageReadControl value                                      */
/* ------------------------------------------------------------------ */

static ssize_t wr_storage_ctrl_write(struct bt_conn *conn,
				     const struct bt_gatt_attr *attr,
				     const void *buf, uint16_t len,
				     uint16_t offset, uint8_t flags);

BT_GATT_SERVICE_DEFINE(wr_storage_svc,
	BT_GATT_PRIMARY_SERVICE(&wr_storage_svc_uuid),
	BT_GATT_CHARACTERISTIC(&wr_storage_stream_uuid.uuid,
			       BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE,
			       NULL, NULL, NULL),
	BT_GATT_CCC(wr_storage_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&wr_storage_ctrl_uuid.uuid,
			       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE,
			       NULL, wr_storage_ctrl_write, NULL),
);

/* ------------------------------------------------------------------ */
/* Notification helpers                                                */
/* ------------------------------------------------------------------ */

/*
 * Send one typed notify.  Retries on -ENOMEM (TX queue full) to provide
 * simple backpressure without needing a completion callback.
 * Returns 0 on success or the last error code from bt_gatt_notify().
 */
static int wr_notify(struct bt_conn *conn, uint8_t type,
		     const void *data, uint16_t data_len)
{
	uint8_t buf[1 + WR_STORAGE_CHUNK_SIZE];

	buf[0] = type;
	uint16_t total = 1;
	if (data && data_len > 0) {
		uint16_t copy = data_len < WR_STORAGE_CHUNK_SIZE
				? data_len : WR_STORAGE_CHUNK_SIZE;
		memcpy(&buf[1], data, copy);
		total = (uint16_t)(1 + copy);
	}

	int err;
	for (int i = 0; i < WR_STORAGE_NOTIFY_RETRIES; i++) {
		err = bt_gatt_notify(conn, &wr_storage_svc.attrs[2],
				     buf, total);
		if (err != -ENOMEM) {
			break;
		}
		k_msleep(WR_STORAGE_RETRY_MS);
	}
	return err;
}

/* ------------------------------------------------------------------ */
/* Work handlers (run on system work queue, not ISR)                  */
/* ------------------------------------------------------------------ */

static void wr_storage_list_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	struct bt_conn *conn = wr_sub_conn;

	if (!conn || wr_state != WR_ST_LISTING) {
		return;
	}

	struct fs_dir_t dir;

	fs_dir_t_init(&dir);

	if (fs_opendir(&dir, WR_STORAGE_DIR) != 0) {
		LOG_WRN("wr_storage: opendir %s failed", WR_STORAGE_DIR);
		wr_notify(conn, WR_NOTIF_ERROR, NULL, 0);
		wr_state = WR_ST_IDLE;
		return;
	}

	struct fs_dirent entry;

	while (wr_state == WR_ST_LISTING &&
	       fs_readdir(&dir, &entry) == 0 &&
	       entry.name[0] != '\0') {

		/* Skip the live recording file. */
		if (strcmp(entry.name, WR_STORAGE_ACTIVE) == 0) {
			continue;
		}

		/* Only list .opus files. */
		size_t nlen = strlen(entry.name);

		if (nlen < 5 ||
		    strcmp(entry.name + nlen - 5, ".opus") != 0) {
			continue;
		}

		int err = wr_notify(conn, WR_NOTIF_FILE_ENTRY,
				    entry.name, (uint16_t)nlen);

		if (err) {
			LOG_WRN("wr_storage: notify FILE_ENTRY failed (%d)", err);
			break;
		}
	}

	fs_closedir(&dir);

	if (wr_state != WR_ST_IDLE) {
		wr_notify(conn, WR_NOTIF_END, NULL, 0);
	}
	wr_state = WR_ST_IDLE;
}

static void wr_storage_fetch_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	struct bt_conn *conn = wr_sub_conn;

	if (!conn || wr_state != WR_ST_FETCHING) {
		return;
	}

	char path[128];

	snprintf(path, sizeof(path), "%s/%s", WR_STORAGE_DIR, wr_fetch_name);

	struct fs_file_t file;

	fs_file_t_init(&file);

	if (fs_open(&file, path, FS_O_READ) != 0) {
		LOG_WRN("wr_storage: open %s failed", wr_fetch_name);
		wr_notify(conn, WR_NOTIF_ERROR, NULL, 0);
		wr_state = WR_ST_IDLE;
		return;
	}

	uint8_t chunk[WR_STORAGE_CHUNK_SIZE];
	ssize_t n;

	while (wr_state == WR_ST_FETCHING &&
	       (n = fs_read(&file, chunk, sizeof(chunk))) > 0) {

		int err = wr_notify(conn, WR_NOTIF_DATA, chunk, (uint16_t)n);

		if (err) {
			LOG_WRN("wr_storage: notify DATA failed (%d)", err);
			break;
		}
	}

	fs_close(&file);

	if (wr_state != WR_ST_IDLE) {
		wr_notify(conn, WR_NOTIF_END, NULL, 0);
	}
	wr_state = WR_ST_IDLE;

	LOG_INF("wr_storage: fetch complete: %s", wr_fetch_name);
}

static K_WORK_DEFINE(wr_list_work,  wr_storage_list_fn);
static K_WORK_DEFINE(wr_fetch_work, wr_storage_fetch_fn);

/* ------------------------------------------------------------------ */
/* Control write handler (called from BLE RX thread)                  */
/* ------------------------------------------------------------------ */

static ssize_t wr_storage_ctrl_write(struct bt_conn *conn,
				     const struct bt_gatt_attr *attr,
				     const void *buf, uint16_t len,
				     uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len == 0) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	const uint8_t *cmd = (const uint8_t *)buf;

	switch (cmd[0]) {
	case WR_CMD_LIST:
		LOG_INF("wr_storage: LIST requested");
		wr_sub_conn = conn;
		wr_state = WR_ST_LISTING;
		k_work_submit(&wr_list_work);
		break;

	case WR_CMD_FETCH: {
		if (len < 2) {
			return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
		}
		uint16_t name_len = len - 1;

		if (name_len >= sizeof(wr_fetch_name)) {
			name_len = sizeof(wr_fetch_name) - 1;
		}
		memcpy(wr_fetch_name, cmd + 1, name_len);
		wr_fetch_name[name_len] = '\0';
		LOG_INF("wr_storage: FETCH %s", wr_fetch_name);
		wr_sub_conn = conn;
		wr_state = WR_ST_FETCHING;
		k_work_submit(&wr_fetch_work);
		break;
	}

	case WR_CMD_ABORT:
		LOG_INF("wr_storage: ABORT");
		wr_state = WR_ST_IDLE;
		break;

	default:
		return BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED);
	}

	return (ssize_t)len;
}
