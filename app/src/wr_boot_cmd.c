/*
 * USB CDC ACM bootloader-trigger listener.
 *
 * When the firmware receives the literal 4-byte string "boot" (followed
 * by '\n' or '\r') on the USB CDC ACM console, write the Adafruit nRF
 * UF2 bootloader magic value to GPREGRET and trigger a soft reset. The
 * Adafruit bootloader on the next boot reads GPREGRET and lands the
 * device in UF2 mass-storage mode for drag-drop firmware updates.
 *
 * Purpose: replaces the manual reset-button double-tap during bring-up.
 * Future flashes can be initiated entirely from PowerShell with
 *
 *   echo boot > COM8
 *
 * The physical double-tap path remains available — this listener is
 * additive and does not modify the bootloader itself.
 */

#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/reboot.h>
#include <hal/nrf_power.h>
#include <string.h>

LOG_MODULE_REGISTER(wr_boot_cmd, CONFIG_LOG_DEFAULT_LEVEL);

/* Adafruit nRF UF2 bootloader magic. Confirmed against the upstream
 * Adafruit_nRF52_Bootloader source (DFU_MAGIC_UF2_RESET = 0x57). */
#define ADAFRUIT_UF2_MAGIC 0x57

#define WR_BOOT_CMD_BUFFER 16

static char rx_buf[WR_BOOT_CMD_BUFFER];
static size_t rx_idx;

static void wr_boot_cmd_uart_cb(const struct device *dev, void *user_data)
{
	(void) user_data;

	if (!uart_irq_update(dev)) {
		return;
	}

	while (uart_irq_rx_ready(dev)) {
		uint8_t c;

		if (uart_fifo_read(dev, &c, 1) <= 0) {
			break;
		}

		if (c == '\n' || c == '\r') {
			rx_buf[rx_idx] = '\0';
			if (strcmp(rx_buf, "boot") == 0) {
				LOG_INF("wr_boot_cmd: 'boot' received - jumping to UF2 mode");
				/* Drain a moment so the LOG_INF lands on the host
				 * before the soft reset wipes the USB session. */
				k_sleep(K_MSEC(50));
				/* Use NRF_POWER directly: the GPREGRET write needs
				 * to be the last thing before NVIC_SystemReset, and
				 * the nrfx HAL inline helper is fine here. */
				NRF_POWER->GPREGRET = ADAFRUIT_UF2_MAGIC;
				sys_reboot(SYS_REBOOT_COLD);
			}
			rx_idx = 0;
		} else if (rx_idx < (WR_BOOT_CMD_BUFFER - 1)) {
			rx_buf[rx_idx++] = (char) c;
		} else {
			/* Buffer full without newline: discard and resync on next
			 * line break. */
			rx_idx = 0;
		}
	}
}

static int wr_boot_cmd_init(void)
{
	const struct device *console = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

	if (!device_is_ready(console)) {
		LOG_WRN("wr_boot_cmd: console device not ready, listener disabled");
		return 0;
	}

	uart_irq_callback_user_data_set(console, wr_boot_cmd_uart_cb, NULL);
	uart_irq_rx_enable(console);
	LOG_INF("wr_boot_cmd: listening for 'boot' on console");
	return 0;
}

/* APPLICATION 80: late enough that wr_msc_mode (50) has called
 * usb_enable() and the CDC ACM device is up. */
SYS_INIT(wr_boot_cmd_init, APPLICATION, 80);
