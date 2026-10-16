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

Early implementation; the Go client does not exist yet. Merged so far:

- the Wine/Docker box and an unmodified-launch spike for the reference client;
- Spike A: an injected DLL (via a proxied bundled import) loads into the boxed
  client — passing;
- prefix snapshot/restore for a repeatable starting state;
- Tier-1 containment: a `WINEDEBUG` trace of the client's state set, enforced by a
  read-only base prefix plus a fanotify guard.

This repository contains no credentials,
raw captures, device identifiers, proprietary binaries, or decompiled source.
Grey-box tap offsets and sanitized recordings are allowed. See the
scope-and-safety section of `DESIGN.md`.
