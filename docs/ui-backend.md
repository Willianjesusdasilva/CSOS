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

The public C client in `userspace/csos_ui_backend.h` provides the canonical
sequence:

```text
client_init → hello → hello_ack/confirm → create/resize → present → receive events/responses → close
```

Its transport is callback-based, so a port may use a CSOS socket, an IPC
channel, or a shared ring without changing the engine-facing API. Requests and
events are validated before the client accepts them.

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
