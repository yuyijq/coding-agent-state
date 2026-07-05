/*
 * SPDX-FileCopyrightText: 2026
 *
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 */
/* Includes */
#include "sleep_manager.h"
#include "common.h"
#include "esp_attr.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "led.h"

#include <inttypes.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

/* Defines */
#define SLEEP_START_HOUR 0
#define SLEEP_END_HOUR 8
#define SECONDS_PER_MINUTE 60
#define SECONDS_PER_HOUR (60 * SECONDS_PER_MINUTE)
#define SECONDS_PER_DAY (24 * SECONDS_PER_HOUR)
#define MICROSECONDS_PER_SECOND 1000000ULL
#define PLANNED_WAKEUP_MAGIC 0x5A17C001U

/* Private function declarations */
static void deep_sleep_timer_cb(void *arg);
static void schedule_next_sleep(void);
static uint32_t seconds_since_midnight(const struct tm *timeinfo);
static uint64_t seconds_until_hour(const struct tm *timeinfo, int hour);
static void enter_scheduled_deep_sleep(uint64_t sleep_seconds);

/* Private variables */
static esp_timer_handle_t deep_sleep_timer;
static bool time_is_valid;
static RTC_DATA_ATTR uint32_t planned_wakeup_magic;
static RTC_DATA_ATTR uint64_t planned_wakeup_unix_time;

/* Private functions */
static void deep_sleep_timer_cb(void *arg) {
    (void)arg;
    schedule_next_sleep();
}

static uint32_t seconds_since_midnight(const struct tm *timeinfo) {
    return (uint32_t)timeinfo->tm_hour * SECONDS_PER_HOUR +
           (uint32_t)timeinfo->tm_min * SECONDS_PER_MINUTE +
           (uint32_t)timeinfo->tm_sec;
}

static uint64_t seconds_until_hour(const struct tm *timeinfo, int hour) {
    const uint32_t now = seconds_since_midnight(timeinfo);
    const uint32_t target = (uint32_t)hour * SECONDS_PER_HOUR;

    if (now < target) {
        return target - now;
    }

    return SECONDS_PER_DAY - now + target;
}

static void enter_scheduled_deep_sleep(uint64_t sleep_seconds) {
    if (sleep_seconds == 0) {
        sleep_seconds = 1;
    }

    ESP_LOGI(TAG, "entering deep sleep for %" PRIu64 " seconds", sleep_seconds);
    time_t now;
    if (time(&now) != (time_t)-1) {
        planned_wakeup_unix_time = (uint64_t)now + sleep_seconds;
        planned_wakeup_magic = PLANNED_WAKEUP_MAGIC;
    } else {
        planned_wakeup_unix_time = 0;
        planned_wakeup_magic = 0;
    }

    led_apply_command(LED_CMD_OFF);
    ESP_ERROR_CHECK(
        esp_sleep_enable_timer_wakeup(sleep_seconds * MICROSECONDS_PER_SECOND));
    esp_deep_sleep_start();
}

static void schedule_next_sleep(void) {
    time_t now;
    struct tm timeinfo;

    if (!time_is_valid) {
        return;
    }

    time(&now);
    if (localtime_r(&now, &timeinfo) == NULL) {
        ESP_LOGW(TAG, "failed to get local time");
        return;
    }

    const uint32_t now_sec = seconds_since_midnight(&timeinfo);
    const uint32_t sleep_start_sec = SLEEP_START_HOUR * SECONDS_PER_HOUR;
    const uint32_t sleep_end_sec = SLEEP_END_HOUR * SECONDS_PER_HOUR;

    if (now_sec >= sleep_start_sec && now_sec < sleep_end_sec) {
        enter_scheduled_deep_sleep(sleep_end_sec - now_sec);
        return;
    }

    const uint64_t seconds_to_sleep = seconds_until_hour(&timeinfo,
                                                          SLEEP_START_HOUR);
    esp_err_t ret = esp_timer_stop(deep_sleep_timer);
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_ERROR_CHECK(ret);
    }

    ESP_ERROR_CHECK(esp_timer_start_once(
        deep_sleep_timer, seconds_to_sleep * MICROSECONDS_PER_SECOND));

    ESP_LOGI(TAG, "scheduled deep sleep in %" PRIu64 " seconds",
             seconds_to_sleep);
}

/* Public functions */
void sleep_manager_init(void) {
    setenv("TZ", "CST-8", 1);
    tzset();

    const esp_timer_create_args_t timer_args = {
        .callback = deep_sleep_timer_cb,
        .name = "deep_sleep",
    };

    ESP_ERROR_CHECK(esp_timer_create(&timer_args, &deep_sleep_timer));
}

void sleep_manager_handle_wakeup(void) {
    if (!(esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_TIMER))) {
        return;
    }

    if (planned_wakeup_magic != PLANNED_WAKEUP_MAGIC ||
        planned_wakeup_unix_time == 0) {
        ESP_LOGW(TAG, "timer wakeup without planned wakeup time");
        return;
    }

    const struct timeval now = {
        .tv_sec = (time_t)planned_wakeup_unix_time,
    };

    planned_wakeup_magic = 0;
    ESP_ERROR_CHECK(settimeofday(&now, NULL));
    time_is_valid = true;

    ESP_LOGI(TAG, "time restored from deep sleep wakeup: %" PRIu64,
             planned_wakeup_unix_time);
    schedule_next_sleep();
}

void sleep_manager_update_time(uint64_t unix_time_seconds) {
    const struct timeval now = {
        .tv_sec = (time_t)unix_time_seconds,
    };

    ESP_ERROR_CHECK(settimeofday(&now, NULL));
    time_is_valid = true;

    ESP_LOGI(TAG, "time updated from BLE timestamp: %" PRIu64,
             unix_time_seconds);
    schedule_next_sleep();
}
