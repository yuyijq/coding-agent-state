/*
 * SPDX-FileCopyrightText: 2024 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 */
/* Includes */
#include "led.h"
#include "common.h"

/* Private variables */
static uint8_t led_state;

/* Public functions */
uint8_t get_led_state(void) { return led_state; }

int led_apply_command(uint8_t command) {
    switch (command) {
    case LED_CMD_OFF:
        gpio_set_level(RED_LED_GPIO, false);
        gpio_set_level(YELLOW_LED_GPIO, false);
        gpio_set_level(GREEN_LED_GPIO, false);
        break;
    case LED_CMD_RED:
        gpio_set_level(RED_LED_GPIO, true);
        gpio_set_level(YELLOW_LED_GPIO, false);
        gpio_set_level(GREEN_LED_GPIO, false);
        break;
    case LED_CMD_YELLOW:
        gpio_set_level(RED_LED_GPIO, false);
        gpio_set_level(YELLOW_LED_GPIO, true);
        gpio_set_level(GREEN_LED_GPIO, false);
        break;
    case LED_CMD_GREEN:
        gpio_set_level(RED_LED_GPIO, false);
        gpio_set_level(YELLOW_LED_GPIO, false);
        gpio_set_level(GREEN_LED_GPIO, true);
        break;
    default:
        return -1;
    }

    led_state = command;
    return 0;
}

void led_init(void) {
    ESP_LOGD(TAG, "LEDs configured: red=%d yellow=%d green=%d", RED_LED_GPIO,
             YELLOW_LED_GPIO, GREEN_LED_GPIO);

    gpio_reset_pin(RED_LED_GPIO);
    gpio_reset_pin(YELLOW_LED_GPIO);
    gpio_reset_pin(GREEN_LED_GPIO);

    gpio_set_direction(RED_LED_GPIO, GPIO_MODE_OUTPUT);
    gpio_set_direction(YELLOW_LED_GPIO, GPIO_MODE_OUTPUT);
    gpio_set_direction(GREEN_LED_GPIO, GPIO_MODE_OUTPUT);

    ESP_ERROR_CHECK(gpio_sleep_sel_dis(RED_LED_GPIO));
    ESP_ERROR_CHECK(gpio_sleep_sel_dis(YELLOW_LED_GPIO));
    ESP_ERROR_CHECK(gpio_sleep_sel_dis(GREEN_LED_GPIO));

    led_apply_command(LED_CMD_OFF);
}
