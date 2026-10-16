# Spike A — does an injected DLL load into the client under Wine?

This is the first increment past the §13.1 launch spike and the gate for **both**
driving ([`driving.md`](driving.md)) and read instrumentation
([`instrumentation.md`](instrumentation.md)): before building any tap or driver,
prove the **injection vector works at all** under Wine, and that the client stays
up with a foreign module loaded.

**Status: implemented and passing.** It mirrors
[`../docker/verify-launch.sh`](../docker/verify-launch.sh): one process, an explicit
hold window, a single `PASS:`/`FAIL:` line and a matching exit code. Like the launch
spike it **does not log in and needs no account** — it stops at "the process
launches and stays up", now with the probe DLL injected.

## Run

```sh
make build          # builds the box AND builds the injection proxy (box-proxy.sh)
make inject-spike   # PASS if the probe loads into KakaoTalk.exe and it stays up
```

Observed PASS:

```
>> installing proxy for 'Vox3.dll' (original kept as 'Vox3__orig.dll')
>> launching: .../KakaoTalk.exe (hold 20s)
loaded pid=... host=C:\Program Files\Kakao\KakaoTalk\KakaoTalk.exe
PASS: probe loaded into KakaoTalk.exe via proxied Vox3.dll and the client stayed up for 20s
```

## The probe

[`../patches/loadprobe/loadprobe.c`](../patches/loadprobe/loadprobe.c) is a trivial,
do-nothing DLL body. On `DLL_PROCESS_ATTACH` it appends one line naming the host
process to a marker file and returns `TRUE`. It hooks nothing and contains no client
internals or offsets — our own code, committable where a real tap is not (DESIGN §11).

## Mechanism: proxy a client-bundled static import

The vector that works under Wine is **DLL proxying of a client-bundled import** —
the pattern the Matrix–WeChat box uses ([`alternatives.md`](alternatives.md)):

1. Pick a DLL that ships *with* the client and is **statically imported** by the
   exe (so it loads at process startup, and so it is a real file we can rename and
   forward to — a Wine builtin has no file to forward to).
2. Build a **proxy**: our `loadprobe.c` `DllMain` (writes the marker) plus
   **forwarder exports** for every symbol, pointing at a renamed copy of the
   original. The proxy therefore satisfies every import the client resolves while
   running our code first.
3. Keep the original as `<name>__orig.dll` (the forward target) and shadow the
   original name with the proxy.

Build-time vs runtime split:

- [`../docker/box-proxy.sh`](../docker/box-proxy.sh) runs at **image-build time**:
  it discovers the target, generates forwarders, and compiles the proxy — but does
  **not** swap it in, so the image's client stays pristine for
  `verify-launch.sh`.
- [`../docker/verify-inject.sh`](../docker/verify-inject.sh) does the **reversible
  swap at runtime**, launches, checks the marker + liveness, then restores.

Forwarders are generated from the target's **own exports at build time** by
[`../patches/dllproxy/gen-forwarders.sh`](../patches/dllproxy/gen-forwarders.sh)
(via `gendef`), so **no client-specific symbol list is committed** — it is derived
from whatever DLL is present, which keeps the spike implementation-neutral and lets
it survive a re-baseline onto a new client build (DESIGN §11, §12).

### Why not `WINEDLLOVERRIDES` / `AppInit_DLLs`

- `WINEDLLOVERRIDES` only sets the **native/builtin load order** for a module
  *name*; by itself it does **not** force an otherwise-unreferenced DLL into a
  process. (The production hook ([`driving.md`](driving.md) §2) still uses it — to
  force a seam module *native* — but it is not what triggers the load.)
- `AppInit_DLLs` would be the import-agnostic trigger on real Windows, but **Wine
  does not honor it**: a probe registered via `AppInit_DLLs` did not load even into
  `notepad` (a guaranteed `user32` GUI process). Confirmed on Wine 10; do not rely
  on it under Wine.

Proxying a bundled static import sidesteps both: it is a normal, guaranteed load
the client itself performs, and it is also the production-realistic seam (the hook
will proxy/patch a *chosen* module; this spike just proves the vector with a benign
one).

## PASS / FAIL

- **PASS** — the marker names `KakaoTalk.exe` (the probe loaded into the client
  process, not a Wine helper) **and** the client is still running after the hold
  window.
- **FAIL** — no marker for `KakaoTalk.exe` (the proxy did not load), **or** the
  client exited within the hold window (the proxy broke startup, or anti-tamper
  tripped — see driving.md §6).

## What this unblocks, and what it doesn't

A PASS proves a module reaches the client's address space and the client tolerates
it. It does **not** prove a tap can read a seam or a driver can call an internal
function — that is **Spike B** (driving.md §5), which is account-bearing and comes
next. Spike A is the cheap, account-free probe that must pass first.

## Known limitation

`box-proxy.sh` walks the client-bundled DLLs the exe statically imports in name
order and uses the first one for which a proxy builds with at least one name-based
forwarder. A candidate is skipped (with a message on stderr) if forwarder
generation fails, it exports nothing by name (e.g. import-by-ordinal only, which
name-based forwarders cannot satisfy), or the proxy fails to link. The script fails
only when no candidate qualifies. Not detected at build time: a candidate that
links with forwarders but still does not satisfy the exe's imports at runtime
(for example, some imports are by ordinal while others are by name); that still
shows up as a spike FAIL.

## Scope and safety (DESIGN §11)

No credentials, captures, or device identifiers. No login. The probe and generator
carry no proprietary bytes, offsets, or committed symbol lists. The proxied module
is **discovered at build time, not hardcoded** in the tooling; module names that
appear in examples/output below are the ones observed on the current client build,
shown as evidence, not values the code depends on. Real taps/drivers remain
uncommitted, reviewed artifacts.
