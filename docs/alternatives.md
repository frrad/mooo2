# Alternatives considered

Context for [`../DESIGN.md`](../DESIGN.md): the approaches evaluated before
settling on "official client as a grey-box oracle, Go client as the shipping
implementation."

## A. Lift the macOS binary to run cross-platform

Run the official macOS client on Linux (e.g. via a Darwin compatibility layer) and
hook it.

- **Rejected.** A macOS compatibility layer cannot run a modern AppKit/Swift GUI
  app with the Keychain, code-signing, sandbox, and device-bound crypto the client
  depends on. Even where local computation runs, Keychain identity and server
  acceptance do not hold. The compatibility gap is exactly the hardest part and is
  not closing.

## B. Host the official client as the production runtime

Keep a boxed official client running per account forever and bridge through it.

- **Rejected as the runtime.** Gives protocol parity for free but yields a bridge
  that is not meaningfully self-hostable (a GUI client per account), is a black box
  at its core (crashes/stalls/reconnects happen in code you cannot fix), rides a
  forced-update treadmill, and discards a working Go client. Adopted instead *only*
  as a bench oracle (see `DESIGN.md`).

## C. Reimplement the protocol from public prior art first

Start from third-party reimplementations of the protocol.

- **Rejected as a starting point.** Prior art is used only *after* independently
  deriving findings from the authorized official clients, to confirm, challenge, or
  contextualize — never as the basis for the implementation.

## D. Full clean-room rewrite, verified entirely by hand

The conventional path: reverse method-by-method, spec, implement, hand-author
fixtures.

- **Kept, but accelerated.** This remains the shipping implementation. The oracle
  harness in `DESIGN.md` exists to remove the hand-verification bottleneck: live
  differential testing tells you where the Go client diverges, so deep manual
  tracing is reserved for flagged divergences instead of applied to every feature.

## Precedent

The "boxed Windows client under Wine + injected hook, fronted by a bridge" pattern
is used in production by the Matrix–WeChat bridges:

- `duo/matrix-wechat` — the Go/mautrix bridge side.
- `ChisBread/wechat-box` — the containerized Windows client + hook box.

These are architectural references for the boxing approach, not dependencies.
