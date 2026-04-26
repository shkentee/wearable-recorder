/*
 * Phase 3 sanity test — proves the Twister + native_sim test loop works
 * end-to-end (build → run → assert) before we add real unit tests for the
 * けんた modifications (Plan B, FIFO delete, chunk rotation, MSC mode, LED).
 *
 * Replace this with real tests as Phase 4 lands each module.
 */

#include <zephyr/ztest.h>
#include <zephyr/sys/util.h>
#include <stdint.h>

ZTEST_SUITE(wr_sanity, NULL, NULL, NULL, NULL, NULL);

ZTEST(wr_sanity, test_arithmetic)
{
	zassert_equal(2 + 2, 4, "basic arithmetic broken — toolchain is wrong");
}

ZTEST(wr_sanity, test_fifo_threshold_predicate)
{
	/* Mirrors the predicate sd_fifo.c will use in Phase 4: trigger
	 * deletion when free fraction drops below the threshold. */
	const uint64_t total = 32ULL * 1024 * 1024 * 1024; /* 32 GiB */
	const uint8_t threshold_pct = 10;

	/* 5% free → should delete */
	uint64_t free_low = total * 5 / 100;
	zassert_true(free_low * 100 < total * threshold_pct,
		     "5%% free should trigger FIFO delete at 10%% threshold");

	/* 15% free → should NOT delete */
	uint64_t free_ok = total * 15 / 100;
	zassert_false(free_ok * 100 < total * threshold_pct,
		      "15%% free should NOT trigger delete at 10%% threshold");

	/* Exact 10% boundary → strict less-than means NOT trigger */
	uint64_t free_boundary = total * 10 / 100;
	zassert_false(free_boundary * 100 < total * threshold_pct,
		      "exact 10%% should be the no-delete side of the boundary");
}
