/* Wearable Recorder — application entry point.
 *
 * Bring-up profile: blink the green LED, log over USB CDC ACM. Later
 * tasks add SD mount, BLE peripheral, audio capture, recording state
 * machine.
 */
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/device.h>

#include "led.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

#define BLINK_PERIOD_MS 500

static int wait_for_dtr(void)
{
	const struct device *uart = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
	if (!device_is_ready(uart)) {
		return -ENODEV;
	}
	uint32_t dtr = 0;
	/* Wait up to 5 s for a host to assert DTR; otherwise continue
	 * unconnected so the firmware doesn't hang during a power-only
	 * boot (no USB host attached). */
	for (int i = 0; i < 50 && !dtr; i++) {
		(void)uart_line_ctrl_get(uart, UART_LINE_CTRL_DTR, &dtr);
		k_msleep(100);
	}
	return 0;
}

int main(void)
{
	int ret = usb_enable(NULL);
	if (ret) {
		/* USB might already be enabled by another subsystem; that's fine. */
		LOG_WRN("usb_enable returned %d (continuing)", ret);
	}
	(void)wait_for_dtr();

	LOG_INF("=========================================");
	LOG_INF(" wearable-recorder firmware (scratch v0)");
	LOG_INF("=========================================");
	LOG_INF("Build: " __DATE__ " " __TIME__);

	if (wr_led_init() != 0) {
		LOG_ERR("LED init failed; halting");
		return 0;
	}

	uint32_t tick = 0;
	while (1) {
		wr_led_toggle();
		if ((tick % 10) == 0) {
			LOG_INF("alive tick=%u", tick);
		}
		tick++;
		k_msleep(BLINK_PERIOD_MS);
	}
	return 0;
}
