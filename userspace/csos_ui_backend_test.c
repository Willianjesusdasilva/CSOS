#include "csos_ui_backend.h"

static int send_message(void *userdata, const void *message, uint8_t length) {
    (void)message; *(uint8_t *)userdata = length; return 0;
}
static int receive_message(void *userdata, void *message, uint8_t capacity) {
    if (capacity < 2) return -1;
    ((uint8_t *)message)[0] = CSOS_UI_CLOSE; ((uint8_t *)message)[1] = 2;
    return *(uint8_t *)userdata = 2;
}
static int receive_failure(void *userdata, void *message, uint8_t capacity) {
    (void)userdata; if (capacity < 4) return -1;
    ((uint8_t *)message)[0] = CSOS_UI_FAILURE; ((uint8_t *)message)[1] = 4;
    csos_ui_put16((uint8_t *)message + 2, 0x1234); return 4;
}
static int receive_hello_ack(void *userdata, void *message, uint8_t capacity) {
    (void)userdata; if (capacity < 12) return -1;
    ((uint8_t *)message)[0] = CSOS_UI_HELLO_ACK; ((uint8_t *)message)[1] = 12;
    csos_ui_put16((uint8_t *)message + 2, CSOS_UI_PROTOCOL_VERSION);
    csos_ui_put64((uint8_t *)message + 4, CSOS_UI_CAP_SURFACE); return 12;
}
static int receive_surface_created(void *userdata, void *message, uint8_t capacity) {
    (void)userdata; if (capacity < 27) return -1;
    struct csos_ui_surface surface = { 4, 0x55, 640, 480, 640, CSOS_UI_BGRA8888, 9 };
    return csos_ui_encode_surface_created((uint8_t *)message, capacity, surface);
}
static int receive_focus(void *userdata, void *message, uint8_t capacity) {
    (void)userdata; if (capacity < 3) return -1;
    ((uint8_t *)message)[0] = CSOS_UI_FOCUS; ((uint8_t *)message)[1] = 3; ((uint8_t *)message)[2] = 1; return 3;
}
static int receive_surface_destroyed(void *userdata, void *message, uint8_t capacity) {
    (void)userdata; if (capacity < 6) return -1;
    ((uint8_t *)message)[0] = CSOS_UI_SURFACE_DESTROYED; ((uint8_t *)message)[1] = 6;
    csos_ui_put32((uint8_t *)message + 2, 4); return 6;
}

int main(void) {
    uint8_t message[32];
    struct csos_ui_damage damage = { 1, 2, 8, 9 };
    if (csos_ui_encode_hello(message, sizeof(message), CSOS_UI_PROTOCOL_VERSION,
                             CSOS_UI_CAP_SURFACE | CSOS_UI_CAP_INPUT) != 12)
        return 1;
    if (!csos_ui_request_valid(message, 12) || csos_ui_get16(message + 2) != 1)
        return 2;
    if (csos_ui_encode_present(message, sizeof(message), 4, 7, damage) != 22)
        return 3;
    if (!csos_ui_request_valid(message, 22) || csos_ui_get32(message + 2) != 4)
        return 4;
    if (csos_ui_encode_close(message, 1) != 0)
        return 5;
    struct csos_ui_surface surface = { 4, 0x55, 640, 480, 640, CSOS_UI_BGRA8888, 9 };
    if (csos_ui_encode_surface_created(message, sizeof(message), surface) != 27 ||
        !csos_ui_response_valid(message, 27) || csos_ui_get32(message + 6) != 0x55)
        return 6;
    struct csos_ui_surface decoded_surface;
    if (!csos_ui_decode_surface_created(message, 27, &decoded_surface) || decoded_surface.width != 640 || decoded_surface.format != CSOS_UI_BGRA8888)
        return 7;
    message[0] = CSOS_UI_HELLO_ACK; message[1] = 12; csos_ui_put16(message + 2, 1); csos_ui_put64(message + 4, CSOS_UI_CAP_SURFACE);
    struct csos_ui_hello hello_ack;
    if (!csos_ui_decode_hello_ack(message, 12, &hello_ack) || hello_ack.version != 1 || hello_ack.capabilities != CSOS_UI_CAP_SURFACE)
        return 7;
    message[0] = CSOS_UI_SURFACE_DESTROYED; message[1] = 6; csos_ui_put32(message + 2, 4);
    uint32_t destroyed_id = 0;
    if (!csos_ui_decode_surface_destroyed(message, 6, &destroyed_id) || destroyed_id != 4)
        return 7;
    message[0] = CSOS_UI_FAILURE; message[1] = 4; csos_ui_put16(message + 2, 0x1234);
    uint16_t failure_code = 0;
    if (!csos_ui_decode_failure(message, 4, &failure_code) || failure_code != 0x1234)
        return 7;
    uint8_t transport_state = 0;
    struct csos_ui_transport transport = { &transport_state, send_message, receive_message };
    if (csos_ui_transport_send(&transport, message, 27) != 0 || transport_state != 27)
        return 7;
    if (csos_ui_transport_receive(&transport, message, sizeof(message)) != 2 || message[0] != CSOS_UI_CLOSE)
        return 8;
    struct csos_ui_client client;
    csos_ui_client_init(&client, transport);
    if (csos_ui_client_hello(&client, CSOS_UI_PROTOCOL_VERSION, CSOS_UI_CAP_SURFACE) != 0 || client.ready || !client.hello_pending)
        return 9;
    message[0] = CSOS_UI_HELLO_ACK; message[1] = 12; csos_ui_put16(message + 2, 1); csos_ui_put64(message + 4, CSOS_UI_CAP_SURFACE);
    if (csos_ui_client_confirm_hello(&client, message, 12) != 0 || !client.ready || client.hello_pending)
        return 9;
    struct csos_ui_client incompatible_client;
    csos_ui_client_init(&incompatible_client, transport);
    if (csos_ui_client_hello(&incompatible_client, CSOS_UI_PROTOCOL_VERSION, CSOS_UI_CAP_SURFACE) != 0)
        return 9;
    csos_ui_put16(message + 2, CSOS_UI_PROTOCOL_VERSION + 1);
    if (csos_ui_client_confirm_hello(&incompatible_client, message, 12) != -1 || incompatible_client.ready == 1)
        return 9;
    struct csos_ui_client receiving_client;
    struct csos_ui_transport ack_transport = { 0, send_message, receive_hello_ack };
    csos_ui_client_init(&receiving_client, ack_transport);
    if (csos_ui_client_hello(&receiving_client, CSOS_UI_PROTOCOL_VERSION, CSOS_UI_CAP_SURFACE) != 0 ||
        csos_ui_client_receive_hello_ack(&receiving_client, message, sizeof(message)) != 12 ||
        !receiving_client.ready)
        return 9;
    struct csos_ui_client surface_client;
    struct csos_ui_transport surface_transport = { &transport_state, send_message, receive_surface_created };
    csos_ui_client_init(&surface_client, surface_transport); surface_client.ready = 1;
    if (csos_ui_client_process_response(&surface_client, message, sizeof(message), 0) != 27 ||
        !surface_client.surface_valid || surface_client.surface.buffer_handle != 0x55 ||
        surface_client.surface.generation != 9)
        return 9;
    if (!csos_ui_client_surface(&surface_client) || csos_ui_client_surface(&surface_client)->id != 4)
        return 9;
    if (csos_ui_client_present(&surface_client, 4, 8, (struct csos_ui_damage){ 0, 0, 1, 1 }) != -1 ||
        csos_ui_client_present(&surface_client, 4, 9, (struct csos_ui_damage){ 0, 0, 1, 1 }) != 0)
        return 9;
    if (csos_ui_client_present(&client, 4, 9, (struct csos_ui_damage){ 0, 0, 0, 1 }) != -1)
        return 9;
    struct csos_ui_client destroyed_client;
    struct csos_ui_transport destroyed_transport = { &transport_state, send_message, receive_surface_destroyed };
    csos_ui_client_init(&destroyed_client, destroyed_transport); destroyed_client.ready = 1;
    destroyed_client.surface = surface; destroyed_client.surface_valid = 1;
    if (csos_ui_client_process_response(&destroyed_client, message, sizeof(message), 0) != 6 ||
        destroyed_client.surface_valid)
        return 9;
    if (csos_ui_client_present(&client, 4, 9, (struct csos_ui_damage){ 0, 0, 8, 8 }) != 0)
        return 10;
    if (csos_ui_client_create_window(&client, 320, 200, "FILES", 5) != 0 ||
        csos_ui_client_destroy_window(&client, 4) != 0)
        return 11;
    if (csos_ui_client_open_file(&client, "/index.html", 11) != 0 ||
        csos_ui_client_set_timer(&client, 1, 60) != 0)
        return 12;
    if (csos_ui_client_connect(&client, "127.0.0.1", 9, 80) != 0 ||
        csos_ui_client_audio(&client, 48000, 2) != 0)
        return 13;
    if (csos_ui_client_clipboard_set(&client, "CSOS", 4) != 0)
        return 14;
    if (csos_ui_client_resize(&client, 800, 600) != 0)
        return 15;
    if (csos_ui_client_close(&client) != 0 || client.ready)
        return 16;
    if (csos_ui_client_receive_response(&client, message, sizeof(message)) != -1)
        return 16;
    if (csos_ui_client_receive_event(&client, message, sizeof(message)) != -1)
        return 21;
    struct csos_ui_client failed_client;
    struct csos_ui_transport failure_transport = { 0, send_message, receive_failure };
    csos_ui_client_init(&failed_client, failure_transport); failed_client.ready = 1;
    uint8_t response_kind = 0;
    if (csos_ui_client_process_response(&failed_client, message, sizeof(message), &response_kind) != 4 ||
        response_kind != CSOS_UI_FAILURE || failed_client.ready)
        return 22;
    failed_client.ready = 1; failed_client.surface_valid = 1; failed_client.focused = 1;
    if (csos_ui_client_process_response(&failed_client, message, sizeof(message), 0) != 4 ||
        failed_client.surface_valid || failed_client.focused)
        return 22;
    struct csos_ui_client event_client;
    struct csos_ui_transport event_transport = { 0, send_message, receive_focus };
    csos_ui_client_init(&event_client, event_transport); event_client.ready = 1;
    if (csos_ui_client_process_event(&event_client, message, sizeof(message), &response_kind) != 3 ||
        response_kind != CSOS_UI_FOCUS || !event_client.focused)
        return 23;
    uint32_t timer_id = 0;
    if (!csos_ui_decode_timer((uint8_t[]){ CSOS_UI_TIMER, 6, 0x2a, 0, 0, 0 }, 6, &timer_id) || timer_id != 42)
        return 24;
    struct csos_ui_pointer pointer;
    uint8_t pointer_message[11] = { CSOS_UI_POINTER, 11, 0xfc, 0xff, 0xff, 0xff, 9, 0, 0, 0, 1 };
    if (!csos_ui_decode_pointer(pointer_message, sizeof(pointer_message), &pointer) || pointer.x != -4 || pointer.buttons != 1)
        return 17;
    int32_t wheel = 0;
    if (!csos_ui_decode_wheel((uint8_t[]){ CSOS_UI_WHEEL, 6, 0xfc, 0xff, 0xff, 0xff }, 6, &wheel) || wheel != -4)
        return 18;
    int focused = 0;
    if (!csos_ui_decode_focus((uint8_t[]){ CSOS_UI_FOCUS, 3, 1 }, 3, &focused) || !focused)
        return 19;
    return csos_ui_event_valid((uint8_t[]){ CSOS_UI_FOCUS, 3, 1 }, 3) ? 0 : 20;
}
