/*
 * SPDX-FileCopyrightText: 2026
 *
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 */
#ifndef SLEEP_MANAGER_H
#define SLEEP_MANAGER_H

#include <stdint.h>

void sleep_manager_init(void);
void sleep_manager_handle_wakeup(void);
void sleep_manager_update_time(uint32_t unix_time_seconds,
                               uint8_t sleep_start_hour,
                               uint8_t sleep_end_hour);

#endif // SLEEP_MANAGER_H
