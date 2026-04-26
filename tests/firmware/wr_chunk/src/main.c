/*
 * Phase 4-6+ wr_chunk_logic — unit tests for the pure helpers.
 *
 * Same recipe as the wr_led_pick suite: link the no-Zephyr-deps logic
 * file straight into a native_sim ztest binary and assert behavior on
 * the boundary cases.
 */

#include <zephyr/ztest.h>
#include <string.h>
#include "wr_chunk_logic.h"

ZTEST_SUITE(wr_chunk_logic, NULL, NULL, NULL, NULL, NULL);

/* ========================================================================== */
/* wr_chunk_format_name                                                        */
/* ========================================================================== */

ZTEST(wr_chunk_logic, test_format_name_zero)
{
	char buf[48];
	int n = wr_chunk_format_name(0, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf, "/SD:/audio/chunk_00000.opus"), 0,
		      "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_name_typical)
{
	char buf[48];
	int n = wr_chunk_format_name(42, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf, "/SD:/audio/chunk_00042.opus"), 0,
		      "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_name_max_5digits)
{
	char buf[48];
	int n = wr_chunk_format_name(99999, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf, "/SD:/audio/chunk_99999.opus"), 0,
		      "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_name_wraps_above_100k)
{
	/* 100000 wraps back to 00000, runtime probes for collision. */
	char buf[48];
	int n = wr_chunk_format_name(100000, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf, "/SD:/audio/chunk_00000.opus"), 0,
		      "got '%s'", buf);

	n = wr_chunk_format_name(100007, buf, sizeof(buf));
	zassert_equal(strcmp(buf, "/SD:/audio/chunk_00007.opus"), 0,
		      "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_name_buf_too_small_returns_minus_one)
{
	char tiny[10];
	int n = wr_chunk_format_name(1, tiny, sizeof(tiny));
	zassert_equal(n, -1, "expected -1 for tiny buf, got %d", n);
}

ZTEST(wr_chunk_logic, test_format_name_null_buf_safe)
{
	int n = wr_chunk_format_name(1, NULL, 64);
	zassert_equal(n, -1, "expected -1 for NULL buf, got %d", n);
}

ZTEST(wr_chunk_logic, test_format_name_zero_size_safe)
{
	char buf[8];
	int n = wr_chunk_format_name(1, buf, 0);
	zassert_equal(n, -1, "expected -1 for zero size, got %d", n);
}

/* ========================================================================== */
/* wr_chunk_should_rotate                                                      */
/* ========================================================================== */

ZTEST(wr_chunk_logic, test_should_rotate_with_data)
{
	zassert_true(wr_chunk_should_rotate(0, 1024),
		     "file with data should rotate");
	zassert_true(wr_chunk_should_rotate(0, 1),
		     "file with even 1 byte should rotate");
}

ZTEST(wr_chunk_logic, test_should_skip_when_empty)
{
	zassert_false(wr_chunk_should_rotate(0, 0),
		      "empty file should be skipped (no-op rotation)");
}

ZTEST(wr_chunk_logic, test_should_skip_when_missing)
{
	zassert_false(wr_chunk_should_rotate(-2, 0),
		      "missing file (ENOENT) should be skipped");
	zassert_false(wr_chunk_should_rotate(-2, 9999),
		      "stat err overrides any garbage size");
}

/* ========================================================================== */
/* wr_chunk_format_epoch_name                                                  */
/* ========================================================================== */

ZTEST(wr_chunk_logic, test_format_epoch_name_zero)
{
	char buf[48];
	int n = wr_chunk_format_epoch_name(0, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf, "/SD:/audio/0000000000.opus"), 0,
		      "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_epoch_name_typical)
{
	char buf[48];
	int n = wr_chunk_format_epoch_name(1234U, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf, "/SD:/audio/0000001234.opus"), 0,
		      "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_epoch_name_max_10digits)
{
	char buf[48];
	int n = wr_chunk_format_epoch_name(9999999999ULL, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf, "/SD:/audio/9999999999.opus"), 0,
		      "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_epoch_name_wraps_at_1e10)
{
	char buf[48];
	int n = wr_chunk_format_epoch_name(10000000000ULL, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf, "/SD:/audio/0000000000.opus"), 0,
		      "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_epoch_name_buf_too_small)
{
	char tiny[10];
	int n = wr_chunk_format_epoch_name(1, tiny, sizeof(tiny));
	zassert_equal(n, -1, "expected -1 for tiny buf, got %d", n);
}

ZTEST(wr_chunk_logic, test_format_epoch_name_null_safe)
{
	int n = wr_chunk_format_epoch_name(1, NULL, 64);
	zassert_equal(n, -1, "expected -1 for NULL buf, got %d", n);
}

ZTEST(wr_chunk_logic, test_format_epoch_name_zero_size_safe)
{
	char buf[8];
	int n = wr_chunk_format_epoch_name(1, buf, 0);
	zassert_equal(n, -1, "expected -1 for zero size, got %d", n);
}

/* ========================================================================== */
/* wr_chunk_make_boot_id                                                       */
/* ========================================================================== */

ZTEST(wr_chunk_logic, test_make_boot_id_both_zero)
{
	zassert_equal(wr_chunk_make_boot_id(0, 0), 0U,
		      "all-zero inputs must yield 0");
}

ZTEST(wr_chunk_logic, test_make_boot_id_only_hwrng)
{
	zassert_equal(wr_chunk_make_boot_id(0, 0xCAFEBABEU), 0xCAFEBABEU,
		      "hwrng-only should pass through");
}

ZTEST(wr_chunk_logic, test_make_boot_id_only_cycles)
{
	/* 0x1234_5678_0000 >> 16 == 0x1234_5678 */
	uint64_t cycles = 0x123456780000ULL;
	zassert_equal(wr_chunk_make_boot_id(cycles, 0), 0x12345678U,
		      "cycles>>16 should be exposed in low 32 bits");
}

ZTEST(wr_chunk_logic, test_make_boot_id_xor_mix)
{
	uint64_t cycles = 0x123456780000ULL; /* >>16 == 0x12345678 */
	uint32_t hwrng = 0xFF00FF00U;
	uint32_t expected = 0x12345678U ^ 0xFF00FF00U;
	zassert_equal(wr_chunk_make_boot_id(cycles, hwrng), expected,
		      "expected XOR mix of shifted cycles and hwrng");
}

ZTEST(wr_chunk_logic, test_make_boot_id_distinct_inputs_distinct_outputs)
{
	uint32_t a = wr_chunk_make_boot_id(0x10000ULL, 0x1U);
	uint32_t b = wr_chunk_make_boot_id(0x20000ULL, 0x1U);
	zassert_not_equal(a, b,
			  "different cycles should generally yield different ids");
}

/* ========================================================================== */
/* wr_chunk_format_unsynced_name                                               */
/* ========================================================================== */

ZTEST(wr_chunk_logic, test_format_unsynced_name_typical)
{
	char buf[64];
	int n = wr_chunk_format_unsynced_name(0x0a1b2c3dU, 42, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf,
			     "/SD:/audio/unsynced_0a1b2c3d_00042.opus"),
		      0, "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_unsynced_name_zeros)
{
	char buf[64];
	int n = wr_chunk_format_unsynced_name(0, 0, buf, sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf,
			     "/SD:/audio/unsynced_00000000_00000.opus"),
		      0, "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_unsynced_name_seq_wraps)
{
	char buf[64];
	int n = wr_chunk_format_unsynced_name(0xdeadbeefU, 100007, buf,
					      sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf,
			     "/SD:/audio/unsynced_deadbeef_00007.opus"),
		      0, "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_unsynced_name_max_hex)
{
	char buf[64];
	int n = wr_chunk_format_unsynced_name(0xffffffffU, 99999, buf,
					      sizeof(buf));
	zassert_true(n > 0, "format failed (%d)", n);
	zassert_equal(strcmp(buf,
			     "/SD:/audio/unsynced_ffffffff_99999.opus"),
		      0, "got '%s'", buf);
}

ZTEST(wr_chunk_logic, test_format_unsynced_name_buf_too_small)
{
	char tiny[16];
	int n = wr_chunk_format_unsynced_name(0x1, 1, tiny, sizeof(tiny));
	zassert_equal(n, -1, "expected -1 for tiny buf, got %d", n);
}

ZTEST(wr_chunk_logic, test_format_unsynced_name_null_safe)
{
	int n = wr_chunk_format_unsynced_name(0x1, 1, NULL, 64);
	zassert_equal(n, -1, "expected -1 for NULL buf, got %d", n);
}

ZTEST(wr_chunk_logic, test_format_unsynced_name_zero_size_safe)
{
	char buf[8];
	int n = wr_chunk_format_unsynced_name(0x1, 1, buf, 0);
	zassert_equal(n, -1, "expected -1 for zero size, got %d", n);
}

/* ========================================================================== */
/* wr_chunk_should_rotate_size                                                 */
/* ========================================================================== */

ZTEST(wr_chunk_logic, test_should_rotate_size_above_threshold)
{
	zassert_true(wr_chunk_should_rotate_size(3 * 1024 * 1024,
						 2 * 1024 * 1024),
		     "3MB > 2MB threshold should rotate");
}

ZTEST(wr_chunk_logic, test_should_rotate_size_at_threshold)
{
	zassert_true(wr_chunk_should_rotate_size(2 * 1024 * 1024,
						 2 * 1024 * 1024),
		     "exact-threshold size should rotate (>=)");
}

ZTEST(wr_chunk_logic, test_should_rotate_size_below_threshold)
{
	zassert_false(wr_chunk_should_rotate_size((2 * 1024 * 1024) - 1,
						  2 * 1024 * 1024),
		      "below threshold should not rotate");
}

ZTEST(wr_chunk_logic, test_should_rotate_size_zero_threshold_disabled)
{
	zassert_false(wr_chunk_should_rotate_size(0, 0),
		      "zero threshold disables size-based rotation");
	zassert_false(wr_chunk_should_rotate_size(UINT64_MAX, 0),
		      "zero threshold disables even with huge file");
}

ZTEST(wr_chunk_logic, test_should_rotate_size_zero_file)
{
	zassert_false(wr_chunk_should_rotate_size(0, 1),
		      "empty file vs 1B threshold should not rotate");
}
