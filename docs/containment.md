# Containing the boxed reference client

How the boxed official client can reach state, and where we intercept each
channel. Companion to [`../DESIGN.md`](../DESIGN.md) §5 (input surface and
grey-box taps) and §10 (hosting the reference). Methodology only — no
credentials, captures, device identifiers, or binary-specific addresses.

## Why containment is the whole game

The reference client is an **untrusted proprietary binary** we run on purpose.
For the oracle to be sound, every input it consumes and every output it produces
must be observable and, where nondeterministic, controllable (DESIGN §9). That is
the same requirement as sandboxing it: enumerate every way it can touch state and
put a seam on each one.

The decisive structural fact is that the client does not run on Windows — it runs
on the **official Windows build under Wine, inside a container, headless under
Xvfb** (DESIGN §10). Wine is not an emulator: it translates each Win32 call into a
host primitive. So almost every "Windows" state access becomes a host-level
artifact we already know how to mediate — a socket, a file under the Wine prefix,
a `/dev/urandom` read, a `gettimeofday` syscall. That gives two interception
tiers, and the shipped client's protection layer (see the anti-tamper section)
makes the choice between them easy.

- **Tier 1 — out-of-process, no binary modification. This is the plan.** Mediate
  at the container boundary and the Wine prefix. Robust against anti-tamper (we
  never touch the binary), stable across client releases, and sufficient for
  *control* of every nondeterministic input. Its limit: network capture here is
  ciphertext (decryptable once RNG is seized and a candidate key schedule exists;
  see the network section).
- **Tier 2 — in-process grey-box taps (DESIGN §5.2). Deferred to future work.** An
  injected DLL via `WINEDLLOVERRIDES` (seam already wired in
  [`../docker/entrypoint.sh`](../docker/entrypoint.sh) via `KAKAO_HOOK_OVERRIDES`)
  to read plaintext before TLS, straight from the reference. It is the only way to
  get reference-side plaintext with zero candidate dependency — but it runs *inside*
  the protected process, and the protector actively fights exactly this. We do not
  build it now. The seam stays wired and empty so it can be attempted later without
  touching the rest of the design.

Everything below is Tier 1 unless a paragraph is explicitly marked future work.

## State-access channels and where we intercept

Grouped by DESIGN §5.1's neutralization strategy. The "observed via" column is
grounded in the client's PE import table (the OS surfaces it links against), not
in any internal address.

### Network — the reason the oracle exists

- **What it touches.** A persistent socket session (the LOCO transport, via
  `WS2_32`) plus HTTPS (`WINHTTP` + `CRYPT32`) for auxiliary endpoints. This is
  the only channel that reaches off-box, and the only one that can affect a live
  account.
- **Tier 1 interception (container boundary).** All sockets pass through Wine's
  winsock into the container's network namespace. Mediate there:
  - **Gate outbound** so only the reference's packets reach the server — this is
    the "always run both is safe" gate (DESIGN §4). Default-deny egress; allow only
    the known server endpoints; everything else is dropped and logged.
  - **Fan inbound** to both sides (DESIGN §4). Inbound is received once at the
    interpose and delivered to reference and candidate identically.
  - A transparent proxy / `netns` interpose is the natural home for both.
  - Limitation: at this layer the LOCO payload is **ciphertext**. You can prove
    *what bytes* crossed, not *what they mean* — until RNG is seized (below). With
    the entropy stream seized, the client's ephemeral keys/IVs derive from material
    *we chose*, so a candidate key schedule can reconstruct the session key and
    decrypt the capture **without any in-process hook**. That is the Tier-1 route
    to meaning: it depends on the candidate's crypto rather than on tapping the
    reference.
- **Tier 2 interception (grey-box crypto tap, DESIGN §5.2 #1) — future work.** Hook
  after inbound decrypt / before outbound encrypt to capture **plaintext packets**
  straight from the reference, with zero candidate dependency. Deferred: this hook
  lives inside the protected process (see the anti-tamper section). Until then,
  reference-side plaintext before a trustworthy candidate crypto layer exists is a
  gap we accept.

### Clock — seized

- **What it touches.** Wall clock, monotonic/high-resolution counters, tick
  counts (`kernel32` time APIs → Wine `ntdll` → host `clock_gettime`/
  `gettimeofday`). Feeds timestamps, timeouts, retry timing.
- **Interception (Tier 1).** `libfaketime` via `LD_PRELOAD` on the Wine process
  tree pins and advances wall clock deterministically; for monotonic sources that
  faketime cannot reach, a thin Wine `ntdll` time shim is the fallback. Record the
  stream on the reference, inject it into the candidate (DESIGN §5.1 "seized").

### RNG / entropy — seized

- **What it touches.** The CSPRNG (`bcrypt` / `RtlGenRandom`) → Wine `ntdll` →
  host `/dev/urandom` / `getrandom`. Feeds IVs, ephemeral keys, nonces, GUIDs, and
  client-generated message/request IDs.
- **Interception (Tier 1, at the Wine seam).** Shim the `ntdll` entropy entry
  point in the prefix to record-and-replay the byte stream. This is the same
  "seize" move as the clock and is what makes crypto-bearing output diffable at
  all (DESIGN §5.1). Doing it at Wine's `ntdll` rather than inside the client keeps
  it out-of-binary and anti-tamper-safe.

### Filesystem / local DB — snapshot

- **What it touches.** The encrypted local message DB, config, and caches under
  the client's `AppData\Local` tree, all inside `drive_c` of the Wine prefix.
- **Interception (Tier 1).** The entire prefix is a host directory. Restore it to
  a known baseline before each run and diff the post-run tree for persisted writes.
  Implemented by `prefix-snapshot.sh` / `prefix-restore.sh` / `prefix-diff.sh`
  (see [`boxing.md`](boxing.md)); because registry and device identity also live in
  the prefix, this one mechanism covers those two channels as well. For *decoded*
  record-level diffs rather than encrypted-blob diffs, add the Tier 2 **storage
  tap** (DESIGN §5.2 #2) at the serialization layer — future work.

### Registry — snapshot

- **What it touches.** Platform config and install state (`ADVAPI32` `Reg*`).
- **Interception (Tier 1, trivial under Wine).** Wine's "registry" is just files
  in the prefix (`system.reg`, `user.reg`, `userdef.reg`) — not a kernel registry.
  Snapshot and diff them as ordinary text files; seed values by writing them before
  launch.

### Device identity — snapshot / synthesized

- **What it touches.** Whatever derives the device-bound key: volume serial,
  MAC/adapter info (`IPHLPAPI`), computer/user name, machine GUID (in the registry).
- **Interception (Tier 1).** Every one of these is **synthesized by Wine**, not
  read from host hardware: volume serials and machine GUID live in the prefix
  registry, adapter identity comes from Wine's virtual NIC. Pin them in the prefix
  so the boxed client presents a stable, controlled identity (DESIGN §5.1). No host
  hardware identifiers leak in.

### Environment / locale — folded into the snapshot

- **What it touches.** Timezone, language, locale (`GetTimeZoneInformation`,
  locale APIs).
- **Interception (Tier 1).** Container env vars + Wine locale config, pinned as
  part of the snapshot baseline (DESIGN §5.1).

### Commands / UI — the driven input

- **What it touches.** High-level actions (send, open, fetch) injected through the
  GUI, which renders to `Xvfb` (`d3d11`/`dxgi`/GDI all land on the virtual display;
  no host display, no GPU passthrough).
- **Interception.** This is a deliberate *input*, not a leak: the scenario driver
  injects it and it is recorded as part of the contract `Input` (DESIGN §6).

### Child processes & shell-out — contained by construction

- **What it touches.** The install ships helper executables (a crash reporter, a
  diagnostics tool) and the client can spawn processes / shell out
  (`CreateProcess`, `ShellExecuteW`). Also session/power notifications
  (`WTSAPI32`, `POWRPROF`).
- **Interception.** The container is the boundary: any child runs *inside* it with
  the same gated egress and the same prefix, reaching nothing on the host. Pin
  `wineserver` so spawns stay in the box; keep egress default-deny so a crash
  reporter cannot phone home. No extra seam needed beyond the container itself.

## Validating the state set

The channel list above and the `prefix-state.sh` state set are *declared* — a
claim that these are the only places the client reads state-bearing input. That
claim has to be checked, not assumed: the client could read something we did not
anticipate (another registry hive, a file outside the Kakao tree, a host path) and
we would see a silent parity bug later, not a flag. Because everything runs under
Wine on Linux, every access ultimately becomes a host syscall or a Wine-layer
event, so it is enumerable at runtime. Methods, cheapest first:

1. **Wine's own channels — `WINEDEBUG=+file,+reg` (start here).** Wine logs every
   file open and registry access with the resolved path, in Windows-path terms
   (more meaningful than raw host paths) and **without `ptrace`**, so it is the
   least likely to perturb the protected process. First pass: drive a scenario,
   collect the log, bucket each access as *base* (immutable), *state* (in our set),
   *host-env* (neutralized elsewhere — clock, RNG, locale, timezone, fonts), or
   *unexpected* (investigate). **Implemented** by
   [`../docker/prefix-trace.sh`](../docker/prefix-trace.sh) (default mode); it
   reuses `prefix-state.sh`'s state set as the single source of truth and emits
   per-bucket counts plus the full "unexpected" list. Methods (2) and (3) below are
   available behind `--mode strace` / `--mode bpftrace`. See
   [`boxing.md`](boxing.md) for usage.
2. **Kernel-level ground truth — eBPF/`bpftrace` on the `openat`/`read`
   tracepoints**, scoped to the Wine process tree. Catches raw syscalls that bypass
   libc (Wine's `ntdll` issues some directly), needs no `ptrace`, and is invisible
   to anti-debug checks — at the cost of a privileged (`CAP_BPF`) container. This is
   the authoritative enumerator.
3. **`strace -f` on file syscalls.** Simplest ground truth, but it attaches via
   `ptrace`; the protector may treat that as a debugger (see below), so run it from
   launch on a disposable account and treat a behavior change as itself a signal.
4. **Enforce, don't just observe (the real guarantee).** Mount the base
   **read-only** and present only the declared paths; a read outside the set then
   surfaces as `ENOENT`/`EACCES` rather than succeeding silently, and `fanotify`
   can intercept every open against the prefix mount. This turns "is the set
   complete?" from a question into an enforced invariant with violations logged —
   which is the containment goal anyway. **Implemented** by
   [`../docker/prefix-guard.sh`](../docker/prefix-guard.sh): it bind-remounts the
   immutable base read-only (writes outside the state set fail `EROFS`) and runs an
   `fanotify` `FAN_OPEN_PERM` guard that **`SIGKILL`s the client on any off-list
   open** (a hard crash) — or logs under `--log-only`. Like method (1) it is
   out-of-process (no `ptrace`, anti-tamper-safe) and reuses `prefix-state.sh`'s
   state set as the single source of truth; unlike it, it needs a privileged
   (`CAP_SYS_ADMIN`) container. Converge the allowlist with `prefix-trace.sh` before
   enabling the default kill mode. See [`boxing.md`](boxing.md) for usage.

Expect legitimate host noise (fonts, timezone, `/dev/urandom`, `/etc/resolv.conf`):
the useful question is not "what files are touched" but "is anything *state-,
identity-, or determinism-bearing* touched that we have not captured or seized."
Buckets (1) and (4) answer exactly that.

## Anti-tamper: why we start Tier-1-only

The shipped client is **packed/protected by a commercial protector** (a Themida-
family wrap; one bundled DLL is wrapped too — identified from the PE section
layout, not from any internal analysis). This is the single fact that most shapes
the plan, and it is why Tier 2 is deferred. Three consequences:

### 1. The protector can threaten the box itself, not just the taps

Themida's anti-debugger engine has a documented history of **mistaking Wine for a
debugger and crashing the protected program**, and recent versions ship a
developer-set kill-switch (`OPTION_ADVANCED_DONT_RUN_UNDER_WINE`) that refuses to
run under Wine at all — neither is anything an operator can toggle.[^wine-crash]
[^wine-option] So the protector can break **Tier 1 — the whole host — not only the
in-process taps.**

The offsetting fact: the boxed **unmodified** client already launches and stays up
under Wine (the DESIGN §13.1 spike passed). So this build either does not set the
Wine kill-switch and does not trip the anti-debug-vs-Wine crash at startup, or it
trips it only later. Launch is the easy part; **whether it survives login and a
live session under Wine is the make-or-break gate** and is still unverified
(DESIGN §12). This research promotes that spike from a formality to the
first thing that must pass before any further investment.

### 2. Tier 1 is out-of-process, so the protector mostly cannot see it

Everything in Tier 1 — network gating, filesystem/registry snapshotting, clock via
`libfaketime`, RNG via the Wine `ntdll` seam, device identity via the prefix —
touches the binary *not at all*. A protector's self-integrity and module-list
checks cannot see a `netns` rule, a faked `clock_gettime`, or a swapped host-side
Wine `ntdll` implementation; those live below the Windows modules it verifies.
This is why the entire plan lives here.

### 3. The in-process taps fight the protector directly — hence future work

The injected-DLL crypto/model/decision taps run *inside* the protected process,
and the protector is built to defeat exactly that: code virtualization of hot
routines, anti-debug threads that keep checking **after** the entry point, loaded-
module-list enumeration that spots injected DLLs, and integrity checks that catch
inline/IAT hooks.[^tm-antidebug][^tm-api][^antimida] Tools that get through exist
([Themidie], [Magicmida]) but they are **adversarial** — a per-version cat-and-
mouse unpacking effort, a different and heavier posture than a clean cooperative
"hook one seam" tap. Two caveats cut in our favor and are worth re-checking at
runtime: Themida's options are set per-licensee and many real builds enable **no
virtualization and no anti-debug at all**,[^anyrun] and the fact that this build
already runs under Wine hints the most hostile options may be off. But none of that
is worth betting the deliverable on now. The `WINEDLLOVERRIDES` seam stays wired
and empty (DESIGN §13.1) so a tap can be attempted later without touching anything
else.

### Fallback host if Wine proves hostile: a real Windows guest

If the login spike shows the protector will not tolerate Wine, the oracle design
survives by swapping the host: run the official client in a **real Windows guest
VM (KVM/QEMU) inside the container** instead of under Wine. This sidesteps Wine
detection entirely, and Tier-1 interception still works at the host/hypervisor
boundary — network gating on the VM's tap interface, the disk image as the
filesystem/registry snapshot, the VM's clock and entropy controlled from the
hypervisor. The cost: the clean "Wine prefix is just files" tricks for registry
and device identity move *in-guest*, and the box is heavier and less trivially
self-hostable, which is the specific trade DESIGN §10 chose Wine to avoid. Hold
this as plan B; do not build it unless the spike forces it.

[^wine-crash]: Plutonium forum, Themida anti-debug treating Wine as a debugger and
  crashing the program: <https://forum.plutonium.pw/topic/35590/quantom-of-solace-wine-incompatibility>
[^wine-option]: Oreans Themida changelog, `OPTION_ADVANCED_DONT_RUN_UNDER_WINE`:
  <https://www.oreans.com/ThemidaAllWhatsNew.php>
[^tm-antidebug]: Analysis of Themida anti-debugger detections (threads that keep
  checking past the entry point, hardware-breakpoint detection):
  <https://medium.com/@reversing/analysis-of-oreans-themida-x86-version-2-3-5-10-anti-debugger-detections-8328ebd858c8>
[^tm-api]: Analysis of Themida advanced API-wrapping (un-reconstructable imports):
  <https://medium.com/@reversing/analysis-of-oreans-themida-x86-version-3-0-8-0-advanced-api-wrapping-efb482c2eb11>
[^antimida]: AntiMida notes on Themida checking the loaded-module list:
  <https://ntcore.com/files/antimida_1.0.htm>
[^anyrun]: any.run analysis showing many Themida/VMProtect samples use neither
  virtualization nor anti-debug: <https://any.run/cybersecurity-blog/vmprotect-themida-malware-analysis/>

[Themidie]: https://github.com/VenTaz/Themidie
[Magicmida]: https://github.com/Hendi48/Magicmida

## Interception map (summary)

| Channel | Observed surface | Tier | Where we intercept |
| --- | --- | --- | --- |
| Network (LOCO socket, HTTPS) | `WS2_32`, `WINHTTP`, `CRYPT32` | 1 | Container netns: gate egress, fan ingress |
| Network plaintext | (crypto seam) | 2 — future | Injected DLL: before-encrypt / after-decrypt (or decrypt via seized RNG + candidate key schedule) |
| Clock | `kernel32` time → Wine `ntdll` | 1 | `libfaketime` on Wine; `ntdll` time shim fallback |
| RNG / entropy | `bcrypt`/`RtlGenRandom` → `ntdll` | 1 | Wine `ntdll` entropy shim: record/replay |
| Filesystem / local DB | `AppData\Local` in prefix | 1 (decoded records: 2 — future) | Prefix snapshot/diff; storage tap for records |
| Registry | `ADVAPI32` `Reg*` | 1 | Prefix `*.reg` files: snapshot/diff/seed |
| Device identity | `IPHLPAPI`, volume serial, machine GUID | 1 | Pin in prefix (Wine synthesizes all of it) |
| Locale / timezone | locale APIs | 1 | Container env + Wine locale, in snapshot |
| Commands / UI | GUI → `Xvfb` | — | Driven input (recorded, not a leak) |
| Child processes / shell-out | `CreateProcess`, `ShellExecuteW` | 1 | Container boundary; default-deny egress |

## What's already in place vs. next

- **In place** (merged boxing pipeline): container + Wine prefix + headless Xvfb;
  the unmodified client launches (DESIGN §13.1 spike); the `WINEDLLOVERRIDES` tap
  seam is wired but empty.
- **Gate, before anything else: the Wine login spike.** Confirm the protected
  client completes login and holds a live session under Wine on a disposable
  account. Everything below assumes this passes; if it fails, switch to the
  Windows-guest fallback above before continuing.
- **The plan — Tier 1 only (out-of-process, low anti-tamper risk), in rough
  order:**
  1. Prefix snapshot/restore for filesystem + registry + device identity.
     **Done** — full-prefix `prefix-snapshot.sh` / `prefix-restore.sh` /
     `prefix-diff.sh` for re-baselining, and `prefix-state.sh` for the fast
     per-run loop over just the ~3 MB mutable state set (see [`boxing.md`](boxing.md)).
  2. Network interpose with default-deny egress + ingress fan-out (also the
     Shadow-mode gate, DESIGN §8).
  3. Clock seize (`libfaketime`) and RNG seize (`ntdll` shim) — the latter also
     makes captured traffic decryptable via a candidate key schedule.
  4. Layered prefix: immutable read-only base + writable state layer on a volume,
     plus a dedicated payload dir for a future tap DLL (see [`boxing.md`](boxing.md)).
     Structural; pairs with (2)/(3) and pre-positions Tier 2.
- **Future work — Tier 2 (in-process), explicitly out of scope for now.** Only
  after Tier 1 is delivering, and gated on a runtime anti-tamper check: attempt one
  crypto-seam tap, confirm the protected process tolerates it, and only then
  consider the storage/model/decision taps. Treat as a research bet, not a
  commitment.
