#ifndef CSOS_UI_BACKEND_H
#define CSOS_UI_BACKEND_H

#include <stdint.h>

/* Pointer-free wire ABI. All integers are little-endian on the wire. */
#define CSOS_UI_PROTOCOL_VERSION 1u

#define CSOS_UI_CAP_SURFACE  (1ull << 0)
#define CSOS_UI_CAP_DAMAGE   (1ull << 1)
#define CSOS_UI_CAP_INPUT    (1ull << 2)
#define CSOS_UI_CAP_CLIPBOARD (1ull << 3)
#define CSOS_UI_CAP_TIMERS   (1ull << 4)
#define CSOS_UI_CAP_IPC      (1ull << 5)
#define CSOS_UI_CAP_WINDOWS  (1ull << 6)
#define CSOS_UI_CAP_AUDIO    (1ull << 7)

enum csos_ui_request_kind {
    CSOS_UI_PRESENT = 1,
    CSOS_UI_CREATE_WINDOW = 2,
    CSOS_UI_DESTROY_WINDOW = 3,
    CSOS_UI_OPEN_FILE = 4,
    CSOS_UI_CONNECT = 5,
    CSOS_UI_AUDIO = 6,
    CSOS_UI_SET_TIMER = 7,
    CSOS_UI_CLOSE = 8,
    CSOS_UI_HELLO = 9,
    CSOS_UI_CLIPBOARD_SET = 10,
    CSOS_UI_RESIZE = 11,
};

enum csos_ui_event_kind {
    CSOS_UI_POINTER = 1,
    CSOS_UI_WHEEL = 2,
    CSOS_UI_KEY = 3,
    CSOS_UI_FOCUS = 4,
    CSOS_UI_TIMER = 5,
    CSOS_UI_EVENT_CLOSE = 6,
};

enum csos_ui_response_kind {
    CSOS_UI_SURFACE_CREATED = 1,
    CSOS_UI_SURFACE_DESTROYED = 2,
    CSOS_UI_FAILURE = 3,
    CSOS_UI_HELLO_ACK = 4,
};

enum csos_ui_pixel_format {
    CSOS_UI_RGBA8888 = 1,
    CSOS_UI_BGRA8888 = 2,
    CSOS_UI_ARGB8888 = 3,
};

/* Every message starts with kind:u8, total_length:u8. */
#if defined(__GNUC__) || defined(__clang__)
#define CSOS_UI_PACKED __attribute__((packed))
#else
#define CSOS_UI_PACKED
#endif

struct CSOS_UI_PACKED csos_ui_message_header { uint8_t kind; uint8_t total_length; };

struct CSOS_UI_PACKED csos_ui_damage { uint16_t x, y, width, height; };
struct csos_ui_pointer { int32_t x, y; uint8_t buttons; };
struct csos_ui_key { uint32_t code; uint8_t pressed, modifiers; };
struct CSOS_UI_PACKED csos_ui_hello { uint16_t version; uint64_t capabilities; };
struct CSOS_UI_PACKED csos_ui_present { uint32_t surface_id; uint64_t generation; struct csos_ui_damage damage; };
struct CSOS_UI_PACKED csos_ui_surface { uint32_t id, buffer_handle; uint16_t width, height; uint32_t stride; uint8_t format; uint64_t generation; };

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(struct csos_ui_message_header) == 2, "CSOS UI header layout mismatch");
_Static_assert(sizeof(struct csos_ui_damage) == 8, "CSOS UI damage layout mismatch");
_Static_assert(sizeof(struct csos_ui_hello) == 10, "CSOS UI hello layout mismatch");
_Static_assert(sizeof(struct csos_ui_present) == 20, "CSOS UI present layout mismatch");
_Static_assert(sizeof(struct csos_ui_surface) == 25, "CSOS UI surface layout mismatch");
#endif

static inline void csos_ui_put16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
}
static inline void csos_ui_put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static inline void csos_ui_put64(uint8_t *p, uint64_t v) {
    for (unsigned i = 0; i != 8; ++i) p[i] = (uint8_t)(v >> (i * 8));
}
static inline uint16_t csos_ui_get16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static inline uint32_t csos_ui_get32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline uint64_t csos_ui_get64(const uint8_t *p) {
    uint64_t value = 0;
    for (unsigned i = 0; i != 8; ++i) value |= (uint64_t)p[i] << (i * 8);
    return value;
}

static inline int csos_ui_request_valid(const uint8_t *message, uint8_t length) {
    if (!message || length < 2 || message[1] != length) return 0;
    switch (message[0]) {
    case CSOS_UI_HELLO: return length == 12;
    case CSOS_UI_PRESENT: return length == 22;
    case CSOS_UI_CLOSE: return length == 2;
    case CSOS_UI_CLIPBOARD_SET: return length >= 3 && message[2] == (uint8_t)(length - 3);
    case CSOS_UI_RESIZE: return length == 6 && csos_ui_get16(message + 2) != 0 && csos_ui_get16(message + 4) != 0;
    default: return 0;
    }
}

static inline int csos_ui_event_valid(const uint8_t *message, uint8_t length) {
    if (!message || length < 2 || message[1] != length) return 0;
    switch (message[0]) {
    case CSOS_UI_POINTER: return length == 11;
    case CSOS_UI_WHEEL: return length == 6;
    case CSOS_UI_KEY: return length == 8 && message[6] <= 1;
    case CSOS_UI_FOCUS: return length == 3 && message[2] <= 1;
    case CSOS_UI_TIMER: return length == 6;
    case CSOS_UI_EVENT_CLOSE: return length == 2;
    default: return 0;
    }
}

static inline int csos_ui_response_valid(const uint8_t *message, uint8_t length) {
    if (!message || length < 2 || message[1] != length) return 0;
    switch (message[0]) {
    case CSOS_UI_SURFACE_CREATED:
        return length == 27 && message[18] >= CSOS_UI_RGBA8888 && message[18] <= CSOS_UI_ARGB8888;
    case CSOS_UI_SURFACE_DESTROYED: return length == 6;
    case CSOS_UI_FAILURE: return length == 4;
    case CSOS_UI_HELLO_ACK: return length == 12;
    default: return 0;
    }
}

static inline int csos_ui_decode_hello_ack(const uint8_t *message, uint8_t length,
                                           struct csos_ui_hello *out) {
    if (!out || !csos_ui_response_valid(message, length) || message[0] != CSOS_UI_HELLO_ACK) return 0;
    out->version = csos_ui_get16(message + 2); out->capabilities = csos_ui_get64(message + 4); return 1;
}

static inline int csos_ui_decode_surface_created(const uint8_t *message, uint8_t length,
                                                 struct csos_ui_surface *out) {
    if (!out || !csos_ui_response_valid(message, length) || message[0] != CSOS_UI_SURFACE_CREATED) return 0;
    out->id = csos_ui_get32(message + 2); out->buffer_handle = csos_ui_get32(message + 6);
    out->width = csos_ui_get16(message + 10); out->height = csos_ui_get16(message + 12);
    out->stride = csos_ui_get32(message + 14); out->format = message[18]; out->generation = csos_ui_get64(message + 19); return 1;
}

static inline int csos_ui_decode_surface_destroyed(const uint8_t *message, uint8_t length,
                                                   uint32_t *surface_id) {
    if (!surface_id || !csos_ui_response_valid(message, length) ||
        message[0] != CSOS_UI_SURFACE_DESTROYED) return 0;
    *surface_id = csos_ui_get32(message + 2); return 1;
}

static inline int csos_ui_decode_failure(const uint8_t *message, uint8_t length,
                                         uint16_t *code) {
    if (!code || !csos_ui_response_valid(message, length) || message[0] != CSOS_UI_FAILURE) return 0;
    *code = csos_ui_get16(message + 2); return 1;
}

static inline int csos_ui_decode_pointer(const uint8_t *message, uint8_t length,
                                         struct csos_ui_pointer *out) {
    if (!out || !csos_ui_event_valid(message, length) || message[0] != CSOS_UI_POINTER) return 0;
    out->x = (int32_t)csos_ui_get32(message + 2); out->y = (int32_t)csos_ui_get32(message + 6);
    out->buttons = message[10]; return 1;
}

static inline int csos_ui_decode_key(const uint8_t *message, uint8_t length,
                                     struct csos_ui_key *out) {
    if (!out || !csos_ui_event_valid(message, length) || message[0] != CSOS_UI_KEY) return 0;
    out->code = csos_ui_get32(message + 2); out->pressed = message[6]; out->modifiers = message[7]; return 1;
}

static inline int csos_ui_decode_wheel(const uint8_t *message, uint8_t length, int32_t *delta) {
    if (!delta || !csos_ui_event_valid(message, length) || message[0] != CSOS_UI_WHEEL) return 0;
    *delta = (int32_t)csos_ui_get32(message + 2); return 1;
}

static inline int csos_ui_decode_focus(const uint8_t *message, uint8_t length, int *focused) {
    if (!focused || !csos_ui_event_valid(message, length) || message[0] != CSOS_UI_FOCUS) return 0;
    *focused = message[2] != 0; return 1;
}

/* Return the encoded byte count, or zero when capacity is insufficient. */
static inline uint8_t csos_ui_encode_hello(uint8_t *out, uint8_t capacity,
                                           uint16_t version, uint64_t capabilities) {
    if (!out || capacity < 12) return 0;
    out[0] = CSOS_UI_HELLO; out[1] = 12;
    csos_ui_put16(out + 2, version); csos_ui_put64(out + 4, capabilities);
    return 12;
}

static inline uint8_t csos_ui_encode_close(uint8_t *out, uint8_t capacity) {
    if (!out || capacity < 2) return 0;
    out[0] = CSOS_UI_CLOSE; out[1] = 2; return 2;
}

static inline uint8_t csos_ui_encode_present(uint8_t *out, uint8_t capacity,
                                              uint32_t surface_id, uint64_t generation,
                                              struct csos_ui_damage damage) {
    if (!out || capacity < 22) return 0;
    out[0] = CSOS_UI_PRESENT; out[1] = 22;
    csos_ui_put32(out + 2, surface_id); csos_ui_put64(out + 6, generation);
    csos_ui_put16(out + 14, damage.x); csos_ui_put16(out + 16, damage.y);
    csos_ui_put16(out + 18, damage.width); csos_ui_put16(out + 20, damage.height);
    return 22;
}

static inline uint8_t csos_ui_encode_create_window(uint8_t *out, uint8_t capacity,
                                                    uint16_t width, uint16_t height,
                                                    const char *title, uint8_t title_length) {
    if (!out || !title || title_length > 128 || capacity < (uint8_t)(7 + title_length)) return 0;
    out[0] = CSOS_UI_CREATE_WINDOW; out[1] = (uint8_t)(7 + title_length);
    csos_ui_put16(out + 2, width); csos_ui_put16(out + 4, height); out[6] = title_length;
    for (uint8_t i = 0; i != title_length; ++i) out[7 + i] = (uint8_t)title[i];
    return (uint8_t)(7 + title_length);
}

static inline uint8_t csos_ui_encode_destroy_window(uint8_t *out, uint8_t capacity, uint32_t id) {
    if (!out || capacity < 6) return 0;
    out[0] = CSOS_UI_DESTROY_WINDOW; out[1] = 6; csos_ui_put32(out + 2, id); return 6;
}

static inline uint8_t csos_ui_encode_open_file(uint8_t *out, uint8_t capacity,
                                               const char *path, uint8_t path_length) {
    if (!out || !path || path_length > 252 || capacity < (uint8_t)(3 + path_length)) return 0;
    out[0] = CSOS_UI_OPEN_FILE; out[1] = (uint8_t)(3 + path_length); out[2] = path_length;
    for (uint8_t i = 0; i != path_length; ++i) out[3 + i] = (uint8_t)path[i];
    return (uint8_t)(3 + path_length);
}

static inline uint8_t csos_ui_encode_set_timer(uint8_t *out, uint8_t capacity,
                                               uint32_t timer_id, uint64_t ticks) {
    if (!out || capacity < 14 || timer_id == 0 || ticks == 0) return 0;
    out[0] = CSOS_UI_SET_TIMER; out[1] = 14; csos_ui_put32(out + 2, timer_id); csos_ui_put64(out + 6, ticks); return 14;
}

static inline uint8_t csos_ui_encode_connect(uint8_t *out, uint8_t capacity,
                                             const char *address, uint8_t address_length, uint16_t port) {
    if (!out || !address || address_length > 250 || capacity < (uint8_t)(5 + address_length)) return 0;
    out[0] = CSOS_UI_CONNECT; out[1] = (uint8_t)(5 + address_length); csos_ui_put16(out + 2, port); out[4] = address_length;
    for (uint8_t i = 0; i != address_length; ++i) out[5 + i] = (uint8_t)address[i];
    return (uint8_t)(5 + address_length);
}

static inline uint8_t csos_ui_encode_audio(uint8_t *out, uint8_t capacity, uint32_t sample_rate, uint8_t channels) {
    if (!out || capacity < 7 || sample_rate == 0 || channels == 0 || channels > 8) return 0;
    out[0] = CSOS_UI_AUDIO; out[1] = 7; csos_ui_put32(out + 2, sample_rate); out[6] = channels; return 7;
}

static inline uint8_t csos_ui_encode_clipboard_set(uint8_t *out, uint8_t capacity,
                                                   const char *text, uint8_t text_length) {
    if (!out || !text || text_length > 252 || capacity < (uint8_t)(3 + text_length)) return 0;
    out[0] = CSOS_UI_CLIPBOARD_SET; out[1] = (uint8_t)(3 + text_length); out[2] = text_length;
    for (uint8_t i = 0; i != text_length; ++i) out[3 + i] = (uint8_t)text[i];
    return (uint8_t)(3 + text_length);
}

static inline uint8_t csos_ui_encode_resize(uint8_t *out, uint8_t capacity, uint16_t width, uint16_t height) {
    if (!out || capacity < 6 || width == 0 || height == 0) return 0;
    out[0] = CSOS_UI_RESIZE; out[1] = 6; csos_ui_put16(out + 2, width); csos_ui_put16(out + 4, height); return 6;
}

static inline uint8_t csos_ui_encode_surface_created(uint8_t *out, uint8_t capacity,
                                                     struct csos_ui_surface surface) {
    if (!out || capacity < 27) return 0;
    out[0] = CSOS_UI_SURFACE_CREATED; out[1] = 27;
    csos_ui_put32(out + 2, surface.id); csos_ui_put32(out + 6, surface.buffer_handle);
    csos_ui_put16(out + 10, surface.width); csos_ui_put16(out + 12, surface.height);
    csos_ui_put32(out + 14, surface.stride); out[18] = surface.format;
    csos_ui_put64(out + 19, surface.generation);
    return 27;
}

static inline uint8_t csos_ui_encode_surface_destroyed(uint8_t *out, uint8_t capacity,
                                                       uint32_t surface_id) {
    if (!out || capacity < 6) return 0;
    out[0] = CSOS_UI_SURFACE_DESTROYED; out[1] = 6;
    csos_ui_put32(out + 2, surface_id); return 6;
}

typedef int (*csos_ui_send_fn)(void *userdata, const void *message, uint8_t length);
typedef int (*csos_ui_receive_fn)(void *userdata, void *message, uint8_t capacity);

struct csos_ui_transport {
    void *userdata;
    csos_ui_send_fn send;
    csos_ui_receive_fn receive;
};

struct csos_ui_client {
    struct csos_ui_transport transport;
    uint16_t version;
    uint64_t capabilities;
    int ready;
    int hello_pending;
    struct csos_ui_surface surface;
    int surface_valid;
    int focused;
    struct csos_ui_pointer pointer;
    struct csos_ui_key key;
    int32_t wheel_delta;
};

static inline int csos_ui_transport_send(const struct csos_ui_transport *transport,
                                         const void *message, uint8_t length) {
    if (!transport || !transport->send || !message || length < 2) return -1;
    return transport->send(transport->userdata, message, length);
}

static inline int csos_ui_transport_receive(const struct csos_ui_transport *transport,
                                            void *message, uint8_t capacity) {
    if (!transport || !transport->receive || !message || capacity < 2) return -1;
    return transport->receive(transport->userdata, message, capacity);
}

static inline void csos_ui_client_init(struct csos_ui_client *client,
                                       struct csos_ui_transport transport) {
    if (!client) return;
    client->transport = transport; client->version = 0; client->capabilities = 0; client->ready = 0; client->hello_pending = 0; client->surface_valid = 0; client->focused = 0; client->wheel_delta = 0;
}

static inline int csos_ui_client_hello(struct csos_ui_client *client,
                                       uint16_t version, uint64_t capabilities) {
    uint8_t message[12];
    if (!client || csos_ui_encode_hello(message, sizeof(message), version, capabilities) == 0) return -1;
    if (csos_ui_transport_send(&client->transport, message, sizeof(message)) != 0) return -1;
    client->version = version; client->capabilities = capabilities; client->ready = 0; client->hello_pending = 1; return 0;
}

static inline int csos_ui_client_confirm_hello(struct csos_ui_client *client,
                                               const void *message, uint8_t length) {
    struct csos_ui_hello ack;
    if (!client || !client->hello_pending ||
        !csos_ui_decode_hello_ack((const uint8_t *)message, length, &ack) ||
        ack.version != client->version || (ack.capabilities & client->capabilities) != client->capabilities)
        return -1;
    client->capabilities = ack.capabilities; client->ready = 1; client->hello_pending = 0; return 0;
}

static inline int csos_ui_client_receive_hello_ack(struct csos_ui_client *client,
                                                   void *message, uint8_t capacity) {
    if (!client || !client->hello_pending) return -1;
    const int length = csos_ui_transport_receive(&client->transport, message, capacity);
    if (length < 2 || length > 255) return -1;
    return csos_ui_client_confirm_hello(client, message, (uint8_t)length) == 0 ? length : -1;
}

static inline int csos_ui_client_present(struct csos_ui_client *client, uint32_t surface_id,
                                         uint64_t generation, struct csos_ui_damage damage) {
    uint8_t message[22];
    if (!client || !client->ready || csos_ui_encode_present(message, sizeof(message), surface_id, generation, damage) == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, sizeof(message));
}

static inline int csos_ui_client_create_window(struct csos_ui_client *client, uint16_t width,
                                               uint16_t height, const char *title, uint8_t title_length) {
    uint8_t message[135];
    const uint8_t length = csos_ui_encode_create_window(message, sizeof(message), width, height, title, title_length);
    if (!client || !client->ready || length == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, length);
}

static inline int csos_ui_client_destroy_window(struct csos_ui_client *client, uint32_t id) {
    uint8_t message[6];
    if (!client || !client->ready || csos_ui_encode_destroy_window(message, sizeof(message), id) == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, sizeof(message));
}

static inline int csos_ui_client_open_file(struct csos_ui_client *client, const char *path, uint8_t path_length) {
    uint8_t message[255];
    const uint8_t length = csos_ui_encode_open_file(message, sizeof(message), path, path_length);
    if (!client || !client->ready || length == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, length);
}

static inline int csos_ui_client_set_timer(struct csos_ui_client *client, uint32_t timer_id, uint64_t ticks) {
    uint8_t message[14];
    const uint8_t length = csos_ui_encode_set_timer(message, sizeof(message), timer_id, ticks);
    if (!client || !client->ready || length == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, length);
}

static inline int csos_ui_client_connect(struct csos_ui_client *client, const char *address,
                                         uint8_t address_length, uint16_t port) {
    uint8_t message[255];
    const uint8_t length = csos_ui_encode_connect(message, sizeof(message), address, address_length, port);
    if (!client || !client->ready || length == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, length);
}

static inline int csos_ui_client_audio(struct csos_ui_client *client, uint32_t sample_rate, uint8_t channels) {
    uint8_t message[7];
    const uint8_t length = csos_ui_encode_audio(message, sizeof(message), sample_rate, channels);
    if (!client || !client->ready || length == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, length);
}

static inline int csos_ui_client_clipboard_set(struct csos_ui_client *client, const char *text, uint8_t text_length) {
    uint8_t message[255];
    const uint8_t length = csos_ui_encode_clipboard_set(message, sizeof(message), text, text_length);
    if (!client || !client->ready || length == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, length);
}

static inline int csos_ui_client_resize(struct csos_ui_client *client, uint16_t width, uint16_t height) {
    uint8_t message[6];
    if (!client || !client->ready || csos_ui_encode_resize(message, sizeof(message), width, height) == 0) return -1;
    return csos_ui_transport_send(&client->transport, message, sizeof(message));
}

static inline int csos_ui_client_close(struct csos_ui_client *client) {
    uint8_t message[2];
    if (!client || !client->ready || csos_ui_encode_close(message, sizeof(message)) == 0) return -1;
    const int result = csos_ui_transport_send(&client->transport, message, sizeof(message));
    client->ready = 0; client->hello_pending = 0; client->surface_valid = 0; client->focused = 0; return result;
}

static inline int csos_ui_client_receive_response(struct csos_ui_client *client,
                                                   void *message, uint8_t capacity) {
    if (!client || !client->ready) return -1;
    const int length = csos_ui_transport_receive(&client->transport, message, capacity);
    return length >= 2 && csos_ui_response_valid((const uint8_t *)message, (uint8_t)length) ? length : -1;
}

/* Receive one validated response and apply transport-level lifecycle effects.
 * Payload-specific decoding remains explicit through the typed decoder helpers. */
static inline int csos_ui_client_process_response(struct csos_ui_client *client,
                                                  void *message, uint8_t capacity,
                                                  uint8_t *kind) {
    const int length = csos_ui_client_receive_response(client, message, capacity);
    if (length < 0) return -1;
    const uint8_t response_kind = ((const uint8_t *)message)[0];
    if (kind) *kind = response_kind;
    if (response_kind == CSOS_UI_SURFACE_CREATED &&
        csos_ui_decode_surface_created((const uint8_t *)message, (uint8_t)length, &client->surface))
        client->surface_valid = 1;
    else if (response_kind == CSOS_UI_SURFACE_DESTROYED) {
        uint32_t destroyed_id = 0;
        if (csos_ui_decode_surface_destroyed((const uint8_t *)message, (uint8_t)length, &destroyed_id) &&
            client->surface_valid && client->surface.id == destroyed_id) client->surface_valid = 0;
    }
    if (response_kind == CSOS_UI_FAILURE) { client->ready = 0; client->hello_pending = 0; client->surface_valid = 0; client->focused = 0; }
    return length;
}

static inline int csos_ui_client_receive_event(struct csos_ui_client *client,
                                               void *message, uint8_t capacity) {
    if (!client || !client->ready) return -1;
    const int length = csos_ui_transport_receive(&client->transport, message, capacity);
    return length >= 2 && csos_ui_event_valid((const uint8_t *)message, (uint8_t)length) ? length : -1;
}

static inline int csos_ui_client_process_event(struct csos_ui_client *client,
                                               void *message, uint8_t capacity,
                                               uint8_t *kind) {
    const int length = csos_ui_client_receive_event(client, message, capacity);
    if (length < 0) return -1;
    const uint8_t event_kind = ((const uint8_t *)message)[0];
    if (kind) *kind = event_kind;
    if (event_kind == CSOS_UI_FOCUS) {
        int focused = 0;
        if (csos_ui_decode_focus((const uint8_t *)message, (uint8_t)length, &focused)) client->focused = focused;
    } else if (event_kind == CSOS_UI_POINTER) {
        (void)csos_ui_decode_pointer((const uint8_t *)message, (uint8_t)length, &client->pointer);
    } else if (event_kind == CSOS_UI_KEY) {
        (void)csos_ui_decode_key((const uint8_t *)message, (uint8_t)length, &client->key);
    } else if (event_kind == CSOS_UI_WHEEL) {
        (void)csos_ui_decode_wheel((const uint8_t *)message, (uint8_t)length, &client->wheel_delta);
    } else if (event_kind == CSOS_UI_EVENT_CLOSE) { client->ready = 0; client->hello_pending = 0; client->surface_valid = 0; client->focused = 0; }
    return length;
}

#endif
