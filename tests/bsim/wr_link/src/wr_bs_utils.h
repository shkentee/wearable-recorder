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

void wr_test_init(void);
void wr_test_tick(bs_time_t HW_device_time);

void wr_run_peripheral(void);
void wr_run_central(void);

#endif /* WR_BS_UTILS_H */
