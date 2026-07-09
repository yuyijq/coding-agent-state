/*
 * SPDX-FileCopyrightText: 2024-2025 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 */
/* Includes */
#include "gatt_svc.h"
#include "common.h"
#include "led.h"
#include "sleep_manager.h"

/* Private function declarations */
static int led_chr_access(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg);
static uint64_t read_le_uint(const uint8_t *data, uint16_t len);

/* Defines */
#define TIME_SYNC_PAYLOAD_LEN 6

/* Private variables */
/* Automation IO service */
static const ble_uuid16_t auto_io_svc_uuid = BLE_UUID16_INIT(0x1815);
static uint16_t led_chr_val_handle;
static uint16_t time_chr_val_handle;
static const ble_uuid128_t led_chr_uuid =
    BLE_UUID128_INIT(0x23, 0xd1, 0xbc, 0xea, 0x5f, 0x78, 0x23, 0x15, 0xde, 0xef,
                     0x12, 0x12, 0x25, 0x15, 0x00, 0x00);
static const ble_uuid128_t time_chr_uuid =
    BLE_UUID128_INIT(0x23, 0xd1, 0xbc, 0xea, 0x5f, 0x78, 0x23, 0x15, 0xde, 0xef,
                     0x12, 0x12, 0x25, 0x15, 0x00, 0x01);

/* GATT services table */
static const struct ble_gatt_svc_def gatt_svr_svcs[] = {
    /* Automation IO service */
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &auto_io_svc_uuid.u,
        .characteristics =
            (struct ble_gatt_chr_def[]){/* LED characteristic */
                                        {.uuid = &led_chr_uuid.u,
                                         .access_cb = led_chr_access,
                                         .flags = BLE_GATT_CHR_F_WRITE,
                                         .val_handle = &led_chr_val_handle},
                                        {.uuid = &time_chr_uuid.u,
                                         .access_cb = led_chr_access,
                                         .flags = BLE_GATT_CHR_F_WRITE,
                                         .val_handle = &time_chr_val_handle},
                                        {0}},
    },

    {
        0, /* No more services. */
    },
};

/* Private functions */
static uint64_t read_le_uint(const uint8_t *data, uint16_t len) {
    uint64_t value = 0;

    for (uint16_t i = 0; i < len; i++) {
        value |= (uint64_t)data[i] << (8 * i);
    }

    return value;
}

static int led_chr_access(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg) {
    /* Local variables */
    int rc = 0;

    /* Handle access events */
    /* Note: LED characteristic is write only */
    switch (ctxt->op) {

    /* Write characteristic event */
    case BLE_GATT_ACCESS_OP_WRITE_CHR:
        /* Verify connection handle */
        if (conn_handle != BLE_HS_CONN_HANDLE_NONE) {
            ESP_LOGI(TAG, "characteristic write; conn_handle=%d attr_handle=%d",
                     conn_handle, attr_handle);
        } else {
            ESP_LOGI(TAG,
                     "characteristic write by nimble stack; attr_handle=%d",
                     attr_handle);
        }

        if (attr_handle == led_chr_val_handle) {
            if (ctxt->om->om_len == 1) {
                uint8_t command = ctxt->om->om_data[0];
                rc = led_apply_command(command);
                if (rc != 0) {
                    ESP_LOGE(TAG, "invalid led command: %d", command);
                    return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
                }
                ESP_LOGD(TAG, "led command applied: %d", command);
            } else {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            return rc;
        }

        if (attr_handle == time_chr_val_handle) {
            if (ctxt->om->om_len != TIME_SYNC_PAYLOAD_LEN) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }

            uint8_t timestamp_bytes[TIME_SYNC_PAYLOAD_LEN] = {0};
            rc = os_mbuf_copydata(ctxt->om, 0, ctxt->om->om_len,
                                  timestamp_bytes);
            if (rc != 0) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            if (timestamp_bytes[4] > 23 || timestamp_bytes[5] > 23 ||
                timestamp_bytes[4] == timestamp_bytes[5]) {
                return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
            }

            uint32_t unix_time_seconds =
                (uint32_t)read_le_uint(timestamp_bytes, sizeof(uint32_t));
            sleep_manager_update_time(unix_time_seconds, timestamp_bytes[4], timestamp_bytes[5]);
            return 0;
        }
        goto error;

    /* Unknown event */
    default:
        goto error;
    }

error:
    ESP_LOGE(TAG,
             "unexpected access operation to led characteristic, opcode: %d",
             ctxt->op);
    return BLE_ATT_ERR_UNLIKELY;
}

/* Public functions */
/*
 *  Handle GATT attribute register events
 *      - Service register event
 *      - Characteristic register event
 *      - Descriptor register event
 */
void gatt_svr_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg) {
    /* Local variables */
    char buf[BLE_UUID_STR_LEN];

    /* Handle GATT attributes register events */
    switch (ctxt->op) {

    /* Service register event */
    case BLE_GATT_REGISTER_OP_SVC:
        ESP_LOGD(TAG, "registered service %s with handle=%d",
                 ble_uuid_to_str(ctxt->svc.svc_def->uuid, buf),
                 ctxt->svc.handle);
        break;

    /* Characteristic register event */
    case BLE_GATT_REGISTER_OP_CHR:
        ESP_LOGD(TAG,
                 "registering characteristic %s with "
                 "def_handle=%d val_handle=%d",
                 ble_uuid_to_str(ctxt->chr.chr_def->uuid, buf),
                 ctxt->chr.def_handle, ctxt->chr.val_handle);
        break;

    /* Descriptor register event */
    case BLE_GATT_REGISTER_OP_DSC:
        ESP_LOGD(TAG, "registering descriptor %s with handle=%d",
                 ble_uuid_to_str(ctxt->dsc.dsc_def->uuid, buf),
                 ctxt->dsc.handle);
        break;

    /* Unknown event */
    default:
        assert(0);
        break;
    }
}

/*
 *  GATT server initialization
 *      1. Initialize GATT service
 *      2. Update NimBLE host GATT services counter
 *      3. Add GATT services to server
 */
int gatt_svc_init(void) {
    /* Local variables */
    int rc = 0;

    /* 1. GATT service initialization */
    ble_svc_gatt_init();

    /* 2. Update GATT services counter */
    rc = ble_gatts_count_cfg(gatt_svr_svcs);
    if (rc != 0) {
        return rc;
    }

    /* 3. Add GATT services */
    rc = ble_gatts_add_svcs(gatt_svr_svcs);
    if (rc != 0) {
        return rc;
    }

    return 0;
}
