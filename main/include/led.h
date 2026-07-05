/*
 * SPDX-FileCopyrightText: 2024 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 */
#ifndef LED_H
#define LED_H

/* Includes */
/* ESP APIs */
#include "driver/gpio.h"

/* Defines */
#define RED_LED_GPIO GPIO_NUM_7
#define YELLOW_LED_GPIO GPIO_NUM_8
#define GREEN_LED_GPIO GPIO_NUM_9

#define LED_CMD_OFF 0
#define LED_CMD_RED 1
#define LED_CMD_YELLOW 2
#define LED_CMD_GREEN 3

/* Public function declarations */
uint8_t get_led_state(void);
int led_apply_command(uint8_t command);
void led_init(void);

#endif // LED_H
