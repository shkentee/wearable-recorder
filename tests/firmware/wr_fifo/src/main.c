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

/* ========================================================================== */
/* wr_fifo_classify (Phase 6)                                                  */
/* ========================================================================== */

ZTEST(wr_fifo_logic, test_classify_legacy_chunk)
{
	zassert_equal(wr_fifo_classify("chunk_00001.opus"),
		      WR_FIFO_KIND_LEGACY,
		      "chunk_NNNNN.opus is LEGACY");
	zassert_equal(wr_fifo_classify("chunk_99999.opus"),
		      WR_FIFO_KIND_LEGACY,
		      "high seq chunk_*.opus is still LEGACY");
}

ZTEST(wr_fifo_logic, test_classify_unsynced)
{
	zassert_equal(wr_fifo_classify("unsynced_0a1b2c3d_00001.opus"),
		      WR_FIFO_KIND_UNSYNCED,
		      "unsynced_<bootid>_<seq>.opus is UNSYNCED");
	zassert_equal(wr_fifo_classify("unsynced_ffffffff_99999.opus"),
		      WR_FIFO_KIND_UNSYNCED,
		      "max boot_id/seq still UNSYNCED");
}

ZTEST(wr_fifo_logic, test_classify_epoch_typical)
{
	zassert_equal(wr_fifo_classify("1234567890.opus"),
		      WR_FIFO_KIND_EPOCH,
		      "10-digit unix-secs is EPOCH");
}

ZTEST(wr_fifo_logic, test_classify_epoch_zero)
{
	zassert_equal(wr_fifo_classify("0000000000.opus"),
		      WR_FIFO_KIND_EPOCH,
		      "zero-padded 10-digit zero is EPOCH");
}

ZTEST(wr_fifo_logic, test_classify_epoch_max)
{
	zassert_equal(wr_fifo_classify("9999999999.opus"),
		      WR_FIFO_KIND_EPOCH,
		      "10-digit max is EPOCH");
}

ZTEST(wr_fifo_logic, test_classify_short_digits_unknown)
{
	zassert_equal(wr_fifo_classify("123456789.opus"),
		      WR_FIFO_KIND_UNKNOWN,
		      "9 digits does not match epoch format");
	zassert_equal(wr_fifo_classify("12345678901.opus"),
		      WR_FIFO_KIND_UNKNOWN,
		      "11 digits does not match epoch format");
}

ZTEST(wr_fifo_logic, test_classify_garbage_unknown)
{
	zassert_equal(wr_fifo_classify("abc.opus"),
		      WR_FIFO_KIND_UNKNOWN,
		      "non-digit basename is UNKNOWN");
	zassert_equal(wr_fifo_classify("readme.txt"),
		      WR_FIFO_KIND_UNKNOWN,
		      "foreign file is UNKNOWN");
	zassert_equal(wr_fifo_classify("123456789a.opus"),
		      WR_FIFO_KIND_UNKNOWN,
		      "10 chars but not all digits is UNKNOWN");
}

ZTEST(wr_fifo_logic, test_classify_chunkfoo_unknown)
{
	zassert_equal(wr_fifo_classify("chunkfoo.opus"),
		      WR_FIFO_KIND_UNKNOWN,
		      "chunkfoo (no underscore) is not LEGACY");
}

ZTEST(wr_fifo_logic, test_classify_null_and_empty)
{
	zassert_equal(wr_fifo_classify(NULL), WR_FIFO_KIND_UNKNOWN,
		      "NULL is UNKNOWN");
	zassert_equal(wr_fifo_classify(""), WR_FIFO_KIND_UNKNOWN,
		      "empty string is UNKNOWN");
}

/* ========================================================================== */
/* wr_fifo_compare_priority (Phase 6)                                          */
/* ========================================================================== */

ZTEST(wr_fifo_logic, test_compare_priority_legacy_vs_legacy)
{
	zassert_true(wr_fifo_compare_priority("chunk_00001.opus",
					      "chunk_00002.opus") < 0,
		     "within LEGACY, lower seq is older");
	zassert_true(wr_fifo_compare_priority("chunk_00010.opus",
					      "chunk_00002.opus") > 0,
		     "within LEGACY, higher seq is newer");
}

ZTEST(wr_fifo_logic, test_compare_priority_unsynced_vs_unsynced)
{
	zassert_true(wr_fifo_compare_priority("unsynced_0a1b2c3d_00001.opus",
					      "unsynced_0a1b2c3d_00002.opus") < 0,
		     "within UNSYNCED, lower seq is older (same boot_id)");
}

ZTEST(wr_fifo_logic, test_compare_priority_epoch_vs_epoch)
{
	zassert_true(wr_fifo_compare_priority("1234567890.opus",
					      "1234567899.opus") < 0,
		     "within EPOCH, smaller unix-secs is older");
	zassert_true(wr_fifo_compare_priority("0000000001.opus",
					      "9999999999.opus") < 0,
		     "EPOCH zero vs max — zero older");
}

ZTEST(wr_fifo_logic, test_compare_priority_legacy_before_unsynced)
{
	zassert_true(wr_fifo_compare_priority("chunk_99999.opus",
					      "unsynced_00000000_00000.opus") < 0,
		     "LEGACY always deleted before UNSYNCED");
	zassert_true(wr_fifo_compare_priority("unsynced_00000000_00000.opus",
					      "chunk_99999.opus") > 0,
		     "symmetric: UNSYNCED is newer than any LEGACY");
}

ZTEST(wr_fifo_logic, test_compare_priority_legacy_before_epoch)
{
	zassert_true(wr_fifo_compare_priority("chunk_99999.opus",
					      "1234567890.opus") < 0,
		     "LEGACY always deleted before EPOCH");
	zassert_true(wr_fifo_compare_priority("9999999999.opus",
					      "chunk_00001.opus") > 0,
		     "symmetric: EPOCH is newer than any LEGACY");
}

ZTEST(wr_fifo_logic, test_compare_priority_unsynced_before_epoch)
{
	zassert_true(wr_fifo_compare_priority("unsynced_ffffffff_99999.opus",
					      "0000000000.opus") < 0,
		     "UNSYNCED always deleted before EPOCH (no real timestamp)");
	zassert_true(wr_fifo_compare_priority("9999999999.opus",
					      "unsynced_00000000_00000.opus") > 0,
		     "symmetric: EPOCH is newer than any UNSYNCED");
}

ZTEST(wr_fifo_logic, test_compare_priority_null_safe)
{
	zassert_equal(wr_fifo_compare_priority(NULL, NULL), 0,
		      "both NULL → 0");
	zassert_true(wr_fifo_compare_priority(NULL, "chunk_00001.opus") > 0,
		     "NULL > anything (sorts last, never deleted)");
	zassert_true(wr_fifo_compare_priority("chunk_00001.opus", NULL) < 0,
		     "anything < NULL");
}
