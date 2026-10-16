# Boxing the reference client (Wine pipeline)

This is the reproducible pipeline for DESIGN.md §10 ("Hosting the reference") and
roadmap step 1, the **Wine spike** (§13.1): box the official KakaoTalk Windows
client under Wine in a container and prove it launches headlessly. The grey-box
taps (§5.2) are a later, reviewed step — the [`patches/`](../patches/) seam is
empty for now.

## Quick start

```sh
make fetch    # download the pinned x64 installer into vendor/ and verify its SHA256
make build    # build the image: Debian + Wine, client installed into the prefix
make run      # launch spike: PASS if the client runs under Wine headlessly
make shell    # interactive shell in the image to poke at the prefix
```

`make build` depends on `make fetch`, so `make build` alone is enough after a
clean checkout.

## What is pinned, and how

| Thing | Pin | Where |
|-------|-----|-------|
| Installer bytes | SHA256 | [`../SHA256SUMS`](../SHA256SUMS), checked by `make verify` |
| Debian base | manifest digest | `DEBIAN_DIGEST` in [`../Dockerfile`](../Dockerfile) |
| Wine | exact WineHQ apt version | `WINE_VERSION` in the Dockerfile |
| winetricks | release tag | `WINETRICKS_VERSION` in the Dockerfile |

The installer itself is **never committed** (it is proprietary; see DESIGN §11).
Only its SHA256 is tracked. `vendor/` is gitignored.

### The installer URL is a rolling "latest"

`https://app-pc.kakaocdn.net/talk/win32/x64/KakaoTalk_Setup.exe` has no version in
its path — it always serves the current build. So "pinned" means the bytes must
match `SHA256SUMS`. When Kakao ships a new client, `make fetch` fails with a
checksum mismatch. **That is by design** (DESIGN §9): a new upstream build is a
deliberate re-baseline event, not a silent upgrade.

## Re-baselining on a new client release

```sh
make rebaseline   # re-download, rewrite SHA256SUMS
```

Then review and commit the new `SHA256SUMS`, rebuild, and **re-baseline any
grey-box taps** — tap offsets move every release (DESIGN §12).

## Reproducibility notes

- The hard pins (installer bytes, base image digest, Wine version, winetricks tag)
  are exact. `apt-get update` for the WineHQ/Debian repos still reaches live
  mirrors, so transitive apt dependencies are only as reproducible as those
  mirrors at build time — acceptable for a bench oracle, and documented here.
- Scripts live under [`../docker/`](../docker/): `box-install.sh` (build-time
  silent install), `entrypoint.sh` (headless X + tap seam), `verify-launch.sh`
  (the spike's pass/fail check), and the containment tools described below.

## Network interpose (Tier 1 containment)

The boxed client's only off-box channel is the network, so egress is
**default-deny** and every attempt is logged (DESIGN §4, §8;
[`containment.md`](containment.md) "Network"). `net-interpose.sh` sets it up
inside the container's network namespace, without touching the client:

- **nftables rules on the wine user's uid** (the client, `wineserver` and every
  Wine helper run as it). IPv4 DNS to any server goes to a DNS stub, every other
  IPv4 TCP connection off loopback goes to a transparent proxy, loopback is
  allowed, and everything else (UDP, ICMP, IPv6) is dropped and counted. The
  redirect runs at nat priority -101, ahead of Docker's own DNS DNAT on
  user-defined networks, and the filter accepts only flows carrying the
  conntrack mark set by our own redirect, not any DNAT. Direct traffic to
  Docker's embedded resolver (`127.0.0.11`, on its real port) is dropped and
  counted.
- **`net-interpose.py`**, running as root so its own traffic is not redirected.
  The DNS stub resolves allowlisted names for real and answers every other name
  with a unique sinkhole address from `198.18.0.0/15` (never routed). The client
  then still tries to connect, so the proxy logs the port and the TLS server name
  it wanted before resetting the connection. Allowlisted connections are spliced
  to the real server. A destination that is allowed only because an allowlisted
  name resolved to it may be a shared CDN address, so if the client opens with a
  TLS ClientHello, its SNI must be allowlisted (for that port) as well. A
  mismatch, or a ClientHello with no SNI, is denied and logged (`"reason":"sni"`)
  before any byte reaches the server. Address-allowlisted destinations and
  non-TLS flows are not SNI-checked.
- **Ingress fan-out (Shadow mode).** With `--fanout HOST:PORT`, every chunk of an
  allowed flow is also sent to each connected subscriber as a JSON line
  (`{"conn","dir":"in"|"out","b64"}`). Inbound is received once and delivered to
  the reference and the subscribers identically. Subscribers can only read, so a
  candidate attached here runs dry-run by construction. Subscribers never slow
  the reference down. Each has its own queue, bounded by `--fanout-limit` bytes
  (default 8 MiB), and a subscriber that falls that far behind is disconnected
  and logged (`"kind":"fanout","verdict":"drop"`). It is not left to buffer
  without bound, and it does not silently skip chunks.
- **Decision log** — `events.jsonl` in `$NET_RUN_DIR` (default
  `/tmp/net-interpose`): one JSON line per DNS or TCP verdict, names and addresses
  only, never payload. It is still a lab artifact; do not commit it.

```sh
make net-spike    # = docker run --rm --cap-add NET_ADMIN -u 0 <image> verify-net.sh
```

`verify-net.sh` is account-free. It launches the **unmodified** client behind the
interpose, then runs probes as the wine user: a DNS lookup, a TLS connection and a
UDP send, each of which must be denied and logged (or counted), plus a connection
to an allowlisted test server inside the container, whose reply must reach both
the probe and a fan-out subscriber. It also checks the SNI gate: a name allowlisted
for a second test port resolves to that server through the stub, and only a
ClientHello naming it gets through. Finally, it checks the fan-out bound: a 16 MiB
download must reach the probe intact while a stalled subscriber is dropped. On a user-defined network (`docker run
--network <net>`) it also queries Docker's resolver directly, and that query must
be dropped. It passes if all of that holds and the client
is still running after the hold window. It also lists what the client itself
tried to reach. Pre-login, that is a single HTTPS lookup of a Kakao CDN name.

**The allowlist hook.** `/etc/kakao/net-allowlist` ships empty (see
[`../docker/net-allowlist`](../docker/net-allowlist) for the format: exact names,
`*.suffix`, IPv4/CIDR, each with an optional `:PORT`). For the login spike, which
is a manual step on a disposable account (DESIGN §11), mount a filled-in copy:

```sh
docker run --rm --cap-add NET_ADMIN -u 0 \
  -v "$PWD/my-allowlist:/etc/kakao/net-allowlist:ro" <image> verify-net.sh
```

Start from the names `verify-net.sh` reports as client-denied, and widen it one
denied entry at a time. Do not commit a filled-in list with anything
account-specific in it.

To gate another script the same way, wrap it in `net-interpose.sh up
[--allowlist FILE] [--fanout HOST:PORT]` … `net-interpose.sh down`; stop the
client before `down`, since egress is ungated afterwards.

## Clock and RNG seize (Tier 1 containment)

The clock and the CSPRNG are the client's two nondeterministic inputs that are not
files, so they are *seized*: chosen by us, captured, and replayed (DESIGN §5.1, §9;
[`containment.md`](containment.md) "Clock", "RNG"). `seize.sh` wraps any command,
normally `wine …`, with two `LD_PRELOAD` libraries on the Wine process tree:

- **libfaketime** pins the wall clock to a start instant (`--time "@2025-01-01
  00:00:00"`, default: now) and lets it advance in real time. It fakes the host
  monotonic clock too, so `QueryPerformanceCounter` and `GetTickCount64` are covered
  as well. `seize.sh` hands libfaketime a fixed offset from the real clock rather
  than its per-process `@start` mode, so every process in the tree reads the same
  clock (see [`containment.md`](containment.md) "Clock" for why).
- **`rng-seize.so`** ([`../docker/rng-seize.c`](../docker/rng-seize.c)) replaces
  `getrandom()`, the one host call that Wine's `ntdll` makes for every Windows
  CSPRNG API. With `--seed N`, each process gets a stream derived from the seed and
  its exe name; `--log DIR` writes the bytes served to `DIR/<exe>.<pid>.rng`.

Both live below the Windows modules, so the client binary and its protector see
nothing.

```sh
# record: pin the inputs and save them
seize.sh --time "@2025-01-01 00:00:00" --seed 0x5eed --capture /work/seize.env \
         --log /work/rng -- wine "C:/.../KakaoTalk.exe"
# replay: same inputs from the capture
seize.sh --from /work/seize.env -- wine "C:/.../KakaoTalk.exe"
```

Stop `wineserver` first (`wineserver -k`). Processes that an already-running
wineserver started keep their real clock and RNG.

```sh
make seize-spike  # = docker run --rm <image> verify-seize.sh
```

`verify-seize.sh` is account-free and needs no extra privileges. It runs
`seize-probe.exe` (our own program,
[`../docker/seize-probe.c`](../docker/seize-probe.c), built into the image), which
reads every Windows clock and CSPRNG API. The probe runs three times: once with a
pinned time and seed captured to an env file, once replayed from that file, and once
with a different seed. The check passes if all of the following hold:

- the wall clock reads the pinned date, and `QueryPerformanceCounter` and
  `GetTickCount64` read within minutes of the pinned epoch (unseized, they read
  host uptime);
- all six random APIs return identical bytes on replay and different bytes under
  the other seed;
- a chain of probe processes reads one continuous clock: the first exits before
  the last starts, and the last must not read earlier than the one before it;
- the unmodified client stays up seized, with both libraries mapped into
  `KakaoTalk.exe`.

It also lists how much entropy each process drew. Pre-login, the client takes a few
hundred seeded bytes.

**Limits of the RNG stream.** Replay is exact only when each process draws in
the same order:

- Each process has one byte counter. Threads that draw concurrently interleave in
  scheduling order, so multi-threaded draw order is not replay-stable. This is the
  same residual as scheduling (DESIGN §9).
- A stream is keyed by the exe name only. Two instances of the same exe get the
  same stream.
- A `fork` without `exec` inherits the counter and repeats its parent's stream.
- The key is read from `argv[0]` on the first draw. A draw before Wine rewrites
  `argv` would be keyed as the Wine loader (e.g. `wine64`). It is still
  deterministic, but filed under that name in the `.rng` logs.

**Other limits.** In-process `RDTSC`/`RDRAND` never reach the host and stay unseized.
32-bit Wine helpers cannot load the 64-bit libraries (ld.so prints a "wrong ELF
class" note) and run unseized; the x64 client and its x64 helpers are seized. For
the login spike, pin a *current* time: TLS certificate checks fail under a date
outside the certificates' validity. A seeded client's keys are predictable by
design, so seed only a box that logs in with a disposable account (DESIGN §11).
Treat `.rng` logs and capture files as lab artifacts and do not commit them.

## Layered prefix (Tier 1 containment)

`prefix-layer.sh` runs the client from a prefix split into separately mounted
layers. This follows the Matrix–WeChat `wechat-box` precedent: an immutable Wine
base image plus mounted-in payloads.

| Layer | Where | What |
|-------|-------|------|
| **Base** (immutable) | the image's installed prefix, `/home/wine/.wine` | Wine's `C:\windows` and the installed client. These are the `BASE_PATHS` in `prefix-state.sh`, which `prefix-guard.sh` uses too. They are **symlinked** into the state layer, never copied. With `docker run --read-only` the base is read-only at the filesystem level, so a write fails `EROFS`. |
| **State** (writable) | `/var/lib/kakao/prefix`, a **tmpfs or volume** | The prefix root (registry hives, `dosdevices`) plus `users` and `ProgramData`, seeded from the base on first use (~3 MB). It is not on the container's own overlay, because overlay-on-overlay breaks. The whole `STATE_GLOBS` set lives here, so `prefix-state.sh` snapshot/restore/diff touch only this layer. |
| **Payload** | `/var/lib/kakao/payload`, linked as `C:\injector` | Empty by default. A future version-matched tap DLL is mounted here and swapped without touching the prefix. |

```sh
make layered-spike
# = docker run --rm --read-only --tmpfs /tmp:exec \
#     --tmpfs /var/lib/kakao/prefix:exec,uid=1000,gid=1000 <image> verify-layered.sh

# persistent state on a named volume, a payload mounted in, any command:
docker run --rm --read-only --tmpfs /tmp:exec \
  -v kakao-state:/var/lib/kakao/prefix -v "$PWD/taps:/var/lib/kakao/payload:ro" \
  <image> prefix-layer.sh run -- verify-launch.sh
```

`prefix-layer.sh run` assembles the state layer if it is empty (`--fresh` reseeds
it), checks the invariants, then execs the command with `WINEPREFIX` pointing at
the state layer and `KAKAO_EXE` set to the client inside it. `verify-launch.sh`
honours `KAKAO_EXE`. The invariants are:

- the base trees are linked;
- every state path resolves inside the state layer;
- the state layer is not overlayfs;
- `C:\injector` points at the payload dir;
- the base is read-only: creating a file at its root or in a linked tree fails,
  so `run` needs `docker run --read-only`.

Mount tmpfs layers with `exec`, because Wine maps PE images from them.

`verify-layered.sh` is account-free and passes if all of these hold:

- the invariants hold, and `check` fails when pointed at a writable base;
- writing into the base fails, both directly and through the prefix;
- the **unmodified** client stays up from the layered prefix;
- its writes land in the state layer, where `prefix-state.sh snapshot` captures them.

Run without `--read-only`, it fails and says so.

## Prefix snapshot / restore (Tier 1 containment)

The filesystem/DB, the Wine registry, and the synthesized device identity all
live inside `$WINEPREFIX`, so one archive snapshots all three "Snapshot" channels
of DESIGN §5.1 at once. Three scripts (shipped in the image at
`/usr/local/bin/`, source under [`../docker/`](../docker/)) implement the
"restore to a known baseline before each run, diff after" loop from
[`containment.md`](containment.md):

```sh
# capture a clean baseline (e.g. right after a fresh boot, before login)
prefix-snapshot.sh /work/baseline.tar

# ... drive the client through a scenario ...

# see what it persisted (paths added / removed / size-changed)
prefix-diff.sh /work/baseline.tar            # fast: path + size
prefix-diff.sh /work/baseline.tar --hash     # also content (sha256)

# reset the prefix to the baseline for the next run
prefix-restore.sh /work/baseline.tar
```

- `prefix-snapshot.sh` writes a deterministic tar (sorted, zeroed owner/mtime) so
  an unchanged prefix hashes identically run to run. It does not modify the prefix.
- `prefix-restore.sh` stops `wineserver`, extracts to a staging dir, then swaps —
  a failed extraction leaves the old prefix intact. It refuses obviously wrong
  targets (`/`, `/home`, `$HOME`).
- `prefix-diff.sh` reports `+ added`, `- removed`, `~ changed` paths; it is
  path+size/hash level only. Decoding the records themselves is the Tier 2 storage
  tap (future work).

### State-only snapshots (`prefix-state.sh`)

A full prefix snapshot is ~1.5 GB / ~13 s uncompressed on the current client,
because almost all of it is immutable base — Wine's own `C:\windows` (~1.4 GB) and
the installed client (~135 MB), which are identical every run and already live in
the image's read-only layers. The only state the client's output actually depends
on is the **registry + the Kakao app-data tree: ~3 MB.** `prefix-state.sh` operates
on exactly that set:

```sh
prefix-state.sh snapshot /work/state.tar      # ~3 MB, not 1.5 GB
prefix-state.sh diff     /work/state.tar       # path+size; add --hash for content
prefix-state.sh restore  /work/state.tar       # resets state only; base untouched
```

The state set (single source of truth, in the script): `system.reg`, `user.reg`,
`userdef.reg`, and `drive_c/users/*/AppData/{Local,Roaming,LocalLow}/Kakao` (plus
`drive_c/ProgramData/Kakao` if present); `Temp` is excluded as run noise. `restore`
clears those paths and extracts the baseline over them, leaving the base in place —
verified: a tampered base file survives a state restore.

Use `prefix-state.sh` for the per-run snapshot/restore/diff loop. Use the
full-prefix `prefix-snapshot.sh` only to re-baseline the whole box on a new client
release (DESIGN §9).

**Is the state set complete?** It is a *declared* set, validated by observation —
see "Validating the state set" in [`containment.md`](containment.md) for the
method, and `prefix-trace.sh` below for the implementation.

### Validating the state set at runtime (`prefix-trace.sh`)

The snapshot/diff tools above show what the client *wrote*. They cannot show what
it *read* — including reads of paths we never provisioned (a probe for a missing
file is itself a signal). `prefix-trace.sh` closes that gap: it launches the
boxed client, records every file and registry access, and classifies each one, so
the claim "the state set is the only state-bearing thing the client reads" becomes
checkable rather than assumed.

```sh
# default: WINEDEBUG trace of a ~20s headless launch (no login), then report
prefix-trace.sh

prefix-trace.sh --seconds 30            # longer exercise window
prefix-trace.sh --keep --out /work      # retain the raw log under /work
prefix-trace.sh --strict                # exit non-zero if anything is "unexpected"
prefix-trace.sh --mode strace           # ptrace ground truth (caveat below)
prefix-trace.sh --mode bpftrace         # eBPF ground truth (needs CAP_BPF)
```

It reuses `prefix-state.sh`'s `STATE_GLOBS` as the single source of truth (it
`source`s the script; the state set is never redefined), and buckets every access
as:

- **base** — immutable Wine/client install (`C:\windows`, the installed client
  under `Program Files\Kakao`, the host Wine runtime, Wine's XDG desktop
  integration). Expected, ignorable.
- **state** — inside the declared state set (registry hives + the Kakao AppData /
  ProgramData trees, and the ancestor dirs traversed to reach them). Covered.
- **host-env** — clock / RNG / locale / timezone / fonts / DNS / run-noise
  (`/dev/urandom`, `/etc/localtime`, `/usr/share/fonts`, `Temp`, …), neutralized by
  the other Tier-1 seams (DESIGN §5.1). Expected.
- **unexpected** — everything else. This is the list to read: anything here is a
  state-, identity-, or determinism-bearing read that the state set does not cover,
  *or* benign noise (pre-login known-folder probes such as `Desktop`/`Downloads`,
  bare drive-root traversal) — confirm each.

The report prints per-bucket counts and the full "unexpected" list. On the current
pre-login client the useful catch is that the client probes a **compiled-in
OpenSSL config/CA path from its build machine** (`C:\kakao\work\vcpkg\…\openssl.cnf`,
`cert.pem`) that does not exist in the prefix — exactly the kind of determinism-
relevant read worth knowing about, surfaced rather than hidden.

#### Methods and the anti-tamper caveat

| `--mode` | How | Anti-tamper risk |
|----------|-----|------------------|
| `winedebug` (default) | `WINEDEBUG=+file,+reg`; Wine logs resolved paths itself | **None** — no `ptrace`, nothing attaches to the protected process |
| `strace` | `strace -f` on file syscalls | **Attaches via `ptrace`** — the Themida-family protector may treat it as a debugger (see [`containment.md`](containment.md) "Anti-tamper"); treat any behavior change as itself a signal |
| `bpftrace` | eBPF on the `openat` tracepoint | None (ptrace-free), but needs a privileged / `CAP_BPF` container and `bpftrace` in the image |

`strace`/`bpftrace` are not installed in the image by default; those modes fail
with a clear message rather than silently. `winedebug` is the primary method
precisely because it is the lowest-risk against the protector.

**Safety (DESIGN §11).** The client is never logged in. The raw trace log is a
capture artifact: it is written to a temp dir and deleted unless `--keep`, and
must never be committed.

### Enforcing the state set (`prefix-guard.sh`)

`prefix-trace.sh` *observes*; `prefix-guard.sh` *enforces*. It turns "is the state
set complete?" into an invariant the box upholds at runtime: any file access
outside the declared set crashes the client. This is method (4) of
[`containment.md`](containment.md)'s "Validating the state set". Two out-of-process
layers (no `ptrace`, anti-tamper-safe), both needing a **privileged /
`CAP_SYS_ADMIN`** container:

1. **Structural read-only base.** The immutable install (`drive_c/windows`,
   `drive_c/Program Files`) is bind-remounted **read-only**, so a write outside the
   state set fails `EROFS` and an unprovisioned base read fails `ENOENT`. The prefix
   is first bind-mounted to itself, which also bounds the guard's scope to the
   prefix subtree.
2. **Active `fanotify` guard** (`prefix-guard.py`). Intercepts every open in the
   writable region via `FAN_OPEN_PERM`, classifies it against the state set, and on
   any off-list access **`SIGKILL`s the whole client process tree** — a hard crash —
   or logs it under `--log-only`.

```sh
# must be root; e.g.
docker run --rm --privileged -u 0 <image> prefix-guard.sh              # kill mode (default)
docker run --rm --privileged -u 0 <image> prefix-guard.sh --log-only   # observe, don't kill
docker run --rm --privileged -u 0 <image> prefix-guard.sh --allow-extra 'drive_c/foo/*'
#   --seconds N     launch-hold window      --no-readonly   skip the ro base layer
```

Like `prefix-trace.sh` it reuses `prefix-state.sh`'s `STATE_GLOBS` as the single
source of truth (the wrapper `source`s it and passes the globs to the guard). The
base and known-benign allow rules are the guard's own policy: the benign seed is
exactly the pre-login residue `prefix-trace.sh` surfaces (`Desktop`/`Downloads`
known-folder probes, the compiled-in OpenSSL build path), so the **unmodified**
client runs clean under the default kill mode and only a *genuinely new* access
crashes it.

**Converge first.** A too-tight allowlist crashes the client on a legitimate read.
The workflow is: run `prefix-trace.sh`, fold any benign "unexpected" into the
allowlist (`--allow-extra`, or the seed in `prefix-guard.py`), *then* enable kill
mode. The guard exits non-zero (3) on a violation, so CI can gate on it.

**Caveat.** `fanotify` and the read-only bind-remounts need `CAP_SYS_ADMIN`; the
guard refuses to run unless it is root and prints how to launch the container. This
is the same privilege class as the `bpftrace` trace mode — the trade for a
kernel-level, anti-tamper-safe enforcement point.

### Future: a layered prefix

`prefix-guard.sh` already enforces a read-only base in place, and the state-only
tool makes the snapshot loop cheap, but the prefix is still one directory. The
structural step splits it into separately-mounted layers, following the
Matrix–WeChat `wechat-box` precedent (immutable Wine base image + mounted-in
payloads):

- **Immutable lower layer** — Wine + installed client, baked into the image,
  mounted **read-only**. A read-only base is also what makes "did the client try to
  write/read outside its state?" observable (an `EACCES`/`EROFS` is a signal).
- **Writable upper layer** — the state set, on a real volume or `tmpfs` (not on the
  container's own overlay — overlay-on-overlay fails; keep frequently-written state
  on a volume). Snapshot/restore then touches only this small layer.
- **A dedicated payload dir** (e.g. `drive_c/injector/`, as `injector-box` uses) for
  a future grey-box tap DLL, so a version-matched tap drops in and is swapped with
  zero prefix churn.

**Built** as `prefix-layer.sh`; see "Layered prefix" above.

## Scope and safety

`verify-launch.sh` stops at "the process launches and stays up." It does **not**
attempt login — that needs a disposable, owned test account and is done manually
(DESIGN §11). No credentials, captures, or device identifiers belong in the image
or the repo.

## Next increment: the injection spike

Once the launch spike passes, [`inject-spike.md`](inject-spike.md) ("Spike A") is
the next step: `make inject-spike` proves an injected DLL (`loadprobe.dll`) loads
into the boxed client under Wine and the client stays up. It is still account-free
and is the gate for both driving ([`driving.md`](driving.md)) and the read taps
([`instrumentation.md`](instrumentation.md)).
