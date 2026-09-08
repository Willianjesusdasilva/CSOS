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

Responses use the same envelope: `surface_created` (27 bytes, including the
opaque buffer handle, dimensions, stride, pixel format and generation),
`surface_destroyed`, or `failure`. The surface response is the only way for an
engine to learn a shared-buffer handle; raw kernel pointers are never exposed.

The `hello` request negotiates protocol version 1 and capability bits for
surfaces, damage, input, clipboard, timers, IPC, windows, and audio. Unsupported
versions are rejected before an engine starts rendering.
