/*
 * Phase 5+ bsim wr_link — shared helpers (test framework hooks + flags).
 *
 * Lifted from Zephyr's tests/bsim/bluetooth/host/adv/resume/src/bs_bt_utils.h
 * and trimmed to what wr_link needs. We intentionally avoid the
 * backchannel helpers — peripheral and central don't need to coordinate
 * out-of-band beyond the radio link itself.
 */

#ifndef WR_BS_UTILS_H
#define WR_BS_UTILS_H

#include "bs_tracing.h"
#include "bs_types.h"
#include "bstests.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/atomic.h>

extern enum bst_result_t bst_result;

#define DECLARE_FLAG(flag) extern atomic_t flag
#define DEFINE_FLAG(flag)  atomic_t flag = (atomic_t)false
#define SET_FLAG(flag)     ((void)atomic_set(&(flag), (atomic_t)true))
#define UNSET_FLAG(flag)   ((void)atomic_set(&(flag), (atomic_t)false))
#define WAIT_FOR_FLAG(flag) \
	while (!(bool)atomic_get(&(flag))) { \
		k_sleep(K_MSEC(1)); \
	}

#define FAIL(...) \
	do { \
		bst_result = Failed; \
		bs_trace_error_time_line(__VA_ARGS__); \
	} while (0)

#define PASS(...) \
	do { \
		bst_result = Passed; \
		bs_trace_info_time(1, __VA_ARGS__); \
	} while (0)

/* omi audio service primary UUID (mirrors transport.c). */
#define BT_UUID_OMI_AUDIO_SERVICE_VAL \
	BT_UUID_128_ENCODE(0x19B10000, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)
#define BT_UUID_OMI_AUDIO_SERVICE \
	BT_UUID_DECLARE_128(BT_UUID_OMI_AUDIO_SERVICE_VAL)

/* audioCodec characteristic (notify) — the path the firmware streams
 * Opus packets over (3 byte header + payload). For the bsim notify
 * exchange test we just notify a known short payload and verify the
 * central receives it. */
#define BT_UUID_OMI_AUDIO_CODEC_VAL \
	BT_UUID_128_ENCODE(0x19B10002, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)
#define BT_UUID_OMI_AUDIO_CODEC \
	BT_UUID_DECLARE_128(BT_UUID_OMI_AUDIO_CODEC_VAL)

/* Sentinel payload the peripheral notifies once after connect.
 * Mirrors omi packet header layout: packet_id LE16 + frame_id u8. */
#define WR_LINK_PROBE_PAYLOAD \
	{ 0x42, 0x00, 0x00, /* header: pkt 0x0042, frame 0 */ \
	  'A', 'B', 'C', 'D' /* dummy "Opus" payload */ }

/* D7 time-sync write characteristic (UUID 19B10005-...).
 * Service UUID doubles as the characteristic UUID — single-char service,
 * mirrors app/src/wr_time_sync.c. Central writes 8-byte LE64 Unix epoch;
 * peripheral echoes it back as a GATT indication and validates content. */
#define BT_UUID_WR_TIME_SYNC_VAL \
	BT_UUID_128_ENCODE(0x19B10005, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)
#define BT_UUID_WR_TIME_SYNC \
	BT_UUID_DECLARE_128(BT_UUID_WR_TIME_SYNC_VAL)

/* Fixed test epoch used by the central; peripheral validates the received value.
 * LE64 bytes: {0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01}. */
#define WR_LINK_TIME_SYNC_EPOCH 0x0102030405060708ULL

void wr_test_init(void);
void wr_test_tick(bs_time_t HW_device_time);

void wr_run_peripheral(void);
void wr_run_central(void);

#endif /* WR_BS_UTILS_H */
