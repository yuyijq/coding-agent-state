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
void sleep_manager_update_time(uint64_t unix_time_seconds);

#endif // SLEEP_MANAGER_H
