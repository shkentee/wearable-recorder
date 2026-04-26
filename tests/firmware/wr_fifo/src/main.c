/*
 * Phase 4-6+ wr_fifo_logic — unit tests for the pure helpers.
 */

#include <zephyr/ztest.h>
#include "wr_fifo_logic.h"

ZTEST_SUITE(wr_fifo_logic, NULL, NULL, NULL, NULL, NULL);

/* ========================================================================== */
/* wr_fifo_should_prune                                                        */
/* ========================================================================== */

ZTEST(wr_fifo_logic, test_prune_below_threshold_triggers)
{
	/* 5% free at 10% threshold → prune. */
	const uint64_t total = 100ULL * 1024 * 1024;
	zassert_true(wr_fifo_should_prune(total * 5 / 100, total, 10),
		     "5%% free should prune at 10%% threshold");
}

ZTEST(wr_fifo_logic, test_prune_above_threshold_skips)
{
	/* 15% free at 10% threshold → no prune. */
	const uint64_t total = 100ULL * 1024 * 1024;
	zassert_false(wr_fifo_should_prune(total * 15 / 100, total, 10),
		      "15%% free should NOT prune at 10%% threshold");
}

ZTEST(wr_fifo_logic, test_prune_at_threshold_skips)
{
	/* free * 100 == total * threshold → predicate is < not <= so skip. */
	const uint64_t total = 100ULL * 1024 * 1024;
	zassert_false(wr_fifo_should_prune(total * 10 / 100, total, 10),
		      "exactly threshold means NOT below, skip");
}

ZTEST(wr_fifo_logic, test_prune_full_disk_triggers)
{
	zassert_true(wr_fifo_should_prune(0, 1024 * 1024, 10),
		     "0%% free should always prune");
}

ZTEST(wr_fifo_logic, test_prune_zero_total_safe)
{
	zassert_false(wr_fifo_should_prune(0, 0, 10),
		      "uninitialized statvfs (total=0) must not prune");
}

ZTEST(wr_fifo_logic, test_prune_zero_threshold_disables)
{
	zassert_false(wr_fifo_should_prune(0, 1024, 0),
		      "0%% threshold disables FIFO entirely");
}

ZTEST(wr_fifo_logic, test_prune_huge_disk_no_overflow)
{
	/* 32 GB SD card; 5% free at 10% threshold. uint64_t avoids overflow. */
	const uint64_t total = 32ULL * 1024 * 1024 * 1024;
	zassert_true(wr_fifo_should_prune(total * 5 / 100, total, 10),
		     "32 GB / 5%% / 10%% should prune (no uint64 overflow)");
}

/* ========================================================================== */
/* wr_fifo_is_managed_chunk                                                    */
/* ========================================================================== */

ZTEST(wr_fifo_logic, test_managed_typical_chunk)
{
	zassert_true(wr_fifo_is_managed_chunk("chunk_00042.opus", "a01.txt"),
		     "chunk_*.opus is managed");
}

ZTEST(wr_fifo_logic, test_managed_skips_active_file)
{
	zassert_false(wr_fifo_is_managed_chunk("a01.txt", "a01.txt"),
		      "active file must NEVER be deleted");
}

ZTEST(wr_fifo_logic, test_managed_skips_non_chunk_files)
{
	zassert_false(wr_fifo_is_managed_chunk("readme.txt", "a01.txt"),
		      "foreign files (readme.txt) are not managed");
	zassert_false(wr_fifo_is_managed_chunk("Chunk_00001.opus", "a01.txt"),
		      "case-sensitive — Chunk_ ≠ chunk_");
	zassert_false(wr_fifo_is_managed_chunk("chunks_00001.opus", "a01.txt"),
		      "prefix mismatch — chunks_ ≠ chunk_");
}

ZTEST(wr_fifo_logic, test_managed_null_safe)
{
	zassert_false(wr_fifo_is_managed_chunk(NULL, "a01.txt"),
		      "NULL name must not crash");
	zassert_false(wr_fifo_is_managed_chunk("", "a01.txt"),
		      "empty name returns false");
}

ZTEST(wr_fifo_logic, test_managed_null_active_name_ok)
{
	zassert_true(wr_fifo_is_managed_chunk("chunk_00001.opus", NULL),
		     "NULL active_name → no active-file skip, but managed if matches");
}

/* ========================================================================== */
/* wr_fifo_compare_chunk                                                       */
/* ========================================================================== */

ZTEST(wr_fifo_logic, test_compare_orders_lex)
{
	zassert_true(wr_fifo_compare_chunk("chunk_00001.opus",
					   "chunk_00002.opus") < 0,
		     "00001 should sort before 00002");
}

ZTEST(wr_fifo_logic, test_compare_equal_returns_zero)
{
	zassert_equal(wr_fifo_compare_chunk("chunk_00001.opus",
					    "chunk_00001.opus"), 0,
		      "identical names compare equal");
}

ZTEST(wr_fifo_logic, test_compare_null_safe)
{
	zassert_equal(wr_fifo_compare_chunk(NULL, NULL), 0, "both NULL → 0");
	zassert_true(wr_fifo_compare_chunk(NULL, "x") > 0, "NULL > anything");
	zassert_true(wr_fifo_compare_chunk("x", NULL) < 0, "anything < NULL");
}
