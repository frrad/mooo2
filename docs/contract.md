# The contract and the comparator's equality policy

This document records the v0 contract types and the equality policy the
comparator applies to them. It realizes [`../DESIGN.md`](../DESIGN.md) §6
(the contract), §7 (the comparator) and §9 (determinism limits). The code is
in [`../contract/`](../contract/) and [`../comparator/`](../comparator/).

**Status:** v0, provisional. No inbound-decrypt tap works yet, so none of the
types has been checked against the reference's real decoded models (DESIGN.md
§12). Types marked "Provisional" in their doc comments are shaped by the
design docs only and will change once the taps produce real frames.

---

## 1. The contract

The contract sits at the decrypted-packet + command/event boundary. One
scenario step is an `Input` and the `Output` a client produces for it.

| `Input` field | Source on the reference |
|---|---|
| `commands` | command RPC ([`driving.md`](driving.md) §3) |
| `inbound` | crypto tap, `dir=in` ([`instrumentation.md`](instrumentation.md) §3.1) |
| `entropy` | seized RNG (`tap=rng`) |
| `clock` | seized clock (`tap=clock`) |
| `snapshot` | baseline restored before the step |

| `Output` field | Source on the reference | Equality |
|---|---|---|
| `outbound` | crypto tap, `dir=out` | machine-exact |
| `events` | derived from the model and decision taps | machine-exact |
| `records` | storage tap | machine-exact |
| `decisions` | decision tap | review-gated |

Each output item carries a `cause`: `cmd:<command id>`, `in:<index into
inbound>`, or empty for spontaneous output such as a timer. This is the
correlation id of [`driving.md`](driving.md) §3.3, extended to inbound
packets.

Packet bodies are BSON on the wire. In the contract they are MongoDB
canonical Extended JSON, which keeps both the BSON value types (`int32` vs
`int64`) and the key order, so two bodies that are equal as Extended JSON
encode to the same BSON bytes.

### 1.1 Text formats

The corpus must be text (corpus-lint rejects binary files, DESIGN.md §10.1).

- **Scenario bundle:** one indented JSON document with
  `"format": "mooo2.contract/v0"`, a scenario name, and a list of steps.
  Encoding is deterministic, and reading is strict: unknown fields, trailing
  data, causes that do not resolve, and packet bodies that are not canonical
  Extended JSON encodable as BSON (checked with [`../loco/bson/`](../loco/bson/))
  are errors.
- **Capture log:** JSON Lines, one capture-bus frame per line
  (`seq`, `tap`, `dir`, `altitude`, `payload`). A partial last line from a
  crashed run (one that is not well-formed JSON) is reported as truncation,
  and every complete frame before it is kept. A last line that is whole JSON
  but not a valid frame is a validation error, newline or not.

## 2. Equality policy

The comparator diffs the reference output ("want") against the candidate
output ("got"). Every difference becomes one field-level diff with a class.

### 2.1 Strict by default

Outbound packets, events and records are **machine-exact**. Every field must
match, including:

- BSON value types: `{"$numberInt":"1"}` and `{"$numberLong":"1"}` differ.
- Object key order, because it changes the BSON bytes.
- Values derived from seized entropy or clock. Both sides consume the same
  seized streams, so those values are pinned and must match.

An unexplained difference in a machine-exact field is a **bug**. By default
the candidate is wrong (DESIGN.md §3).

### 2.2 Review-gated: the decision layer

Decisions (which request fired and why) are **review-gated** (DESIGN.md §7,
§12). Some divergence there is legitimate implementation freedom, so a
difference is flagged as **review**, not failed. A person then classifies it
as a bug (write a failing test, fix the candidate) or as a deviation (add a
rule, §2.3).

### 2.3 Rules: free fields and documented deviations

A policy is a list of rules. Each rule names a stream, an optional
discriminator (packet method, event kind, record store or decision request),
and an optional field path. It also has a required rationale.

- **`free`**: the protocol genuinely leaves the field to client choice. The
  diff is reported as `free` and does not fail.
- **`deviation`**: the candidate deliberately differs and is still correct
  for interop. The diff is reported as `deviation` and does not fail.

Field paths are dotted (`body.msg`). `*` matches any one segment, and array
indexes are ignored. A rule covers its field and everything below it. A rule
with no field covers the whole item, including an item that one side is
missing. A field rule never excuses a missing or extra item.

The v0 policy has no rules. Each rule added later must carry its rationale,
so the policy file doubles as the list of documented deviations.

### 2.4 Ordering: causal, not interleaved

Thread scheduling is the one input that cannot be pinned (DESIGN.md §5.1,
§9), so the comparator does not compare wall-clock interleaving. Instead:

- Each stream is grouped by `cause`.
- **Within one cause and one stream, order must match.** Items are compared
  position by position.
- **Across causes, order is not compared.** If command `a` and inbound packet
  `0` both produce outbound packets, the two chains may interleave
  differently.
- **Across streams, order is not compared.** For example, the relative order
  of a record write and an outbound packet is not checked.
- Attributing an item to a different cause counts as a missing item in one
  group plus an extra item in another.

Capture-bus `seq` numbers record the reference's actual order, but they are
not part of the compared data.

Provisional: causes point only at inputs. Finer causal edges, such as "this
outbound request was caused by that decision", are left for when the
decision tap shows what trigger context is available.

### 2.5 Reports

A report's verdict is **FAIL** if any diff is a bug, otherwise **REVIEW** if
any diff awaits review, otherwise **PASS**. Diffs print as a class and a
location such as `bug outbound[cmd:a][0].body.msg`. Values are kept on the
diff for local debugging but are never printed, because CI logs are public.
