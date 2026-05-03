#ifndef WR_LED_H
#define WR_LED_H

#include <stdbool.h>

/* Initialise the status LED (green). Returns 0 on success. */
int wr_led_init(void);

/* Drive the LED on/off explicitly. */
int wr_led_set(bool on);

/* Toggle the LED (used during bring-up blink). */
int wr_led_toggle(void);

#endif /* WR_LED_H */
