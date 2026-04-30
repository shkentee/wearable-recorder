/*
 * Dedicated watchdog-feeder thread.
 *
 * Bring-up note 2026-04-30: even after wiring watchdog_feed() into both
 * the main loop and pusher, the device kept WDT-resetting 30 s after
 * every BLE CONNECT. The trigger is something on the BT host stack path
 * that simultaneously blocks the threads that were feeding the dog.
 *
 * Spin up a stand-alone thread whose only job is to sleep and call
 * watchdog_feed. It depends on nothing beyond k_msleep returning, so it
 * keeps the device alive even when other threads are wedged. This lets
 * us continue debugging the underlying BT issue without the device
 * resetting out from under us every 30 s.
 *
 * Once the BT issue is fully fixed this thread can stay as defence in
 * depth or be removed.
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(wr_wdt_feeder, CONFIG_LOG_DEFAULT_LEVEL);

extern void watchdog_feed(void);

/* WDT timeout default is 30 000 ms. Feed every 1 000 ms — gives 30 misses
 * of headroom even if this thread is briefly preempted. */
#define WR_WDT_FEEDER_PERIOD_MS 1000

#define WR_WDT_FEEDER_STACK_SIZE 512
K_THREAD_STACK_DEFINE(wr_wdt_feeder_stack, WR_WDT_FEEDER_STACK_SIZE);
static struct k_thread wr_wdt_feeder_thread;

static void wr_wdt_feeder_entry(void *p1, void *p2, void *p3)
{
	(void) p1; (void) p2; (void) p3;
	LOG_INF("wr_wdt_feeder: armed (period %d ms)", WR_WDT_FEEDER_PERIOD_MS);
	while (1) {
		watchdog_feed();
		k_msleep(WR_WDT_FEEDER_PERIOD_MS);
	}
}

static int wr_wdt_feeder_init(void)
{
	/* Use cooperative priority so this thread is not pre-empted by other
	 * preemptive threads — it should run to its k_msleep no matter what.
	 * K_PRIO_COOP(2) is high enough to slip past most preemptive workers
	 * but below the BT controller / log thread cooperative priorities so
	 * we don't disturb their timing. */
	k_thread_create(&wr_wdt_feeder_thread,
			wr_wdt_feeder_stack,
			K_THREAD_STACK_SIZEOF(wr_wdt_feeder_stack),
			wr_wdt_feeder_entry,
			NULL, NULL, NULL,
			K_PRIO_COOP(2),
			0,
			K_NO_WAIT);
	k_thread_name_set(&wr_wdt_feeder_thread, "wr_wdt_feeder");
	return 0;
}

/* APPLICATION 60: after wr_msc_mode (50) and wdog_facade (which is part
 * of main()'s init), but during SYS_INIT so it starts early. */
SYS_INIT(wr_wdt_feeder_init, APPLICATION, 60);
