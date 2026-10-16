# mooo2

A design proposal for building and verifying a clean-room, self-hostable KakaoTalk
secondary-device client in Go by using the official client as a **grey-box
differential oracle**.

The short version: keep the official client on the bench as a reference, wrap it so
it and the Go client expose the **identical input/output contract**, run both on
the same input, and **flag every discrepancy** automatically. Hack a few grey-box
taps into the reference so comparisons are over plaintext and structured data —
not opaque ciphertext — and so nondeterministic inputs (clock, randomness) become
captured and replayable. The official client verifies the Go client; the Go client
is what ships.

## Documents

- [`DESIGN.md`](DESIGN.md) — the full design: contract, input surface, grey-box
  taps, comparator, operating modes, determinism limits, roadmap.
- [`docs/containment.md`](docs/containment.md) — how the boxed reference client
  can reach state, and where each channel is intercepted.
- [`docs/alternatives.md`](docs/alternatives.md) — approaches considered and why
  they were rejected.
- [`docs/driving.md`](docs/driving.md) — driving the reference client via an
  injected hook + command RPC (no UI scripting), and the injection spike.
- [`docs/instrumentation.md`](docs/instrumentation.md) — the read/capture side:
  the grey-box taps that synthesize the contract's `Output` from the reference,
  the capture bus, and the first inbound-decrypt tap spike.
- [`docs/boxing.md`](docs/boxing.md) — boxing the reference client under
  Wine/Docker: the build pipeline, launch, and prefix snapshot/restore.
- [`docs/native-ipc-findings.md`](docs/native-ipc-findings.md) — findings on the
  client's native IPC surface.
- [`docs/inject-spike.md`](docs/inject-spike.md) — Spike A: proving an injected
  DLL loads into the boxed client under Wine (the gate for driving and taps).
- [`docs/contract.md`](docs/contract.md) — the v0 `Input`/`Output` contract
  types, their text formats, and the comparator's equality policy.

## Status

Early implementation. There is no Go client yet, but the pieces the oracle
compares it against are in place:

- the Wine/Docker box and an unmodified-launch spike for the reference client,
  with a proxy-DLL fallback for the injection seam;
- Spike A: an injected DLL (via a proxied bundled import) loads into the boxed
  client — passing;
- prefix snapshot/restore for a repeatable starting state;
- **Contract v0** ([`contract/`](contract/), [`docs/contract.md`](docs/contract.md)):
  the `Input`/`Output` types, the scenario-bundle and capture-log text formats,
  and projection from capture-bus frames;
- **Comparator v0** ([`comparator/`](comparator/)): field-level diffs under the
  equality policy of [`docs/contract.md`](docs/contract.md) §2 — strict by
  default, review-gated decisions, documented free/deviation rules, causal
  ordering;
- **LOCO framing stub** ([`loco/`](loco/)): the packet header and a minimal
  BSON codec with canonical Extended JSON, from public sources only;
- **Tier 1 containment, complete** ([`docs/containment.md`](docs/containment.md)):
  default-deny network interpose with ingress fan-out, clock and RNG seize
  (libfaketime plus an entropy shim below Wine's `ntdll`), and a layered
  prefix (read-only base, state layer on tmpfs or a volume, payload dir), on
  top of the `WINEDEBUG` state-set trace and fanotify guard.

Next is the Wine login spike, which is manual and needs a disposable account.

This repository contains no credentials,
raw captures, device identifiers, proprietary binaries, or decompiled source.
Grey-box tap offsets and sanitized recordings are allowed. See the
scope-and-safety section of `DESIGN.md`.
