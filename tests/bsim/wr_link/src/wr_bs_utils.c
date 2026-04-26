/*
 * Phase 5+ bsim wr_link — shared helpers (test framework hooks + flags).
 */

#include "wr_bs_utils.h"

#define BS_SECONDS(s)         ((bs_time_t)(s) * USEC_PER_SEC)
#define WR_LINK_SIM_TIMEOUT   BS_SECONDS(15)

void wr_test_init(void)
{
	bst_ticker_set_next_tick_absolute(WR_LINK_SIM_TIMEOUT);
	bst_result = In_progress;
}

void wr_test_tick(bs_time_t HW_device_time)
{
	if (bst_result != Passed) {
		bst_result = Failed;
		bs_trace_error_line(
			"wr_link: simulation timed out before role hit PASS()\n");
	}
}
