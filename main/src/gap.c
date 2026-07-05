/*
 * SPDX-FileCopyrightText: 2024 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 */
/* Includes */
#include "gap.h"
#include "common.h"
#include "esp_bt.h"

/* Private function declarations */
static int start_advertising(void);
static void restart_advertising_cb(struct ble_npl_event *event);
static void schedule_advertising_restart(void);
static int gap_event_handler(struct ble_gap_event *event, void *arg);

/* Private variables */
static uint8_t own_addr_type;
static struct ble_npl_callout restart_advertising_callout;
static const ble_uuid16_t auto_io_svc_uuid = BLE_UUID16_INIT(0x1815);

/* Private functions */
static int start_advertising(void) {
    /* Local variables */
    int rc = 0;
    const char *name;
    struct ble_hs_adv_fields adv_fields = {0};
    struct ble_gap_adv_params adv_params = {0};

    /* Set advertising flags */
    adv_fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    /* Set device name */
    name = ble_svc_gap_device_name();
    adv_fields.name = (uint8_t *)name;
    adv_fields.name_len = strlen(name);
    adv_fields.name_is_complete = 1;
    adv_fields.uuids16 = &auto_io_svc_uuid;
    adv_fields.num_uuids16 = 1;
    adv_fields.uuids16_is_complete = 1;

    /* Set advertisement fields */
    rc = ble_gap_adv_set_fields(&adv_fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "failed to set advertising data, error code: %d", rc);
        return rc;
    }

    /* Set undirected connectable and general discoverable mode */
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    /* Set advertising interval */
    adv_params.itvl_min = BLE_GAP_ADV_ITVL_MS(1000);
    adv_params.itvl_max = BLE_GAP_ADV_ITVL_MS(1020);

    rc = esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_ADV, ESP_PWR_LVL_N6);
    if (rc != ESP_OK) {
        ESP_LOGW(TAG, "failed to set advertising tx power, error code: %d", rc);
    }

    /* Start advertising */
    rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &adv_params,
                           gap_event_handler, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "failed to start advertising, error code: %d", rc);
        return rc;
    }
    ESP_LOGD(TAG, "advertising started");
    return rc;
}

static void restart_advertising_cb(struct ble_npl_event *event) {
    int rc = start_advertising();

    if (rc == BLE_HS_ENOMEM || rc == BLE_HS_EAGAIN) {
        schedule_advertising_restart();
    }
}

static void schedule_advertising_restart(void) {
    int rc;

    if (ble_npl_callout_is_active(&restart_advertising_callout)) {
        return;
    }

    rc = ble_npl_callout_reset(&restart_advertising_callout,
                               pdMS_TO_TICKS(100));
    if (rc != 0) {
        ESP_LOGE(TAG, "failed to schedule advertising restart, error code: %d",
                 rc);
    }
}

/*
 * NimBLE applies an event-driven model to keep GAP service going
 * gap_event_handler is a callback function registered when calling
 * ble_gap_adv_start API and called when a GAP event arrives
 */
static int gap_event_handler(struct ble_gap_event *event, void *arg) {
    /* Local variables */
    int rc = 0;

    /* Handle different GAP event */
    switch (event->type) {

    /* Connect event */
    case BLE_GAP_EVENT_CONNECT:
        /* Connection succeeded */
        if (event->connect.status == 0) {
            rc = esp_ble_tx_power_set_enhanced(ESP_BLE_ENHANCED_PWR_TYPE_CONN,
                                               event->connect.conn_handle,
                                               ESP_PWR_LVL_N6);
            if (rc != ESP_OK) {
                ESP_LOGD(TAG, "failed to set connection tx power, error code: %d",
                         rc);
            }

            struct ble_gap_upd_params params = {.itvl_min = 80,
                                                .itvl_max = 120,
                                                .latency = 4,
                                                .supervision_timeout = 600};
            rc = ble_gap_update_params(event->connect.conn_handle, &params);
            if (rc != 0) {
                ESP_LOGW(TAG,
                         "failed to update connection parameters, error code: %d",
                         rc);
            }
        }
        /* Connection failed, restart advertising */
        else {
            schedule_advertising_restart();
        }
        return rc;

    /* Disconnect event */
    case BLE_GAP_EVENT_DISCONNECT:
        /* Restart advertising */
        schedule_advertising_restart();
        return rc;

    /* Connection parameters update event */
    case BLE_GAP_EVENT_CONN_UPDATE:
        return rc;

    /* Advertising complete event */
    case BLE_GAP_EVENT_ADV_COMPLETE:
        /* Advertising completed, restart advertising */
        schedule_advertising_restart();
        return rc;
    }

    return rc;
}


/* Public functions */
void adv_init(void) {
    /* Local variables */
    int rc = 0;

    /* Make sure we have proper BT identity address set (random preferred) */
    rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "device does not have any available bt address!");
        return;
    }

    /* Figure out BT address to use while advertising (no privacy for now) */
    rc = ble_hs_id_infer_auto(0, &own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "failed to infer address type, error code: %d", rc);
        return;
    }

    /* Start advertising. */
    start_advertising();
}

int gap_init(void) {
    /* Local variables */
    int rc = 0;

    /* Call NimBLE GAP initialization API */
    ble_svc_gap_init();

    ble_npl_callout_init(&restart_advertising_callout,
                         nimble_port_get_dflt_eventq(),
                         restart_advertising_cb, NULL);

    /* Set GAP device name */
    rc = ble_svc_gap_device_name_set(DEVICE_NAME);
    if (rc != 0) {
        ESP_LOGE(TAG, "failed to set device name to %s, error code: %d",
                 DEVICE_NAME, rc);
        return rc;
    }
    return rc;
}
