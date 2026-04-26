/*
 * Phase 5+ bsim smoke — peripheral that advertises the omi audio
 * service UUID for ~3 seconds, then exits cleanly.
 *
 * Purpose: prove that the bsim BLE build pipeline works under NCS by
 * compiling AND linking a Zephyr Bluetooth Host application against
 * the software-split LL controller (CONFIG_BT_LL_SW_SPLIT=y).
 *
 * Phase 6 will replace this with a two-device test (peripheral +
 * central) that exercises the actual chunk-push protocol; for now we
 * just need a green compile to unblock that work.
 */

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/printk.h>

LOG_MODULE_REGISTER(wr_bsim_smoke, LOG_LEVEL_INF);

/* omi audio service primary UUID (mirrors transport.c in third_party/omi). */
#define BT_UUID_OMI_AUDIO_SERVICE_VAL \
	BT_UUID_128_ENCODE(0x19B10000, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, BT_UUID_OMI_AUDIO_SERVICE_VAL),
};

int main(void)
{
	int err = bt_enable(NULL);
	if (err) {
		LOG_ERR("bt_enable failed: %d", err);
		return err;
	}
	LOG_INF("bt enabled, starting advertise");

	err = bt_le_adv_start(BT_LE_ADV_CONN, ad, ARRAY_SIZE(ad), NULL, 0);
	if (err) {
		LOG_ERR("bt_le_adv_start failed: %d", err);
		return err;
	}
	LOG_INF("advertising as 'WrBsimSmoke'");

	/* Run the simulation for a fixed window so the test exits cleanly
	 * without external orchestration. */
	k_sleep(K_SECONDS(3));

	(void)bt_le_adv_stop();
	LOG_INF("smoke complete");
	return 0;
}
