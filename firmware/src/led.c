/* Status LED driver — single GPIO LED, active low.
 *
 * On XIAO BLE Sense the green LED is led1 (P0.30, GPIO_ACTIVE_LOW).
 * We drive it as a status indicator: bring-up blink, then later
 * idle/connected/recording patterns from recorder.c.
 */
#include "led.h"

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(wr_led, LOG_LEVEL_INF);

#define WR_LED_NODE DT_ALIAS(led1)

static const struct gpio_dt_spec led_spec = GPIO_DT_SPEC_GET(WR_LED_NODE, gpios);

int wr_led_init(void)
{
	if (!gpio_is_ready_dt(&led_spec)) {
		LOG_ERR("LED GPIO not ready");
		return -ENODEV;
	}
	int ret = gpio_pin_configure_dt(&led_spec, GPIO_OUTPUT_INACTIVE);
	if (ret < 0) {
		LOG_ERR("LED gpio_pin_configure_dt: %d", ret);
		return ret;
	}
	LOG_INF("LED initialised (green, %s pin %u)", led_spec.port->name, led_spec.pin);
	return 0;
}

int wr_led_set(bool on)
{
	return gpio_pin_set_dt(&led_spec, on ? 1 : 0);
}

int wr_led_toggle(void)
{
	return gpio_pin_toggle_dt(&led_spec);
}
