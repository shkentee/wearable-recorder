/*
 * Phase 5+ bsim wr_link — peripheral side.
 *
 * Advertise the omi audio service, accept the central's connection,
 * notify a single sentinel packet on the audioCodec characteristic,
 * then PASS.
 *
 * Connection callbacks are registered with bt_conn_cb_register() at
 * runtime instead of BT_CONN_CB_DEFINE(). With link-time registration
 * the central role's callbacks (also linked into the same binary)
 * fire on the peripheral's connect event and trigger work that wasn't
 * initialised on this side — kernel panic. Dynamic registration keeps
 * the policy tied to the role that's actually active.
 */

#include "wr_bs_utils.h"

#include <zephyr/bluetooth/gatt.h>
#include <errno.h>
#include <string.h>

#define WR_LINK_BURST_COUNT 5
#define WR_LINK_BURST_INTERVAL_MS 50
#define WR_STORAGE_NOTIFY_RETRIES 20
#define WR_STORAGE_NOTIFY_RETRY_MS 20

DEFINE_FLAG(flag_peer_connected);
DEFINE_FLAG(flag_notify_sent);
DEFINE_FLAG(flag_time_sync_received);
DEFINE_FLAG(flag_storage_list_handled);
DEFINE_FLAG(flag_storage_fetch_handled);

static struct bt_conn *peer_conn;
static struct k_work_delayable notify_work;
static uint16_t notify_seq;

/* Storage GATT: command received from central, queued to work queue. */
static uint8_t  storage_cmd;
static struct k_work storage_resp_work;

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, BT_UUID_OMI_AUDIO_SERVICE_VAL),
};

static void ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	bs_trace_info_time(1, "peripheral: CCC changed -> 0x%04x\n", value);
	/* Fire the notify only once the central has actually subscribed
	 * (CCC value bit BT_GATT_CCC_NOTIFY set). Otherwise bt_gatt_notify
	 * returns -EINVAL with the "Device is not subscribed" warning. */
	if ((value & BT_GATT_CCC_NOTIFY) != 0) {
		k_work_schedule(&notify_work, K_MSEC(20));
	}
}

BT_GATT_SERVICE_DEFINE(audio_svc,
	BT_GATT_PRIMARY_SERVICE(BT_UUID_OMI_AUDIO_SERVICE),
	BT_GATT_CHARACTERISTIC(BT_UUID_OMI_AUDIO_CODEC,
			       BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE,
			       NULL, NULL, NULL),
	BT_GATT_CCC(ccc_cfg_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* ---------------------------------------------------------------
 * Storage GATT service — bsim test stub.
 *
 * Mirrors the protocol in app/src/wr_storage_service.c:
 *   LIST (0x00) → FILE_ENTRY × 2 + END
 *   FETCH (0x01 + name) → DATA × 1 + END
 * Responses are sent from a work queue handler (not from the write
 * callback) to keep the BLE RX thread unblocked.
 * --------------------------------------------------------------- */

static ssize_t storage_ctrl_write_cb(struct bt_conn *conn,
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

	storage_cmd = ((const uint8_t *)buf)[0];
	k_work_submit(&storage_resp_work);
	return (ssize_t)len;
}

static void storage_stream_ccc_changed(const struct bt_gatt_attr *attr,
				       uint16_t value)
{
	bs_trace_info_time(1, "peripheral: storage stream CCC -> 0x%04x\n", value);
}

BT_GATT_SERVICE_DEFINE(storage_svc,
	BT_GATT_PRIMARY_SERVICE(BT_UUID_WR_STORAGE_SVC),
	BT_GATT_CHARACTERISTIC(BT_UUID_WR_STORAGE_STREAM,
			       BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE,
			       NULL, NULL, NULL),
	BT_GATT_CCC(storage_stream_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(BT_UUID_WR_STORAGE_CTRL,
			       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE,
			       NULL, storage_ctrl_write_cb, NULL),
);
/* storage_svc.attrs[2] = storageStream value (used with bt_gatt_notify). */

static void storage_notify_done(struct bt_conn *conn, void *user_data)
{
	ARG_UNUSED(conn);

	struct k_sem *done = user_data;
	k_sem_give(done);
}

static int storage_notify_with_retry(struct bt_conn *conn,
				     const void *data, uint16_t len)
{
	int err = 0;
	struct k_sem done;
	struct bt_gatt_notify_params params = {
		.attr = &storage_svc.attrs[2],
		.data = data,
		.len = len,
		.func = storage_notify_done,
		.user_data = &done,
	};

	for (int attempt = 0; attempt < WR_STORAGE_NOTIFY_RETRIES; attempt++) {
		k_sem_init(&done, 0, 1);

		err = bt_gatt_notify_cb(conn, &params);
		if (err == 0) {
			k_sem_take(&done, K_FOREVER);
			return 0;
		}

		if (err != -ENOMEM && err != -EAGAIN) {
			return err;
		}

		k_msleep(WR_STORAGE_NOTIFY_RETRY_MS);
	}

	return err;
}

static void storage_resp_worker(struct k_work *work)
{
	ARG_UNUSED(work);

	struct bt_conn *conn = peer_conn;

	if (!conn) {
		return;
	}

	if (storage_cmd == 0x00) {
		/* LIST: send FILE_ENTRY for each test file, then END. */
		const char *files[] = {
			WR_STORAGE_TEST_FILE_1,
			WR_STORAGE_TEST_FILE_2,
		};
		for (int i = 0; i < 2; i++) {
			uint8_t buf[1 + 64];
			size_t nlen = strlen(files[i]);
			buf[0] = 0x01; /* FILE_ENTRY */
			memcpy(&buf[1], files[i], nlen);
			int err = storage_notify_with_retry(
				conn, buf, (uint16_t)(1 + nlen));
			if (err) {
				FAIL("peripheral: storage LIST notify failed (%d)\n",
				     err);
				return;
			}
			k_msleep(10);
		}
		uint8_t end = 0x03;
		int err = storage_notify_with_retry(conn, &end, 1);
		if (err) {
			FAIL("peripheral: storage LIST END notify failed (%d)\n",
			     err);
			return;
		}
		bs_trace_info_time(1, "peripheral: storage LIST sent (2 entries + END)\n");
		SET_FLAG(flag_storage_list_handled);

	} else if (storage_cmd == 0x01) {
		/* FETCH: send DATA chunk, then END. */
		uint8_t data[] = WR_STORAGE_TEST_DATA;
		uint8_t buf[1 + WR_STORAGE_TEST_DATA_LEN];
		buf[0] = 0x02; /* DATA */
		memcpy(&buf[1], data, WR_STORAGE_TEST_DATA_LEN);
		int err = storage_notify_with_retry(
			conn, buf, (uint16_t)sizeof(buf));
		if (err) {
			FAIL("peripheral: storage FETCH notify failed (%d)\n", err);
			return;
		}
		k_msleep(10);
		uint8_t end = 0x03;
		err = storage_notify_with_retry(conn, &end, 1);
		if (err) {
			FAIL("peripheral: storage FETCH END notify failed (%d)\n",
			     err);
			return;
		}
		bs_trace_info_time(1, "peripheral: storage FETCH sent (data + END)\n");
		SET_FLAG(flag_storage_fetch_handled);
	}
}

/* D7 time-sync service: single WRITE_WITHOUT_RESP characteristic.
 * Mirrors app/src/wr_time_sync.c — service UUID doubles as char UUID. */
static ssize_t time_sync_write(struct bt_conn *conn,
			       const struct bt_gatt_attr *attr,
			       const void *buf, uint16_t len,
			       uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len != sizeof(uint64_t)) {
		FAIL("peripheral: time-sync write: expected 8 bytes, got %u\n",
		     (unsigned)len);
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	uint64_t epoch;
	memcpy(&epoch, buf, sizeof(epoch));

	bs_trace_info_time(1,
		"peripheral: time-sync epoch received: 0x%016llx\n",
		(unsigned long long)epoch);

	if (epoch != WR_LINK_TIME_SYNC_EPOCH) {
		FAIL("peripheral: epoch 0x%016llx != expected 0x%016llx\n",
		     (unsigned long long)epoch,
		     (unsigned long long)WR_LINK_TIME_SYNC_EPOCH);
		return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
	}

	SET_FLAG(flag_time_sync_received);
	return (ssize_t)len;
}

BT_GATT_SERVICE_DEFINE(time_sync_svc,
	BT_GATT_PRIMARY_SERVICE(BT_UUID_WR_TIME_SYNC),
	BT_GATT_CHARACTERISTIC(BT_UUID_WR_TIME_SYNC,
			       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE,
			       NULL, time_sync_write, NULL),
);

static void notify_worker(struct k_work *work)
{
	ARG_UNUSED(work);

	if (!peer_conn) {
		FAIL("peripheral: notify_worker fired without a connection\n");
		return;
	}

	/* Build a packet whose first 2 bytes are the LE16 sequence id;
	 * mirrors omi audio packet header layout (packet_id + frame_id +
	 * payload). The central counts how many it sees, so we just need
	 * each one to be a legal payload. */
	uint8_t payload[] = WR_LINK_PROBE_PAYLOAD;
	payload[0] = (uint8_t)(notify_seq & 0xff);
	payload[1] = (uint8_t)((notify_seq >> 8) & 0xff);

	int err = bt_gatt_notify(peer_conn, &audio_svc.attrs[1],
				 payload, sizeof(payload));
	if (err) {
		FAIL("peripheral: bt_gatt_notify[%u] failed (%d)\n",
		     notify_seq, err);
		return;
	}
	bs_trace_info_time(1, "peripheral: sent notify #%u (%u bytes)\n",
			   notify_seq, (unsigned)sizeof(payload));
	notify_seq++;

	if (notify_seq < WR_LINK_BURST_COUNT) {
		k_work_schedule(&notify_work,
				K_MSEC(WR_LINK_BURST_INTERVAL_MS));
	} else {
		bs_trace_info_time(1,
			"peripheral: burst complete (%u packets)\n",
			WR_LINK_BURST_COUNT);
		SET_FLAG(flag_notify_sent);
	}
}

static void peripheral_connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		FAIL("peripheral: connection failed (%u)\n", err);
		return;
	}
	bs_trace_info_time(1, "peripheral: connected\n");
	peer_conn = bt_conn_ref(conn);
	SET_FLAG(flag_peer_connected);
	/* Don't notify yet — wait for the central to write the CCC
	 * descriptor, which fires ccc_cfg_changed and schedules the
	 * notify_work. Race-free even on bsim's compressed clock. */
}

static void peripheral_disconnected(struct bt_conn *conn, uint8_t reason)
{
	bs_trace_info_time(1, "peripheral: disconnected (reason 0x%02x)\n",
			   reason);
	if (peer_conn) {
		bt_conn_unref(peer_conn);
		peer_conn = NULL;
	}
}

static struct bt_conn_cb peripheral_cb = {
	.connected = peripheral_connected,
	.disconnected = peripheral_disconnected,
};

void wr_run_peripheral(void)
{
	int err = bt_enable(NULL);
	if (err) {
		FAIL("peripheral: bt_enable failed (%d)\n", err);
		return;
	}
	bt_conn_cb_register(&peripheral_cb);
	k_work_init_delayable(&notify_work, notify_worker);
	k_work_init(&storage_resp_work, storage_resp_worker);

	err = bt_le_adv_start(BT_LE_ADV_CONN, ad, ARRAY_SIZE(ad), NULL, 0);
	if (err) {
		FAIL("peripheral: bt_le_adv_start failed (%d)\n", err);
		return;
	}
	bs_trace_info_time(1, "peripheral: advertising as 'WrBsimLink'\n");

	WAIT_FOR_FLAG(flag_peer_connected);
	WAIT_FOR_FLAG(flag_notify_sent);
	WAIT_FOR_FLAG(flag_time_sync_received);
	WAIT_FOR_FLAG(flag_storage_list_handled);
	WAIT_FOR_FLAG(flag_storage_fetch_handled);
	PASS("peripheral: link + notify burst + time-sync + storage LIST + FETCH handled\n");
}
