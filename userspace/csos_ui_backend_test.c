#include "csos_ui_backend.h"

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
    return csos_ui_event_valid((uint8_t[]){ CSOS_UI_FOCUS, 3, 1 }, 3) ? 0 : 6;
}
