#include "csos_ui_backend.h"

static int send_message(void *userdata, const void *message, uint8_t length) {
    (void)message; *(uint8_t *)userdata = length; return 0;
}
static int receive_message(void *userdata, void *message, uint8_t capacity) {
    if (capacity < 2) return -1;
    ((uint8_t *)message)[0] = CSOS_UI_CLOSE; ((uint8_t *)message)[1] = 2;
    return *(uint8_t *)userdata = 2;
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
    uint8_t transport_state = 0;
    struct csos_ui_transport transport = { &transport_state, send_message, receive_message };
    if (csos_ui_transport_send(&transport, message, 27) != 0 || transport_state != 27)
        return 7;
    if (csos_ui_transport_receive(&transport, message, sizeof(message)) != 2 || message[0] != CSOS_UI_CLOSE)
        return 8;
    struct csos_ui_client client;
    csos_ui_client_init(&client, transport);
    if (csos_ui_client_hello(&client, CSOS_UI_PROTOCOL_VERSION, CSOS_UI_CAP_SURFACE) != 0 || !client.ready)
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
    if (csos_ui_client_close(&client) != 0 || client.ready)
        return 14;
    if (csos_ui_client_receive_response(&client, message, sizeof(message)) != -1)
        return 15;
    struct csos_ui_pointer pointer;
    uint8_t pointer_message[11] = { CSOS_UI_POINTER, 11, 0xfc, 0xff, 0xff, 0xff, 9, 0, 0, 0, 1 };
    if (!csos_ui_decode_pointer(pointer_message, sizeof(pointer_message), &pointer) || pointer.x != -4 || pointer.buttons != 1)
        return 16;
    int32_t wheel = 0;
    if (!csos_ui_decode_wheel((uint8_t[]){ CSOS_UI_WHEEL, 6, 0xfc, 0xff, 0xff, 0xff }, 6, &wheel) || wheel != -4)
        return 17;
    int focused = 0;
    if (!csos_ui_decode_focus((uint8_t[]){ CSOS_UI_FOCUS, 3, 1 }, 3, &focused) || !focused)
        return 18;
    return csos_ui_event_valid((uint8_t[]){ CSOS_UI_FOCUS, 3, 1 }, 3) ? 0 : 19;
}
