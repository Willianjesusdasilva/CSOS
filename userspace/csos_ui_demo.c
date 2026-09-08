#include "csos_ui_backend.h"

/* Minimal userspace vertical slice. The server callbacks stand in for the
 * future CSOS IPC endpoint; the application only sees the public ABI. */
struct demo_server {
    struct csos_ui_ring events;
    uint8_t present_count;
    uint32_t surface_id;
    uint64_t generation;
    uint16_t width, height;
};

static int demo_send(void *userdata, const void *message, uint8_t length) {
    struct demo_server *server = (struct demo_server *)userdata;
    const uint8_t *request = (const uint8_t *)message;
    if (!server || length < 2 || request[1] != length) return -1;
    uint8_t response[CSOS_UI_RING_MESSAGE_MAX];
    uint8_t response_length = 0;
    switch (request[0]) {
    case CSOS_UI_HELLO:
        response[0] = CSOS_UI_HELLO_ACK; response[1] = 12;
        csos_ui_put16(response + 2, csos_ui_get16(request + 2));
        csos_ui_put64(response + 4, csos_ui_get64(request + 4)); response_length = 12; break;
    case CSOS_UI_CREATE_WINDOW:
        server->width = csos_ui_get16(request + 2); server->height = csos_ui_get16(request + 4);
        server->surface_id = 1; server->generation = 0;
        { struct csos_ui_surface surface = { 1, 0x100, server->width, server->height,
                                             server->width, CSOS_UI_RGBA8888, server->generation };
          response_length = csos_ui_encode_surface_created(response, sizeof(response), surface); }
        break;
    case CSOS_UI_PRESENT: server->present_count++; return 0;
    case CSOS_UI_RESIZE:
        server->width = csos_ui_get16(request + 2); server->height = csos_ui_get16(request + 4); server->generation++;
        { struct csos_ui_surface surface = { 1, 0x100, server->width, server->height,
                                             server->width, CSOS_UI_RGBA8888, server->generation };
          response_length = csos_ui_encode_surface_created(response, sizeof(response), surface); }
        break;
    case CSOS_UI_CLOSE: return 0;
    default: return 0;
    }
    return response_length != 0 && csos_ui_ring_send(&server->events, response, response_length) == 0 ? 0 : -1;
}

static int demo_receive(void *userdata, void *message, uint8_t capacity) {
    return csos_ui_ring_receive(userdata, message, capacity);
}

int main(void) {
    struct demo_server server = { 0 };
    csos_ui_ring_init(&server.events);
    struct csos_ui_transport transport = { &server, demo_send, demo_receive };
    struct csos_ui_client client;
    csos_ui_client_init(&client, transport);
    uint8_t message[CSOS_UI_RING_MESSAGE_MAX]; uint8_t kind = 0;
    if (csos_ui_client_hello(&client, CSOS_UI_PROTOCOL_VERSION, CSOS_UI_CAP_SURFACE | CSOS_UI_CAP_INPUT) != 0 ||
        csos_ui_client_receive_hello_ack(&client, message, sizeof(message)) != 12) return 1;
    if (csos_ui_client_create_window(&client, 64, 48, "demo", 4) != 0 ||
        csos_ui_client_process_response(&client, message, sizeof(message), &kind) != 27 ||
        kind != CSOS_UI_SURFACE_CREATED || !client.surface_valid) return 2;

    uint32_t pixels[64 * 48];
    for (unsigned i = 0; i < 64 * 48; ++i) pixels[i] = 0xff202030;
    for (unsigned y = 12; y < 36; ++y) for (unsigned x = 16; x < 48; ++x) pixels[y * 64 + x] = 0xff40a0e0;
    if (csos_ui_client_present(&client, client.surface.id, client.surface.generation,
                               (struct csos_ui_damage){ 0, 0, 64, 48 }) != 0) return 3;
    if (server.present_count != 1) return 4;

    uint8_t focus[] = { CSOS_UI_FOCUS, 3, 1 };
    if (csos_ui_ring_send(&server.events, focus, sizeof(focus)) != 0 ||
        csos_ui_client_process_event(&client, message, sizeof(message), &kind) != 3 || !client.focused) return 5;
    if (csos_ui_client_resize(&client, 80, 60) != 0 ||
        csos_ui_client_process_response(&client, message, sizeof(message), &kind) != 27 ||
        client.surface.width != 80 || client.surface.height != 60 || client.surface.generation != 1) return 6;
    if (csos_ui_client_close(&client) != 0 || client.ready) return 7;
    return 0;
}
