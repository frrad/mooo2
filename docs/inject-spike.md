# Spike A — does an injected DLL load into the client under Wine?

This is the first increment past the §13.1 launch spike and the gate for **both**
driving ([`driving.md`](driving.md)) and read instrumentation
([`instrumentation.md`](instrumentation.md)): before building any tap or driver,
prove the **injection vector works at all** under Wine, and that the client stays
up with a foreign module loaded.

It mirrors [`../docker/verify-launch.sh`](../docker/verify-launch.sh): one process,
an explicit hold window, a single `PASS:`/`FAIL:` line and a matching exit code.
Like the launch spike it **does not log in and needs no account** — it stops at
"the process launches and stays up", now with [`loadprobe.dll`](../patches/loadprobe/)
injected.

## Run

```sh
make build          # builds the box AND cross-compiles loadprobe.dll (mingw stage)
make inject-spike   # PASS if the probe loads into KakaoTalk.exe and it stays up
```

`make build` needs the pinned installer in `vendor/` (`make fetch`), exactly as the
launch spike does.

## The probe

[`../patches/loadprobe/loadprobe.c`](../patches/loadprobe/loadprobe.c) is a trivial,
do-nothing DLL. On `DLL_PROCESS_ATTACH` it appends one line naming the host process
to a marker file and returns `TRUE`. It hooks nothing and contains no client
internals or offsets — our own code, so it is committable where a real tap is not
(DESIGN §11). See [`../patches/loadprobe/README.md`](../patches/loadprobe/README.md).

## Mechanism — and an honesty note on `WINEDLLOVERRIDES`

[`driving.md`](driving.md) §2 names the seam as
`KAKAO_HOOK_OVERRIDES → WINEDLLOVERRIDES`. That is accurate for what it controls,
but it is worth being precise about what `WINEDLLOVERRIDES` does and does **not** do:

- `WINEDLLOVERRIDES` only sets the **native/builtin load order** for a module
  *name*. It makes Wine prefer our native `loadprobe.dll` over any builtin of that
  name. **It does not, by itself, force an otherwise-unreferenced DLL into a
  process** — something still has to cause the load.
- So the probe uses Wine's **`AppInit_DLLs`** as the import-agnostic **load
  trigger**: `user32` loads listed DLLs into processes at startup. This means the
  probe does not depend on the client importing any particular DLL, which keeps the
  spike **implementation-neutral** — no client imports, names, or offsets are
  baked in.

This cleanly isolates the Spike A question ("*can* an injected DLL load") from the
production hook's job ("load at a *specific seam* and call internal functions",
driving.md §5.2 / §3). The production hook will move to a seam-specific native
override or a reviewed binary patch (see [`../patches/README.md`](../patches/README.md)
mechanisms 1–2); `AppInit_DLLs` is a probe, not the shipping injection point.

[`../docker/verify-inject.sh`](../docker/verify-inject.sh) does both: forces
`loadprobe=n,b` via `WINEDLLOVERRIDES` **and** sets the `AppInit_DLLs` registry
keys, then launches the client.

## PASS / FAIL

- **PASS** — the marker file names `KakaoTalk.exe` (the probe loaded into the
  client process, not just a Wine helper) **and** the client is still running after
  the hold window (injection did not destabilize startup).
- **FAIL** — no marker for `KakaoTalk.exe` (the override / `AppInit_DLLs` path was
  not honored, or the client never reached DLL load), **or** the client exited
  within the hold window (injection broke startup, or anti-tamper tripped — see
  driving.md §6).

## What this unblocks, and what it doesn't

A PASS proves only that a module reaches the client's address space and the client
tolerates it. It does **not** prove a tap can read a seam or a driver can call an
internal function — that is **Spike B** (driving.md §5), which is account-bearing
and comes next. Spike A is the cheap, account-free probe that must pass first.

## Scope and safety (DESIGN §11)

No credentials, captures, or device identifiers. No login. The probe carries no
proprietary bytes or offsets. Real taps/drivers remain uncommitted, reviewed
artifacts.
