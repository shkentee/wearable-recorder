/*
 * Phase 5+ bsim wr_link — peripheral side.
 *
 * Advertise the omi audio service UUID, wait for the central to
 * connect (signalled by bt_conn_cb.connected), then PASS.
 */

#include "wr_bs_utils.h"

DEFINE_FLAG(flag_peer_connected);

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, BT_UUID_OMI_AUDIO_SERVICE_VAL),
};

static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		FAIL("peripheral: connection failed (%u)\n", err);
		return;
	}
	bs_trace_info_time(1, "peripheral: connected\n");
	SET_FLAG(flag_peer_connected);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	bs_trace_info_time(1, "peripheral: disconnected (reason 0x%02x)\n",
			   reason);
}

BT_CONN_CB_DEFINE(peripheral_cb) = {
	.connected = connected,
	.disconnected = disconnected,
};

void wr_run_peripheral(void)
{
	int err = bt_enable(NULL);
	if (err) {
		FAIL("peripheral: bt_enable failed (%d)\n", err);
		return;
	}

	err = bt_le_adv_start(BT_LE_ADV_CONN, ad, ARRAY_SIZE(ad), NULL, 0);
	if (err) {
		FAIL("peripheral: bt_le_adv_start failed (%d)\n", err);
		return;
	}
	bs_trace_info_time(1, "peripheral: advertising as 'WrBsimLink'\n");

	WAIT_FOR_FLAG(flag_peer_connected);
	PASS("peripheral: link established\n");
}
