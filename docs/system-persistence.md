# CSOS system/state separation

The first infrastructure gate now has a concrete FAT layout:

```text
/system/config/defaults/   versioned, reproducible defaults
/data/config/              machine-generated state (hardware.csc, boot/install state)
/home/                     user data boundary
/nix/                      reserved persistent Nix boundary
```

The kernel seeds this layout idempotently during boot. The hardware profile is
created, read, verified, and updated below `/data/config`; it is no longer a
root-level system file. Boot recovery state, installation transaction state,
and the persistent state probe use the same persistent boundary. UI assets
remain below `/system/ui`, which is versioned system content.

Evidence from the bounded QEMU boot:

```text
persistent layout ready: /system/config/defaults /data/config /home /nix
hardware.csc generated in /data/config
CSOS M16 hardware profile ready
CSOS installation completed
CSOS graphical session ready
```

A second bounded boot reuses the same persisted profile and reports:

```text
hardware.csc reused from /data/config
CSOS installation reused
CSOS boot health ready
```

The same behavior was re-run through the official `zig build run` path after
the smoke runner was changed to send QEMU's graceful `quit` command before its
bounded cleanup.  The first run (`zig-out/smoke-d6e6d6bfeb0d47809ed48ed92a88ff50.serial.log`)
reached `CSOS graphical session ready`; the following run
(`zig-out/smoke-9bc276229f114507afa8b8fafa0f7e83.serial.log`) reported
`hardware.csc reused from /data/config`.  Both runs exited with code 0 and no
QEMU process remained.  This proves persistence across two boots of the same
FAT-backed storage image; the installed-storage Git reset demonstration is
still the remaining P0 gate.

The test runner terminates the emulator after the bounded smoke test; no QEMU
process is left running. P0 still requires a real installed-storage reset
demonstration before it is considered complete, but the runtime no longer
couples generated hardware state to the system checkout.
