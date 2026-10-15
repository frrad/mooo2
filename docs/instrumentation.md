# Read instrumentation: the grey-box capture side

This is the scoping / scaffolding document for the **read** half of the oracle
harness: the taps that observe the boxed reference client and emit the contract's
`Output` bundle. It realizes [`../DESIGN.md`](../DESIGN.md) §5.2 (grey-box tap
points) and §6 (the contract), and it is the capture-side counterpart to the
**write** half — driving the client — scoped separately in
[`driving.md`](driving.md).

**Status:** scope only. No tap is built here, no hook code and no reversed
offsets are committed (DESIGN §11, §12). This document says *what* to capture,
*which representation*, *roughly where* in the client stack, and *in what order*
to build it — not *how to find* any seam in a specific binary.

Both halves ride the **same injection seam**: a hook loaded via
`WINEDLLOVERRIDES`, wired by [`../docker/entrypoint.sh`](../docker/entrypoint.sh)
through `KAKAO_HOOK_OVERRIDES`, and staged under [`../patches/`](../patches/).
Read taps and write commands are the two directions of one hook; this document
owns the read direction and defers the command RPC to [`driving.md`](driving.md).

---

## 1. What "read instrumentation" produces

The whole point of the harness is to diff two `Output`s for one `Input`
(DESIGN §6–§7). The reference does not produce an `Output` natively — it produces
GUI updates, encrypted sockets, and an encrypted local database. Read
instrumentation is what *synthesizes* an `Output` from the reference by observing
it from the inside.

Recall the contract's output type (DESIGN §6, illustrative):

```go
type Output struct {
    Outbound  []Packet   // decrypted packets the client would send
    Events    []Event    // events emitted toward the consumer/bridge
    Records   []Record   // decoded local-store writes
    Decisions []Decision // which requests fired and why (trigger context)
}
```

Every field above is the product of one or more taps. The read instrumentation's
job is to fill this struct for the reference side, per scenario step, so the
comparator has something interface-identical to the candidate's native `Output`
to diff against.

---

## 2. The governing rule (DESIGN §5)

> Wherever a black-box boundary would force you to diff an opaque, encrypted, or
> nondeterministic representation, hack a tap one layer **inward** to the
> plaintext / structured / deterministic representation.

Read instrumentation is this rule applied four times for observation, plus twice
for the nondeterministic inputs that must be *recorded* so the output is
diffable at all. A tap placed too far out (e.g. on the raw socket) captures
ciphertext you cannot align; a tap placed at the right seam captures the decoded
object a field-level diff can act on.

---

## 3. The four read taps (DESIGN §5.2)

Each tap is one internal seam. For each: the representation it must capture, the
`Output` field it fills, and — implementation-neutrally — the kind of boundary
it sits at. No binary-specific location is given or implied; finding the actual
seam in a given release is reviewed, uncommitted work (§5.3 below, DESIGN §12).

### 3.1 Crypto / transport tap → plaintext packets

- **Captures:** inbound packets *after* decryption and outbound packets *before*
  encryption — the LOCO plaintext, not the TLS/socket bytes.
- **Fills:** `Output.Outbound` (the before-encrypt direction). The after-decrypt
  direction is simultaneously the harness's record of inbound `Input.Inbound`,
  so this one seam feeds both the input fan-out and the output comparison.
- **Boundary:** the seam between the transport/crypto layer and the message
  layer — one layer inward from the socket. This is the first and canonical
  instance of the governing rule.
- **Also seizes key material:** at the same seam, the negotiated session key and
  per-packet IV are captured at generation (DESIGN §5.2(1)), so a capture can be
  decrypted *and* the same key material can be injected into the candidate for
  byte-identical ciphertext. Seizing is covered in §4.

### 3.2 Storage / DB tap → decoded records

- **Captures:** local-store writes as decoded rows/objects, tapped at the
  serialization layer — not the encrypted blob on disk.
- **Fills:** `Output.Records`.
- **Boundary:** the seam between the client's model and its persistence
  serializer — the filesystem analogue of network-after-decrypt.

### 3.3 Request / response model tap → structured objects

- **Captures:** the request/response structures the client builds (outbound) and
  parses (inbound), one layer above raw packets.
- **Fills:** `Output.Outbound` at structured granularity, and corroborates the
  parse side. Diffing structured objects localizes a divergence to a *field*
  rather than a byte offset (DESIGN §5.2(3)).
- **Boundary:** the model-construction / model-parse seam, just above the crypto
  tap. In practice the crypto tap and the model tap are complementary views of
  the same traffic at two altitudes; both are worth having because the lower one
  catches serialization bugs and the higher one makes diffs legible.

### 3.4 Decision / trigger tap → why a request fires

- **Captures:** the caller/trigger context for client-originated actions — not
  just *that* a request fired but *why* (e.g. "a push referenced an unknown
  member, so a member-list fetch fired").
- **Fills:** `Output.Decisions`.
- **Boundary:** the orchestration seam where the client decides to act. This is
  the one tap whose output is **review-gated** rather than machine-exact
  (DESIGN §7, §12): some decision divergence is legitimate implementation
  freedom.

`Output.Events` (events toward the consumer/bridge) are derived, not a fifth
tap — they fall out of the model and decision taps (DESIGN §5.2 closing note:
"outbound packets and emitted events … fall out of the crypto tap and the
model/decision taps").

---

## 4. Seizing clock and RNG (the inputs that make output diffable)

Two inputs are not observed but **seized** — recorded on the reference, injected
into the candidate (DESIGN §5.1 "Seized") — because without them crypto-bearing
output can never match:

- **RNG / entropy** — the CSPRNG and any hardware RNG, feeding IVs, ephemeral
  keys, nonces, GUIDs, and client-generated message/request IDs.
- **Clock** — wall clock, tick counts, high-resolution counters, feeding
  timestamps, timeouts, retry timing.

For read instrumentation these are *capture* hooks on the entropy/time sources:
record each draw, in order, onto the capture bus. (The *inject* side — replaying
the recorded stream into the candidate — belongs to the candidate and the replay
mode, DESIGN §8; it is out of scope here.) Seizing is listed with the taps
because it rides the same hook and writes the same bus.

---

## 5. The capture bus

The four taps plus the two seized streams all feed one **capture bus**: the
single ordered channel that aggregates every observation for a scenario run into
one `Output` bundle (DESIGN §5.2 "The capture bus collects all four taps plus the
seized clock/RNG. That bundle *is* the contract.").

### 5.1 Requirements

- **Single writer, ordered.** All taps write to one bus so cross-tap causal
  ordering is preserved (the comparator checks ordering up to documented causal
  constraints, DESIGN §7). Each record carries a monotonic sequence number from
  the seized clock tap, not wall-clock time.
- **Tagged by tap + altitude.** Each entry names its source tap (crypto / storage
  / model / decision / clock / rng) and the altitude (e.g. packet vs. structured
  object) so the comparator can apply the right equality policy per field class.
- **Out-of-process sink.** The bus crosses out of the boxed client to a harness
  collector, so a client crash does not lose the capture and the collector can be
  the Go-side comparator's input. The transport is the same local channel family
  the command RPC uses ([`driving.md`](driving.md)); read uses it as an
  append-only event stream, write uses it request/response. Keeping both on one
  channel keeps driven `Input.Commands` and captured `Output` on a single
  timeline.

### 5.2 Capture format (on-disk / over-the-wire)

A framed, append-only event log. Each frame is one tap observation:

```
seq        uint64     monotonic, from the seized clock tap
tap        enum       crypto | storage | model | decision | clock | rng
dir        enum       in | out | n/a      (inbound-decrypt vs outbound-pre-encrypt)
altitude   enum       packet | record | object | decision | entropy | time
payload    bytes      the decoded representation (structured encoding, e.g. a
                      length-prefixed structured blob — NOT raw ciphertext)
```

On disk this is one capture file per scenario run; the collector can project it
into the `Output` struct by grouping frames by `tap`/`dir`. The format is
deliberately dumb and append-only so a partial capture from a crashed run is
still parseable up to the last complete frame.

> **Safety boundary (DESIGN §11).** A real capture contains decrypted traffic,
> timestamps, IDs, and possibly device-bound material. Capture files are lab
> artifacts and are **never committed**: they live outside the repo like the
> installer (`vendor/`), and `.gitignore` must exclude any capture output
> directory before the first tap writes anything. This document and the repo
> carry the *format and the tooling*, never a capture.

---

## 6. First spike: one inbound-decrypt plaintext tap

Following DESIGN §13.1's spirit — the cheapest thing that resolves the biggest
unknown first — the first read spike is **a single crypto/transport tap on the
inbound-decrypt path** (§3.1, the canonical instance of the governing rule). Not
all four taps; not the bus; just: can we observe one plaintext inbound packet
from inside the boxed client at all?

This is the natural follow-on to the sibling driving spike (can an injected DLL
load and reach one internal *send* path, [`driving.md`](driving.md)); here the
question is whether that same loaded hook can observe one internal *decrypt*
result.

### 6.1 Preconditions

- The §13.1 unmodified-launch spike passes (the client runs under Wine).
- The driving-side injection spike has shown a `WINEDLLOVERRIDES` DLL *loads*
  into the client (§3.1 of [`driving.md`](driving.md)). The read spike reuses
  that loading result; it does not re-prove injection.
- A disposable, owned test account and a live or replayed inbound message, driven
  manually (DESIGN §11) — the spike needs one real inbound packet to decrypt.

### 6.2 PASS / FAIL (mirroring [`../docker/verify-launch.sh`](../docker/verify-launch.sh))

A `verify-tap.sh`-style check (not written here) would:

```
PASS  the hook, loaded via KAKAO_HOOK_OVERRIDES, emits exactly one capture-bus
      frame for one known inbound message, tap=crypto dir=in altitude=packet,
      whose payload decodes as structured plaintext (not ciphertext), within a
      bounded hold window — and the UNMODIFIED-launch behavior is unchanged when
      KAKAO_HOOK_OVERRIDES is empty.

FAIL  no frame emitted in the window; or the payload is opaque/ciphertext
      (tap placed too far out — move one layer inward per §2); or the client
      crashes / fails to launch with the hook loaded; or the empty-override path
      regresses the §13.1 spike.
```

The decisive signal, like `verify-launch.sh`'s "process is up," is binary: **one
structured-plaintext frame on the bus, or not.** Everything after — the other
three taps, the bus collector, the format projection — is only worth building
once this passes.

---

## 7. How this plugs into the existing seam (no §13.1 change)

The read instrumentation adds **nothing** to the default (unmodified) path. It
reuses exactly what [`../patches/README.md`](../patches/README.md) and
[`../docker/entrypoint.sh`](../docker/entrypoint.sh) already define:

- **Loading.** The tap hook is the same injected DLL the patches seam describes
  (mechanism 1): drop it into the prefix, set `KAKAO_HOOK_OVERRIDES`
  (e.g. `KAKAO_HOOK_OVERRIDES="kakaotap=n,b"`), and `entrypoint.sh` wires it into
  `WINEDLLOVERRIDES`. **With `KAKAO_HOOK_OVERRIDES` unset the client runs
  unmodified** — the §13.1 spike is untouched. This is already the entrypoint's
  documented behavior; read instrumentation does not change the entrypoint.
- **Staging.** The tap DLL (when it exists) stages under `patches/` as a reviewed
  artifact, same as the driving hook. In practice read taps and write commands
  may be one DLL with two directions; this document does not mandate a split.
- **Capture sink.** The only new runtime surface is the bus's out-of-process sink
  (§5.1): a local channel the harness collector reads. That is additive and
  inert when no hook is loaded.

### 7.1 Relationship to [`driving.md`](driving.md)

| | Driving (write) | Instrumentation (read) |
|---|---|---|
| Direction | harness → client | client → harness |
| Shape | command RPC (request/response) | event stream (append-only) |
| Fills | `Input.Commands` on the reference | `Output.*` from the reference |
| Shared | same hook seam, same local channel family, same `patches/` staging, same empty-override = unmodified rule |

They are two directions of one instrument. Keep the channel and the DLL staging
unified; keep the RPC design in `driving.md` and the tap/format design here.

---

## 8. Open questions / risks

- **Tap-offset stability (DESIGN §12).** The four seams move every release; the
  read taps need re-baselining on each official-client bump, same as the driving
  hook. No offset is committed (DESIGN §11).
- **Anti-tamper / integrity.** An injected observing DLL may trip integrity
  checks (DESIGN §12); unverified until the injection spike runs. Shared risk
  with driving.
- **Altitude duplication.** The crypto tap (§3.1) and model tap (§3.3) observe
  overlapping traffic at two altitudes. Confirm against the real decoded models
  (DESIGN §12 "contract boundary placement") that both are needed and that they
  factor cleanly, rather than collapsing to one.
- **Decision-tap semantics.** The decision tap (§3.4) is review-gated, not
  machine-exact; defining what trigger context is "enough" to diff is open and
  overlaps the comparator's equality policy (DESIGN §7).
- **Thread scheduling (DESIGN §5.1, §9).** Fine-grained interleaving across taps
  is accepted as equivalence, not a bug; the bus's monotonic `seq` records order
  but the comparator only enforces causal ordering.
