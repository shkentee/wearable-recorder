#include "wr_battery.h"

uint16_t wr_battery_raw_to_mv(int16_t raw_adc)
{
	if (raw_adc <= 0) {
		return 0;
	}
	/* raw * 4800 / 4096; use 32-bit to avoid overflow (max: 4095 * 4800 = ~19.6M). */
	return (uint16_t)(((uint32_t)(uint16_t)raw_adc * 4800U) / 4096U);
}

uint8_t wr_battery_mv_to_pct(uint16_t vbat_mv)
{
	if (vbat_mv <= 3000U) {
		return 0;
	}
	if (vbat_mv >= 4200U) {
		return 100;
	}
	/* Linear interpolation in the 1200 mV window. */
	return (uint8_t)(((uint32_t)(vbat_mv - 3000U) * 100U) / 1200U);
}
