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

#define WR_LINK_BURST_COUNT 5
#define WR_LINK_BURST_INTERVAL_MS 50

DEFINE_FLAG(flag_peer_connected);
DEFINE_FLAG(flag_notify_sent);

static struct bt_conn *peer_conn;
static struct k_work_delayable notify_work;
static uint16_t notify_seq;

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

	err = bt_le_adv_start(BT_LE_ADV_CONN, ad, ARRAY_SIZE(ad), NULL, 0);
	if (err) {
		FAIL("peripheral: bt_le_adv_start failed (%d)\n", err);
		return;
	}
	bs_trace_info_time(1, "peripheral: advertising as 'WrBsimLink'\n");

	WAIT_FOR_FLAG(flag_peer_connected);
	WAIT_FOR_FLAG(flag_notify_sent);
	PASS("peripheral: link + notify sent\n");
}
