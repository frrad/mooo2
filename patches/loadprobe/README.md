# `loadprobe` — injection probe (Spike A)

A minimal, do-nothing hook DLL built from [`loadprobe.c`](loadprobe.c). It is the
first artifact in the [`../`](../) tap seam, and exists only to answer the gating
question for both driving ([`../../docs/driving.md`](../../docs/driving.md)) and
read instrumentation ([`../../docs/instrumentation.md`](../../docs/instrumentation.md)):

> Can an injected DLL be loaded into the boxed client's process under Wine at all?

On `DLL_PROCESS_ATTACH` it appends one line to a marker file naming the host
process, then returns `TRUE`. Nothing else. See
[`../../docs/inject-spike.md`](../../docs/inject-spike.md) for how it is loaded
(the `WINEDLLOVERRIDES` + `AppInit_DLLs` mechanism) and the PASS/FAIL criteria.

## Why this is committable (DESIGN §11)

It is **our own** code: no client internals, no hooks into the client, no reversed
entry points, and no offsets. A real tap/driver (the §5.2 seams) is a separate,
reviewed artifact and still is **not** committed. This probe only proves the
*vector*, so it carries nothing proprietary.

## Build

Cross-compiled with mingw-w64 in a dedicated Docker stage (see
[`../../Dockerfile`](../../Dockerfile)); no local toolchain needed:

```sh
x86_64-w64-mingw32-gcc -O2 -shared -o loadprobe.dll loadprobe.c -luser32
```
