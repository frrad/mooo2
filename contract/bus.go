package contract

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Tap names the source of a capture-bus frame (docs/instrumentation.md §5.2).
type Tap string

// Taps: the four grey-box taps plus the two seized input streams.
const (
	TapCrypto   Tap = "crypto"
	TapStorage  Tap = "storage"
	TapModel    Tap = "model"
	TapDecision Tap = "decision"
	TapClock    Tap = "clock"
	TapRNG      Tap = "rng"
)

// Dir is a frame's direction. Only the crypto and model taps see both
// directions; every other tap uses DirNA.
type Dir string

// Directions.
const (
	DirIn  Dir = "in"  // inbound, after decrypt / parse
	DirOut Dir = "out" // outbound, before encrypt / after build
	DirNA  Dir = "n/a"
)

// Altitude is the representation a frame's payload carries.
type Altitude string

// Altitudes.
const (
	AltPacket   Altitude = "packet"
	AltRecord   Altitude = "record"
	AltObject   Altitude = "object"
	AltDecision Altitude = "decision"
	AltEntropy  Altitude = "entropy"
	AltTime     Altitude = "time"
)

// tapShape is the altitude each tap emits and whether it is directional.
var tapShape = map[Tap]struct {
	alt Altitude
	dir bool
}{
	TapCrypto:   {AltPacket, true},
	TapStorage:  {AltRecord, false},
	TapModel:    {AltObject, true},
	TapDecision: {AltDecision, false},
	TapClock:    {AltTime, false},
	TapRNG:      {AltEntropy, false},
}

// Frame is one capture-bus observation (docs/instrumentation.md §5.2).
// Payload holds the decoded representation as a JSON object, never raw
// ciphertext. Its shape depends on the tap; see [Project].
type Frame struct {
	// Seq is monotonic across the whole bus, from the seized clock tap.
	Seq      uint64          `json:"seq"`
	Tap      Tap             `json:"tap"`
	Dir      Dir             `json:"dir"`
	Altitude Altitude        `json:"altitude"`
	Payload  json.RawMessage `json:"payload"`
}

// Validate checks that the tap, direction, and altitude agree and that the
// payload is a JSON object.
func (f *Frame) Validate() error {
	shape, ok := tapShape[f.Tap]
	if !ok {
		return fmt.Errorf("frame %d: unknown tap %q", f.Seq, f.Tap)
	}
	if f.Altitude != shape.alt {
		return fmt.Errorf("frame %d: tap %s has altitude %q, want %q", f.Seq, f.Tap, f.Altitude, shape.alt)
	}
	switch {
	case shape.dir && f.Dir != DirIn && f.Dir != DirOut:
		return fmt.Errorf("frame %d: tap %s needs dir in or out, got %q", f.Seq, f.Tap, f.Dir)
	case !shape.dir && f.Dir != DirNA:
		return fmt.Errorf("frame %d: tap %s needs dir %q, got %q", f.Seq, f.Tap, DirNA, f.Dir)
	}
	if err := checkObject(f.Payload, false); err != nil {
		return fmt.Errorf("frame %d: payload: %w", f.Seq, err)
	}
	return nil
}

// FrameWriter appends frames to a capture log, one JSON object per line.
// The log is append-only, so a crashed run still leaves every complete
// frame readable.
type FrameWriter struct {
	w    io.Writer
	last uint64
	n    int
}

// NewFrameWriter returns a FrameWriter that writes to w.
func NewFrameWriter(w io.Writer) *FrameWriter { return &FrameWriter{w: w} }

// Write validates f and appends it. Seq must increase strictly.
func (fw *FrameWriter) Write(f Frame) error {
	if err := f.Validate(); err != nil {
		return err
	}
	if fw.n > 0 && f.Seq <= fw.last {
		return fmt.Errorf("frame %d: seq not after %d", f.Seq, fw.last)
	}
	line, err := json.Marshal(f)
	if err != nil {
		return err
	}
	// One write per frame, so a frame is never split across writes.
	if _, err := fw.w.Write(append(line, '\n')); err != nil {
		return err
	}
	fw.last, fw.n = f.Seq, fw.n+1
	return nil
}

// ErrTruncated reports that a capture log ends in a partial frame. The
// frames before it are still returned.
var ErrTruncated = errors.New("capture log ends in a partial frame")

// ReadFrames reads a capture log written by FrameWriter. If the final line
// has no newline and is not well-formed JSON, it returns every complete
// frame along with ErrTruncated. Any other malformed or invalid line,
// including an unterminated last line that is whole JSON but not a valid
// frame, is an error.
func ReadFrames(r io.Reader) ([]Frame, error) {
	br := bufio.NewReader(r)
	var frames []Frame
	for lineNo := 1; ; lineNo++ {
		line, err := br.ReadBytes('\n')
		if err != nil && err != io.EOF {
			return frames, err
		}
		complete := err == nil
		if len(bytes.TrimSpace(line)) > 0 {
			f, perr := parseFrame(line)
			if perr != nil {
				// An unterminated last line that is not even well-formed
				// JSON was cut off mid-write. One that is whole but invalid
				// is reported like any other bad line.
				if !complete && !json.Valid(line) {
					return frames, ErrTruncated
				}
				return frames, fmt.Errorf("line %d: %w", lineNo, perr)
			}
			if len(frames) > 0 && f.Seq <= frames[len(frames)-1].Seq {
				return frames, fmt.Errorf("line %d: seq %d not after %d", lineNo, f.Seq, frames[len(frames)-1].Seq)
			}
			frames = append(frames, f)
		}
		if !complete {
			return frames, nil
		}
	}
}

func parseFrame(line []byte) (Frame, error) {
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.DisallowUnknownFields()
	var f Frame
	if err := dec.Decode(&f); err != nil {
		return f, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return f, errors.New("trailing data after frame")
	}
	return f, f.Validate()
}

// Project groups a run's frames into the contract types, in bus order:
//
//   - crypto/in  → Input.Inbound   (payload: [Packet] without Cause)
//   - crypto/out → Output.Outbound (payload: [Packet])
//   - storage    → Output.Records  (payload: [Record])
//   - decision   → Output.Decisions (payload: [Decision])
//   - clock      → Input.Clock     (payload: [ClockRead])
//   - rng        → Input.Entropy   (payload: [EntropyDraw])
//
// Model-tap frames are returned unprojected. Provisional: how structured
// objects map onto Outbound and Events is open until the crypto and model
// taps can be compared on real traffic (docs/instrumentation.md §8,
// "altitude duplication").
//
// Commands come from the command RPC, not the bus, so the caller passes the
// commands driven during the run. They become Input.Commands, and output
// causes of the form cmd:<id> resolve against them.
func Project(commands []Command, frames []Frame) (in Input, out Output, unprojected []Frame, err error) {
	in.Commands = commands
	for _, f := range frames {
		if err = f.Validate(); err != nil {
			return
		}
		var dst any
		switch f.Tap {
		case TapCrypto:
			in.Inbound, out.Outbound, err = projectPacket(f, in.Inbound, out.Outbound)
		case TapStorage:
			out.Records = append(out.Records, Record{})
			dst = &out.Records[len(out.Records)-1]
		case TapDecision:
			out.Decisions = append(out.Decisions, Decision{})
			dst = &out.Decisions[len(out.Decisions)-1]
		case TapClock:
			in.Clock = append(in.Clock, ClockRead{})
			dst = &in.Clock[len(in.Clock)-1]
		case TapRNG:
			in.Entropy = append(in.Entropy, EntropyDraw{})
			dst = &in.Entropy[len(in.Entropy)-1]
		case TapModel:
			unprojected = append(unprojected, f)
		}
		if err == nil && dst != nil {
			err = decodeStrict(f.Payload, dst)
		}
		if err != nil {
			err = fmt.Errorf("frame %d: %w", f.Seq, err)
			return
		}
	}
	if err = in.Validate(); err == nil {
		err = out.Validate(&in)
	}
	return
}

func projectPacket(f Frame, inbound, outbound []Packet) ([]Packet, []Packet, error) {
	var p Packet
	if err := decodeStrict(f.Payload, &p); err != nil {
		return inbound, outbound, err
	}
	if f.Dir == DirIn {
		return append(inbound, p), outbound, nil
	}
	return inbound, append(outbound, p), nil
}

func decodeStrict(raw json.RawMessage, dst any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}
