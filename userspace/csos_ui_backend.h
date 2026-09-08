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
    default: return 0;
    }
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

/* Transport is supplied by the CSOS userspace runtime, not by this header. */
int csos_ui_send(const void *message, uint8_t length);
int csos_ui_receive(void *message, uint8_t capacity);

#endif
