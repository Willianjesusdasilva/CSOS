# CSOS UI Backend

`graphics/ui_backend.zig` is the engine-neutral boundary between a userspace
HTML engine and the CSOS window/compositor stack. The engine never receives a
kernel pointer and the window manager never sees DOM or CSS.

## Flow

```text
engine process -> wire messages -> UI backend -> surface/damage -> compositor
compositor -> event wire messages -> engine process
```

The current SDL/HTML runtime is an adapter and fallback. A future WPE/WebKit
or other engine can use the same backend without changing the Window Manager.

## Wire envelope

Every message is little-endian and starts with two bytes:

```text
byte 0: message kind
byte 1: total message length, including these two bytes
```

Requests include `hello`, `present`, `create_window`, `destroy_window`,
`open_file`, `connect`, `audio`, `set_timer`, and `close`. Events include
pointer, wheel, key, focus, timer, and close. Strings are length-prefixed and
bounded; no message contains a pointer.

Responses use the same envelope: `hello_ack` (12 bytes, confirming the
negotiated version and capability bits), `surface_created` (27 bytes, including the
opaque buffer handle, dimensions, stride, pixel format and generation),
`surface_destroyed`, or `failure`. The surface response is the only way for an
engine to learn a shared-buffer handle; raw kernel pointers are never exposed.

The Zig userspace client uses `graphics/ui_backend.zig` as the canonical
sequence:

```text
client_init → hello → hello_ack/confirm → create/resize → present → receive events/responses → close
```

The compatibility C client in `userspace/csos_ui_backend.h` mirrors this
sequence for ABI validation only. The transport is callback-based, so a port
may use a CSOS socket, an IPC channel, or a shared ring without changing the
engine-facing API. Requests and events are validated before the client accepts
them.

The Zig backend exposes the same seam through `WireTransport` and
`Backend.pumpTransport`: one bounded request and response can be moved through
the caller-supplied endpoint while framing and validation remain centralized.
On the kernel side, `kernel/ui_ipc.zig` supplies the bounded mailbox used by
that future endpoint; it transports frames only and has no visual policy.

The `hello` request negotiates protocol version 1 and capability bits for
surfaces, damage, input, clipboard, timers, IPC, windows, and audio. Unsupported
versions are rejected before an engine starts rendering.
### Decodificação de respostas

O cliente C pode interpretar o lifecycle sem conhecer estruturas internas do
Window Manager usando `csos_ui_decode_surface_created`,
`csos_ui_decode_surface_destroyed` e `csos_ui_decode_failure`. Assim, resize,
fechamento e falhas de transporte permanecem determinísticos sem acoplar o
engine a DOM, CSS ou drivers.

## Vertical slice userspace

`userspace/csos_ui_demo.c` é uma aplicação mínima independente do renderer
HTML. Ela usa somente `csos_ui_backend.h` e percorre handshake, criação de
superfície, pintura, `present`, mouse, teclado, resize e close. O transporte
em memória simula o endpoint do Window Manager/compositor e pode ser trocado
por socket, canal IPC ou shared ring sem alterar a aplicação:

```text
zig cc -std=c11 -Wall -Werror userspace/csos_ui_demo.c -I userspace -o csos_ui_demo
./csos_ui_demo
```

## HTML/CSS desktop vertical slice

`userspace/csos_ui_html_demo.c` is the first file-backed UI proof. It loads
`system/ui/interface/desktop.html`, the external stylesheet, registered
read-only providers and the allow-listed `open_files` action before creating a
surface and sending `present` through `csos_ui_backend`. No layout or theme is
defined in `kernel/main.zig` for this slice.

```text
zig cc -std=c11 -Wall -Werror userspace/csos_ui_html_demo.c -I userspace -o csos_ui_html_demo
./csos_ui_html_demo
```

On Windows the same check is reproducible with
`powershell -File tools/test-ui-slice.ps1`; it compiles with `-Wall -Werror`
and runs the file-backed userspace composition. The primary implementation is
`userspace/ui_slice.zig`, which loads the manifest, expands providers, routes
pointer input and presents through `graphics/ui_backend.zig`; the C program is
kept as an ABI compatibility check for `csos_ui_backend.h`.

`userspace/ui_ipc_loopback.zig` is the executable transport contract probe. It
serializes requests, decodes them at an endpoint boundary, applies only
surface lifecycle/present state, serializes the response, and decodes it back.
It is deliberately visual-neutral; its bounded buffers can later be replaced
by the kernel IPC channel or a shared ring without changing the HTML engine or
the compositor contract.

Application chrome is declared independently in
`system/ui/interface/apps.manifest`. The Zig userspace composition loads its
HTML fragments and `apps.css`, expands the same read-only providers, and applies
the same action/capability allow-list without coupling application layout to
the compositor.

The Zig proof also exercises an independent application surface through input,
present, resize/focus, and destroy lifecycle transitions; the compositor-facing
backend remains visual-engine neutral.
