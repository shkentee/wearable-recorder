/*
 * Phase 5+ bsim wr_link — bs_tests entry point.
 *
 * Selects peripheral or central role from -testid, registers test
 * callbacks (init / tick / main), and hands control to bst_main().
 */

#include "wr_bs_utils.h"

static const struct bst_test_instance test_to_add[] = {
	{
		.test_id = "peripheral",
		.test_descr = "Advertise omi audio service, accept connection",
		.test_post_init_f = wr_test_init,
		.test_tick_f = wr_test_tick,
		.test_main_f = wr_run_peripheral,
	},
	{
		.test_id = "central",
		.test_descr = "Scan for omi audio service, connect",
		.test_post_init_f = wr_test_init,
		.test_tick_f = wr_test_tick,
		.test_main_f = wr_run_central,
	},
	BSTEST_END_MARKER,
};

static struct bst_test_list *install(struct bst_test_list *tests)
{
	return bst_add_tests(tests, test_to_add);
}

bst_test_install_t test_installers[] = { install, NULL };

int main(void)
{
	bst_main();
	return 0;
}
