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

## Status

Draft proposal. No implementation yet. This repository contains methodology only —
no credentials, captures, device identifiers, binary addresses, or decompiled
source. See the scope-and-safety section of `DESIGN.md`.
