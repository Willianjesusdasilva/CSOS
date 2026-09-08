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

/* Every message starts with kind:u8, total_length:u8. */
struct csos_ui_message_header { uint8_t kind; uint8_t total_length; };

struct csos_ui_damage { uint16_t x, y, width, height; };
struct csos_ui_hello { uint16_t version; uint64_t capabilities; };
struct csos_ui_present { uint32_t surface_id; uint64_t generation; struct csos_ui_damage damage; };
struct csos_ui_surface { uint32_t id, width, height, stride; uint64_t generation; };

/* Transport is supplied by the CSOS userspace runtime, not by this header. */
int csos_ui_send(const void *message, uint8_t length);
int csos_ui_receive(void *message, uint8_t capacity);

#endif
