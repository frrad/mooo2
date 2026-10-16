package contract

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/frrad/mooo2/loco/bson"
)

// Input is everything a client consumes for one scenario step (DESIGN.md
// §6). Entropy and clock are inputs, not generated internally, so
// crypto-bearing output can match byte for byte across both clients.
type Input struct {
	// Commands are the high-level driven actions, in the order the harness
	// issues them (docs/driving.md §3).
	Commands []Command `json:"commands,omitempty"`
	// Inbound are decrypted server-originated packets, in arrival order.
	Inbound []Packet `json:"inbound,omitempty"`
	// Entropy is the seized RNG stream, in draw order.
	Entropy EntropyStream `json:"entropy,omitempty"`
	// Clock is the seized time stream, in read order.
	Clock ClockStream `json:"clock,omitempty"`
	// Snapshot names the baseline fs/DB/registry/device-identity state.
	Snapshot SnapshotRef `json:"snapshot"`
}

// Output is everything a client produces in response to an Input (DESIGN.md
// §6). Each slice is in the order the client produced it. The comparator
// only enforces order within one causal chain (DESIGN.md §9), so the order
// of items with different causes carries no meaning.
type Output struct {
	// Outbound are decrypted packets the client would send.
	Outbound []Packet `json:"outbound,omitempty"`
	// Events are emitted toward the consumer/bridge.
	Events []Event `json:"events,omitempty"`
	// Records are decoded local-store writes.
	Records []Record `json:"records,omitempty"`
	// Decisions say which requests fired and why. They are review-gated,
	// not machine-exact (DESIGN.md §7, §12).
	Decisions []Decision `json:"decisions,omitempty"`
}

// Action names a driven command. The set grows with the scenarios the
// harness drives; keep it tied to real scenario needs (docs/driving.md §6).
type Action string

// Actions from docs/driving.md §3.2.
const (
	ActionSend  Action = "send"  // send a message
	ActionOpen  Action = "open"  // open a chat
	ActionFetch Action = "fetch" // fetch a member list
)

func (a Action) valid() bool {
	switch a {
	case ActionSend, ActionOpen, ActionFetch:
		return true
	}
	return false
}

// Command is one driven action: one command-RPC request (docs/driving.md
// §3.2), and one Input.Commands entry.
type Command struct {
	// ID is the correlation id. Outputs the command causes name it in their
	// Cause (docs/driving.md §3.3).
	ID     string `json:"id"`
	Action Action `json:"action"`
	// Args is a JSON object of action arguments, such as {chat, body} for
	// send.
	//
	// Provisional: the argument shapes will follow the client's real models
	// once the driving hook reaches its internal entry points.
	Args json.RawMessage `json:"args,omitempty"`
}

// Packet is one decrypted LOCO packet: the plaintext seen by the crypto tap
// after inbound decrypt or before outbound encrypt (docs/instrumentation.md
// §3.1).
//
// The header fields follow the public descriptions of the LOCO header (see
// the sources in docs/native-ipc-findings.md).
//
// Provisional: not yet checked against frames from a real inbound-decrypt
// tap.
type Packet struct {
	// PacketID is the client- or server-assigned request id.
	PacketID uint32 `json:"packetId"`
	// Status is the header status code.
	Status int16 `json:"status"`
	// Method is the LOCO method name, at most 11 ASCII bytes.
	Method string `json:"method"`
	// BodyType is the header's body-type byte.
	BodyType uint8 `json:"bodyType"`
	// Body is the BSON body as canonical Extended JSON: a JSON object whose
	// key order and value types match the BSON document.
	Body json.RawMessage `json:"body"`
	// Cause is set on outbound packets only: the input that caused it.
	Cause Ref `json:"cause,omitempty"`
}

// MaxMethodLen is the width of the LOCO header's method field.
const MaxMethodLen = 11

// Event is one event emitted toward the consumer/bridge. Events are derived
// from the model and decision taps, not a separate tap
// (docs/instrumentation.md §3).
//
// Provisional: Kind values and Data shapes are not yet defined.
type Event struct {
	Kind  string          `json:"kind"`
	Cause Ref             `json:"cause,omitempty"`
	Data  json.RawMessage `json:"data,omitempty"`
}

// RecordOp is the kind of local-store write.
type RecordOp string

// Record operations.
const (
	OpInsert RecordOp = "insert"
	OpUpdate RecordOp = "update"
	OpDelete RecordOp = "delete"
)

func (o RecordOp) valid() bool {
	switch o {
	case OpInsert, OpUpdate, OpDelete:
		return true
	}
	return false
}

// Record is one decoded local-store write, from the storage tap
// (docs/instrumentation.md §3.2).
//
// Provisional: Store and Key naming will follow the client's real schema.
type Record struct {
	Store string          `json:"store"`
	Op    RecordOp        `json:"op"`
	Key   string          `json:"key"`
	Data  json.RawMessage `json:"data,omitempty"`
	Cause Ref             `json:"cause,omitempty"`
}

// Decision is the trigger context of one client-originated request, from
// the decision tap (docs/instrumentation.md §3.4). Decisions are
// review-gated: a diff here is flagged for review, not failed outright.
//
// Provisional: what trigger context is "enough" is an open question
// (docs/instrumentation.md §8).
type Decision struct {
	// Request is the LOCO method of the request that fired.
	Request string `json:"request"`
	// Trigger names why it fired, such as "unknown-member".
	Trigger string          `json:"trigger"`
	Cause   Ref             `json:"cause,omitempty"`
	Context json.RawMessage `json:"context,omitempty"`
}

// EntropyStream is the seized RNG stream, in draw order.
type EntropyStream []EntropyDraw

// EntropyDraw is one read from a seized entropy source.
//
// Provisional: source names will follow the hooked APIs.
type EntropyDraw struct {
	Source string `json:"source"`
	Data   []byte `json:"data"`
}

// ClockStream is the seized time stream, in read order.
type ClockStream []ClockRead

// ClockSource is the kind of clock read.
type ClockSource string

// Clock sources (DESIGN.md §5.1).
const (
	ClockWall ClockSource = "wall" // Value is Unix time in nanoseconds
	ClockMono ClockSource = "mono" // Value is a monotonic count in nanoseconds
)

func (c ClockSource) valid() bool { return c == ClockWall || c == ClockMono }

// ClockRead is one read from the seized clock.
//
// Provisional: tick counts and performance counters may need their own
// sources and units.
type ClockRead struct {
	Source ClockSource `json:"source"`
	Value  int64       `json:"value"`
}

// SnapshotRef names the baseline state restored before the step.
//
// Provisional: snapshot naming arrives with record mode (DESIGN.md §13).
type SnapshotRef struct {
	Name string `json:"name,omitempty"`
}

// Ref names the input item that caused an output item. The empty Ref means
// spontaneous: no input caused it (for example, a timer).
//
// The forms are "cmd:<Command.ID>" and "in:<index into Input.Inbound>".
type Ref string

// CommandRef refers to the command with the given id.
func CommandRef(id string) Ref { return Ref("cmd:" + id) }

// InboundRef refers to Input.Inbound[i].
func InboundRef(i int) Ref { return Ref("in:" + strconv.Itoa(i)) }

// Validate checks that in is well formed: command ids are unique and
// non-empty, enums hold known values, and JSON-valued fields hold objects.
func (in *Input) Validate() error {
	seen := map[string]bool{}
	for i, c := range in.Commands {
		if c.ID == "" {
			return fmt.Errorf("commands[%d]: empty id", i)
		}
		if strings.ContainsAny(c.ID, " \t\n") {
			return fmt.Errorf("commands[%d]: id %q contains whitespace", i, c.ID)
		}
		if seen[c.ID] {
			return fmt.Errorf("commands[%d]: duplicate id %q", i, c.ID)
		}
		seen[c.ID] = true
		if !c.Action.valid() {
			return fmt.Errorf("commands[%d]: unknown action %q", i, c.Action)
		}
		if err := checkObject(c.Args, true); err != nil {
			return fmt.Errorf("commands[%d].args: %w", i, err)
		}
	}
	for i, p := range in.Inbound {
		if err := p.validate(); err != nil {
			return fmt.Errorf("inbound[%d]: %w", i, err)
		}
		if p.Cause != "" {
			return fmt.Errorf("inbound[%d]: inbound packets have no cause", i)
		}
	}
	for i, e := range in.Entropy {
		if e.Source == "" {
			return fmt.Errorf("entropy[%d]: empty source", i)
		}
	}
	for i, c := range in.Clock {
		if !c.Source.valid() {
			return fmt.Errorf("clock[%d]: unknown source %q", i, c.Source)
		}
	}
	return nil
}

// Validate checks that out is well formed for in: every Cause resolves to an
// item of in, enums hold known values, and JSON-valued fields hold objects.
func (out *Output) Validate(in *Input) error {
	check := func(r Ref) error { return in.resolve(r) }
	for i, p := range out.Outbound {
		if err := p.validate(); err != nil {
			return fmt.Errorf("outbound[%d]: %w", i, err)
		}
		if err := check(p.Cause); err != nil {
			return fmt.Errorf("outbound[%d]: %w", i, err)
		}
	}
	for i, e := range out.Events {
		if e.Kind == "" {
			return fmt.Errorf("events[%d]: empty kind", i)
		}
		if err := checkObject(e.Data, true); err != nil {
			return fmt.Errorf("events[%d].data: %w", i, err)
		}
		if err := check(e.Cause); err != nil {
			return fmt.Errorf("events[%d]: %w", i, err)
		}
	}
	for i, r := range out.Records {
		if err := r.validate(); err != nil {
			return fmt.Errorf("records[%d]: %w", i, err)
		}
		if err := check(r.Cause); err != nil {
			return fmt.Errorf("records[%d]: %w", i, err)
		}
	}
	for i, d := range out.Decisions {
		if err := d.validate(); err != nil {
			return fmt.Errorf("decisions[%d]: %w", i, err)
		}
		if err := check(d.Cause); err != nil {
			return fmt.Errorf("decisions[%d]: %w", i, err)
		}
	}
	return nil
}

// resolve checks that r names an item of in.
func (in *Input) resolve(r Ref) error {
	if r == "" {
		return nil
	}
	kind, val, ok := strings.Cut(string(r), ":")
	if ok {
		switch kind {
		case "cmd":
			for _, c := range in.Commands {
				if c.ID == val {
					return nil
				}
			}
			return fmt.Errorf("cause %q: no such command", r)
		case "in":
			i, err := strconv.Atoi(val)
			if err == nil && i >= 0 && strconv.Itoa(i) == val {
				if i < len(in.Inbound) {
					return nil
				}
				return fmt.Errorf("cause %q: no such inbound packet", r)
			}
		}
	}
	return fmt.Errorf("cause %q: malformed reference", r)
}

func (p *Packet) validate() error {
	if p.Method == "" || len(p.Method) > MaxMethodLen {
		return fmt.Errorf("method %q: want 1 to %d bytes", p.Method, MaxMethodLen)
	}
	for i := 0; i < len(p.Method); i++ {
		if c := p.Method[i]; c <= ' ' || c > '~' {
			return fmt.Errorf("method %q: not printable ASCII", p.Method)
		}
	}
	if err := checkObject(p.Body, false); err != nil {
		return fmt.Errorf("body: %w", err)
	}
	// The body must be canonical Extended JSON that encodes to BSON, so
	// every valid packet can be framed for the wire.
	d, err := bson.FromExtJSON(p.Body)
	if err != nil {
		return fmt.Errorf("body: %w", err)
	}
	if _, err := bson.Marshal(d); err != nil {
		return fmt.Errorf("body: %w", err)
	}
	return nil
}

func (r *Record) validate() error {
	if r.Store == "" {
		return fmt.Errorf("empty store")
	}
	if !r.Op.valid() {
		return fmt.Errorf("unknown op %q", r.Op)
	}
	if err := checkObject(r.Data, true); err != nil {
		return fmt.Errorf("data: %w", err)
	}
	return nil
}

func (d *Decision) validate() error {
	if d.Request == "" {
		return fmt.Errorf("empty request")
	}
	if d.Trigger == "" {
		return fmt.Errorf("empty trigger")
	}
	if err := checkObject(d.Context, true); err != nil {
		return fmt.Errorf("context: %w", err)
	}
	return nil
}

// checkObject reports whether raw is a JSON object. An absent value passes
// only when optional is set.
func checkObject(raw json.RawMessage, optional bool) error {
	if len(raw) == 0 {
		if optional {
			return nil
		}
		return fmt.Errorf("missing")
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil || m == nil {
		return fmt.Errorf("not a JSON object")
	}
	return nil
}
