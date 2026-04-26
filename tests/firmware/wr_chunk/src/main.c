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
