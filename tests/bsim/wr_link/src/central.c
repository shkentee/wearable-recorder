/*
 * Phase 5+ bsim wr_link — central side.
 *
 * Scan + connect, then discover the omi audio service, find the
 * audioCodec characteristic, subscribe to its notify, and PASS as
 * soon as the first notify arrives.
 *
 * Connection callbacks are registered with bt_conn_cb_register() at
 * runtime (not BT_CONN_CB_DEFINE()) so they only fire on the binary
 * actually running the central role — see peripheral.c for the
 * background.
 */

#include "wr_bs_utils.h"

#include <zephyr/bluetooth/gatt.h>

DEFINE_FLAG(flag_central_connected);
DEFINE_FLAG(flag_audio_subscribed);
DEFINE_FLAG(flag_notify_received);

static struct bt_conn *default_conn;

static struct bt_gatt_discover_params discover_params;
static struct bt_gatt_subscribe_params sub_params;

static uint8_t notify_cb(struct bt_conn *conn,
			 struct bt_gatt_subscribe_params *params,
			 const void *data, uint16_t length)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(params);
	if (data == NULL) {
		bs_trace_info_time(1, "central: subscription tore down\n");
		return BT_GATT_ITER_STOP;
	}
	bs_trace_info_time(1, "central: notify received (%u bytes)\n",
			   (unsigned)length);
	SET_FLAG(flag_notify_received);
	return BT_GATT_ITER_STOP;
}

static uint8_t discover_cb(struct bt_conn *conn,
			   const struct bt_gatt_attr *attr,
			   struct bt_gatt_discover_params *params)
{
	if (!attr) {
		FAIL("central: discovery completed without finding audioCodec\n");
		return BT_GATT_ITER_STOP;
	}

	/* Walk all chrc declarations. attr->user_data is bt_gatt_chrc;
	 * its uuid is the chrc value's UUID (the one we care about).
	 * Mirrors zephyr/tests/bsim/bluetooth/host/gatt/notify pattern. */
	const struct bt_gatt_chrc *chrc = attr->user_data;
	if (bt_uuid_cmp(chrc->uuid, BT_UUID_OMI_AUDIO_CODEC) != 0) {
		return BT_GATT_ITER_CONTINUE;
	}

	bs_trace_info_time(1, "central: found audioCodec chrc, value_handle=%u\n",
			   chrc->value_handle);
	sub_params.notify = notify_cb;
	sub_params.value = BT_GATT_CCC_NOTIFY;
	sub_params.value_handle = chrc->value_handle;
	/* CCC sits one handle past the chrc value attribute. */
	sub_params.ccc_handle = chrc->value_handle + 1;
	int err = bt_gatt_subscribe(conn, &sub_params);
	if (err && err != -EALREADY) {
		FAIL("central: subscribe failed (%d)\n", err);
		return BT_GATT_ITER_STOP;
	}
	SET_FLAG(flag_audio_subscribed);
	return BT_GATT_ITER_STOP;
}

static void start_discovery(struct bt_conn *conn)
{
	/* Walk all characteristics (uuid=NULL) across the connection's
	 * GATT db; the callback filters by chrc->uuid. This matches
	 * Zephyr's own bsim/host/gatt/notify reference test. */
	discover_params.uuid = NULL;
	discover_params.func = discover_cb;
	discover_params.start_handle = BT_ATT_FIRST_ATTRIBUTE_HANDLE;
	discover_params.end_handle = BT_ATT_LAST_ATTRIBUTE_HANDLE;
	discover_params.type = BT_GATT_DISCOVER_CHARACTERISTIC;

	int err = bt_gatt_discover(conn, &discover_params);
	if (err) {
		FAIL("central: bt_gatt_discover failed (%d)\n", err);
	}
}

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
		return false;
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

static void central_connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		FAIL("central: connection failed (%u)\n", err);
		return;
	}
	bs_trace_info_time(1, "central: connected, starting discovery\n");
	SET_FLAG(flag_central_connected);
	start_discovery(conn);
}

static void central_disconnected(struct bt_conn *conn, uint8_t reason)
{
	bs_trace_info_time(1, "central: disconnected (reason 0x%02x)\n",
			   reason);
	if (default_conn) {
		bt_conn_unref(default_conn);
		default_conn = NULL;
	}
}

static struct bt_conn_cb central_cb = {
	.connected = central_connected,
	.disconnected = central_disconnected,
};

void wr_run_central(void)
{
	int err = bt_enable(NULL);
	if (err) {
		FAIL("central: bt_enable failed (%d)\n", err);
		return;
	}
	bt_conn_cb_register(&central_cb);

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
	WAIT_FOR_FLAG(flag_audio_subscribed);
	WAIT_FOR_FLAG(flag_notify_received);
	PASS("central: link + audio notify received\n");
}
