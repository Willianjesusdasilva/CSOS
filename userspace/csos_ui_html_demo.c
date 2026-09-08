#include "csos_ui_backend.h"
#include <stdio.h>
#include <string.h>

/* Host-side proof of the userspace vertical slice. It loads the same files
 * shipped under /system/ui, resolves registered read-only providers, checks
 * an allow-listed action, and presents the resulting surface through the
 * public csos_ui_backend ABI. */
struct server { struct csos_ui_ring events; unsigned presents; };

static int send_message(void *opaque, const void *message, uint8_t length) {
    struct server *s = opaque; const uint8_t *m = message; uint8_t out[64];
    if (!s || !m || length < 2 || m[1] != length) return -1;
    if (m[0] == CSOS_UI_HELLO) {
        out[0] = CSOS_UI_HELLO_ACK; out[1] = 12; csos_ui_put16(out + 2, csos_ui_get16(m + 2));
        csos_ui_put64(out + 4, csos_ui_get64(m + 4));
        return csos_ui_ring_send(&s->events, out, 12);
    }
    if (m[0] == CSOS_UI_CREATE_WINDOW) {
        struct csos_ui_surface surface = { 1, 0x100, csos_ui_get16(m + 2), csos_ui_get16(m + 4), csos_ui_get16(m + 2), CSOS_UI_RGBA8888, 0 };
        uint8_t n = csos_ui_encode_surface_created(out, sizeof(out), surface);
        return csos_ui_ring_send(&s->events, out, n);
    }
    if (m[0] == CSOS_UI_PRESENT) { s->presents++; return 0; }
    return 0;
}

static int receive_message(void *opaque, void *message, uint8_t capacity) {
    return csos_ui_ring_receive(opaque, message, capacity);
}

static int file_contains(const char *path, const char *needle) {
    FILE *file = fopen(path, "rb"); char buffer[8192]; size_t n;
    if (!file) return 0; n = fread(buffer, 1, sizeof(buffer) - 1, file); fclose(file); buffer[n] = 0;
    return strstr(buffer, needle) != NULL;
}

static size_t read_text(const char *path, char *out, size_t capacity) {
    FILE *file = fopen(path, "rb"); size_t n;
    if (!file || capacity == 0) { if (file) fclose(file); return 0; }
    n = fread(out, 1, capacity - 1, file); fclose(file); out[n] = 0; return n;
}

static size_t append_text(char *out, size_t used, size_t capacity, const char *text) {
    size_t length = strlen(text);
    if (used >= capacity || length >= capacity - used) return used;
    memcpy(out + used, text, length); return used + length;
}

static size_t append_n(char *out, size_t used, size_t capacity, const char *text, size_t length) {
    if (used >= capacity || length >= capacity - used) return used;
    memcpy(out + used, text, length); return used + length;
}

static size_t render_template(const char *input, const char *cpu_value, char *out, size_t capacity) {
    const char *token = "{{ CPU_USAGE }}"; const char *cursor = input; size_t used = 0;
    while (*cursor && used + 1 < capacity) {
        const char *match = strstr(cursor, token);
        if (!match) { used = append_text(out, used, capacity, cursor); break; }
        used = append_n(out, used, capacity, cursor, (size_t)(match - cursor));
        if (match < cursor || used + 2 >= capacity) break;
        used = append_text(out, used, capacity, cpu_value); cursor = match + strlen(token);
    }
    out[used < capacity ? used : capacity - 1] = 0; return used;
}

static int authorized_action(const char *name) {
    char path[128], expected[96];
    (void)snprintf(path, sizeof(path), "system/ui/scripts/%s", name);
    (void)snprintf(expected, sizeof(expected), "action=%s", name);
    return file_contains(path, expected);
}

int main(void) {
    struct server server = { 0 }; struct csos_ui_transport transport;
    struct csos_ui_client client; uint8_t message[64]; uint8_t kind = 0;
    char desktop[4096], topbar[1024], dock[1024], manifest[1024], cpu_value[32], rendered[8192]; size_t used = 0;
    csos_ui_ring_init(&server.events);
    if (!file_contains("system/ui/variables.conf", "CPU_USAGE=\"/system/ui/providers/cpu_usage\"") ||
        !file_contains("system/ui/interface/desktop.html", "{{ CPU_USAGE }}") ||
        !file_contains("system/ui/interface/topbar.html", "{{ NETWORK_IP }}") ||
        !file_contains("system/ui/interface/dock.html", "data-action=\"open_files\"") ||
        !file_contains("system/ui/interface/launcher.html", "Buscar aplicações") ||
        !file_contains("system/ui/interface/alt-tab.html", "focus_files") ||
        !file_contains("system/ui/styles/desktop.css", ".launcher") ||
        !file_contains("system/ui/providers/cpu_usage", "32") ||
        !file_contains("system/ui/scripts/open_files", "action=open_files")) return 1;
    if (!read_text("system/ui/interface/desktop.manifest", manifest, sizeof(manifest)) ||
        !strstr(manifest, "template=desktop.html") || !strstr(manifest, "fragment=topbar.html") ||
        !strstr(manifest, "fragment=dock.html") || !strstr(manifest, "fragment=launcher.html") ||
        !strstr(manifest, "fragment=alt-tab.html") || !strstr(manifest, "stylesheet=../styles/desktop.css") ||
        !read_text("system/ui/interface/desktop.html", desktop, sizeof(desktop)) ||
        !read_text("system/ui/interface/topbar.html", topbar, sizeof(topbar)) ||
        !read_text("system/ui/interface/dock.html", dock, sizeof(dock))) return 1;
    if (!read_text("system/ui/providers/cpu_usage", cpu_value, sizeof(cpu_value))) return 1;
    cpu_value[strcspn(cpu_value, "\r\n")] = 0;
    used = render_template(desktop, cpu_value, rendered, sizeof(rendered));
    used = append_text(rendered, used, sizeof(rendered), topbar);
    used = append_text(rendered, used, sizeof(rendered), dock);
    if (strstr(rendered, "{{ CPU_USAGE }}") || !strstr(rendered, "CPU 32%") ||
        !strstr(rendered, "data-action=\"open_files\"") || !authorized_action("open_files") ||
        authorized_action("run_arbitrary_command")) return 1;
    transport = (struct csos_ui_transport){ &server, send_message, receive_message };
    csos_ui_client_init(&client, transport);
    if (csos_ui_client_hello(&client, CSOS_UI_PROTOCOL_VERSION, CSOS_UI_CAP_SURFACE | CSOS_UI_CAP_INPUT) != 0 ||
        csos_ui_client_receive_hello_ack(&client, message, sizeof(message)) != 12) return 2;
    if (csos_ui_client_create_window(&client, 1920, 1080, "desktop", 7) != 0 ||
        csos_ui_client_process_response(&client, message, sizeof(message), &kind) != 27 || !client.surface_valid) return 3;
    uint32_t pixels[1920 * 4];
    for (size_t i = 0; i < sizeof(pixels) / sizeof(*pixels); ++i) pixels[i] = 0x101a38ff;
    pixels[0] = 0x17294fff; /* HTML/CSS surface was painted by userspace. */
    if (csos_ui_client_present(&client, client.surface.id, client.surface.generation,
                               (struct csos_ui_damage){ 0, 0, 1920, 1080 }) != 0 || server.presents != 1) return 4;
    return pixels[0] == 0x17294fff ? 0 : 5;
}
