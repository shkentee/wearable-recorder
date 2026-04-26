/*
 * Pure ADC → battery-percent helpers for the XIAO Sense (nRF52840).
 *
 * Hardware: VBATT/2 resistor divider → P0.31 → SAADC
 * SAADC config: gain=1/4, Vref=0.6V (internal), 12-bit, acquisition=10 µs.
 *
 * These functions have no Zephyr dependencies and are ztest-able on
 * native_sim. The Zephyr glue (SAADC DT node + adc_read()) lives in
 * wr_led_status.c which calls wr_battery_raw_to_mv() and then passes
 * the result to wr_led_status_set_batt_pct().
 */

#ifndef WR_BATTERY_H
#define WR_BATTERY_H

#include <stdint.h>

/*
 * Convert a 12-bit SAADC raw sample to battery voltage in mV.
 *
 * Derivation (SAADC gain=1/4, Vref=0.6 V, 12-bit = 4096 counts):
 *   Full-scale input voltage = Vref / gain = 0.6 / 0.25 = 2.4 V
 *   Voltage at ADC pin       = raw * 2400 mV / 4096
 *   Actual VBATT             = pin voltage * 2  (divider ratio)
 *   → vbat_mv                = raw * 4800 / 4096
 */
uint16_t wr_battery_raw_to_mv(int16_t raw_adc);

/*
 * Map battery voltage to state-of-charge percent [0, 100].
 *
 * Linear LiPo model: 3000 mV → 0 %, 4200 mV → 100 %.
 * Clamped at both ends so out-of-range inputs never underflow/overflow.
 */
uint8_t wr_battery_mv_to_pct(uint16_t vbat_mv);

#endif /* WR_BATTERY_H */
