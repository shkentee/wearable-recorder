/*
 * Phase 5+ bsim wr_link — central side.
 *
 * Scan filtering on the omi audio service UUID, connect to the first
 * matching peer, wait for the connected event, then PASS.
 */

#include "wr_bs_utils.h"

DEFINE_FLAG(flag_central_connected);

static struct bt_conn *default_conn;

static bool eir_found(struct bt_data *data, void *user_data)
{
	bt_addr_le_t *addr = user_data;

	if (data->type != BT_DATA_UUID128_ALL && data->type != BT_DATA_UUID128_SOME) {
		return true;
	}
	if (data->data_len % BT_UUID_SIZE_128 != 0) {
		return true;
	}

	for (size_t i = 0; i < data->data_len; i += BT_UUID_SIZE_128) {
		const uint8_t want[] = { BT_UUID_OMI_AUDIO_SERVICE_VAL };
		if (memcmp(&data->data[i], want, BT_UUID_SIZE_128) != 0) {
			continue;
		}

		bs_trace_info_time(1, "central: found omi peer, connecting\n");
		int err = bt_le_scan_stop();
		if (err && err != -EALREADY) {
			FAIL("central: bt_le_scan_stop failed (%d)\n", err);
			return false;
		}
		err = bt_conn_le_create(addr, BT_CONN_LE_CREATE_CONN,
					BT_LE_CONN_PARAM_DEFAULT, &default_conn);
		if (err) {
			FAIL("central: bt_conn_le_create failed (%d)\n", err);
			return false;
		}
		return false; /* found, stop parsing */
	}
	return true;
}

static void device_found(const bt_addr_le_t *addr, int8_t rssi, uint8_t type,
			 struct net_buf_simple *ad)
{
	if (type != BT_GAP_ADV_TYPE_ADV_IND &&
	    type != BT_GAP_ADV_TYPE_ADV_DIRECT_IND) {
		return;
	}
	bt_data_parse(ad, eir_found, (void *)addr);
}

static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		FAIL("central: connection failed (%u)\n", err);
		return;
	}
	bs_trace_info_time(1, "central: connected\n");
	SET_FLAG(flag_central_connected);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	bs_trace_info_time(1, "central: disconnected (reason 0x%02x)\n",
			   reason);
	if (default_conn) {
		bt_conn_unref(default_conn);
		default_conn = NULL;
	}
}

BT_CONN_CB_DEFINE(central_cb) = {
	.connected = connected,
	.disconnected = disconnected,
};

void wr_run_central(void)
{
	int err = bt_enable(NULL);
	if (err) {
		FAIL("central: bt_enable failed (%d)\n", err);
		return;
	}

	struct bt_le_scan_param scan_param = {
		.type     = BT_LE_SCAN_TYPE_ACTIVE,
		.options  = BT_LE_SCAN_OPT_NONE,
		.interval = BT_GAP_SCAN_FAST_INTERVAL,
		.window   = BT_GAP_SCAN_FAST_WINDOW,
	};
	err = bt_le_scan_start(&scan_param, device_found);
	if (err) {
		FAIL("central: bt_le_scan_start failed (%d)\n", err);
		return;
	}
	bs_trace_info_time(1, "central: scanning for omi audio service\n");

	WAIT_FOR_FLAG(flag_central_connected);
	PASS("central: link established\n");
}
