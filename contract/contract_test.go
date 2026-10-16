package contract

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
)

func readExample(t *testing.T) (*Bundle, []byte) {
	t.Helper()
	raw, err := os.ReadFile("testdata/example.bundle.json")
	if err != nil {
		t.Fatal(err)
	}
	b, err := ReadBundle(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("ReadBundle: %v", err)
	}
	return b, raw
}

func TestBundleRoundTrip(t *testing.T) {
	b, raw := readExample(t)
	got, err := MarshalBundle(b)
	if err != nil {
		t.Fatal(err)
	}
	// The checked-in file is in canonical form, so encoding must reproduce it
	// byte for byte.
	if !bytes.Equal(got, raw) {
		t.Errorf("re-encoded bundle differs from testdata:\n%s", got)
	}
	again, err := ReadBundle(bytes.NewReader(got))
	if err != nil {
		t.Fatal(err)
	}
	got2, _ := MarshalBundle(again)
	if !bytes.Equal(got, got2) {
		t.Error("encoding is not stable across a round trip")
	}
}

func TestBundleIsText(t *testing.T) {
	_, raw := readExample(t)
	if bytes.IndexByte(raw, 0) >= 0 {
		t.Fatal("bundle contains NUL bytes; corpus-lint would reject it")
	}
}

func TestReadBundleRejects(t *testing.T) {
	_, raw := readExample(t)
	s := string(raw)
	cases := map[string]string{
		"bad format":     strings.Replace(s, BundleFormat, "mooo2.contract/v9", 1),
		"unknown field":  strings.Replace(s, `"scenario"`, `"scenery": 1, "scenario"`, 1),
		"trailing data":  s + "{}",
		"bad action":     strings.Replace(s, `"action": "send"`, `"action": "launch"`, 1),
		"dangling cause": strings.Replace(s, `"cause": "in:0"`, `"cause": "in:1"`, 1),
		"bad cause":      strings.Replace(s, `"cause": "in:0"`, `"cause": "in:00"`, 1),
		"unknown cmd":    strings.Replace(s, `"cause": "cmd:c1"`, `"cause": "cmd:c2"`, 1),
		"long method":    strings.Replace(s, `"method": "WRITE"`, `"method": "WRITEWRITEWR"`, 1),
		"body not obj":   strings.Replace(s, `"body": {`, `"body": [{`, 1),
		"body plain num": strings.Replace(s, `"body": {`, `"body": {"n": 1, `, 1),
		"body bad type":  strings.Replace(s, `"body": {`, `"body": {"n": {"$numberInt": "x"}, `, 1),
		"bad clock":      strings.Replace(s, `"source": "mono"`, `"source": "tick"`, 1),
	}
	for name, in := range cases {
		if in == s {
			t.Fatalf("%s: replacement did not apply", name)
		}
		if _, err := ReadBundle(strings.NewReader(in)); err == nil {
			t.Errorf("%s: ReadBundle accepted a bad bundle", name)
		}
	}
}

func TestInputValidate(t *testing.T) {
	dup := Input{Commands: []Command{
		{ID: "a", Action: ActionOpen},
		{ID: "a", Action: ActionOpen},
	}}
	if err := dup.Validate(); err == nil {
		t.Error("duplicate command ids accepted")
	}
	caused := Input{Inbound: []Packet{{Method: "MSG", Body: json.RawMessage(`{}`), Cause: "cmd:a"}}}
	if err := caused.Validate(); err == nil {
		t.Error("inbound packet with a cause accepted")
	}
}

func TestRefs(t *testing.T) {
	if CommandRef("c1") != "cmd:c1" || InboundRef(3) != "in:3" {
		t.Fatal("ref constructors changed form")
	}
	in := Input{
		Commands: []Command{{ID: "c1", Action: ActionSend}},
		Inbound:  []Packet{{Method: "MSG", Body: json.RawMessage(`{}`)}},
	}
	for _, r := range []Ref{"", CommandRef("c1"), InboundRef(0)} {
		if err := in.resolve(r); err != nil {
			t.Errorf("resolve(%q): %v", r, err)
		}
	}
	for _, r := range []Ref{"c1", "cmd:", "in:-1", "in:1", "in:x", "out:0"} {
		if err := in.resolve(r); err == nil {
			t.Errorf("resolve(%q) succeeded", r)
		}
	}
}

func frame(seq uint64, tap Tap, dir Dir, alt Altitude, payload string) Frame {
	return Frame{Seq: seq, Tap: tap, Dir: dir, Altitude: alt, Payload: json.RawMessage(payload)}
}

func sampleFrames() []Frame {
	return []Frame{
		frame(1, TapClock, DirNA, AltTime, `{"source":"wall","value":5}`),
		frame(2, TapCrypto, DirIn, AltPacket, `{"packetId":9,"status":0,"method":"MSG","bodyType":0,"body":{"a":"b"}}`),
		frame(3, TapDecision, DirNA, AltDecision, `{"request":"GETMEM","trigger":"unknown-member","cause":"in:0"}`),
		frame(4, TapRNG, DirNA, AltEntropy, `{"source":"csprng","data":"AQID"}`),
		frame(5, TapCrypto, DirOut, AltPacket, `{"packetId":1,"status":0,"method":"GETMEM","bodyType":0,"body":{},"cause":"in:0"}`),
		frame(6, TapModel, DirOut, AltObject, `{"kind":"GetMemberRequest"}`),
		frame(7, TapStorage, DirNA, AltRecord, `{"store":"members","op":"update","key":"M_1","cause":"in:0"}`),
	}
}

func TestFrameLogRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	fw := NewFrameWriter(&buf)
	for _, f := range sampleFrames() {
		if err := fw.Write(f); err != nil {
			t.Fatal(err)
		}
	}
	if n := bytes.Count(buf.Bytes(), []byte("\n")); n != len(sampleFrames()) {
		t.Fatalf("got %d lines, want one per frame", n)
	}
	got, err := ReadFrames(bytes.NewReader(buf.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(sampleFrames()) {
		t.Fatalf("read %d frames, wrote %d", len(got), len(sampleFrames()))
	}
	for i, f := range got {
		if f.Seq != sampleFrames()[i].Seq || f.Tap != sampleFrames()[i].Tap {
			t.Errorf("frame %d: got %+v", i, f)
		}
	}
}

func TestReadFramesTruncated(t *testing.T) {
	var buf bytes.Buffer
	fw := NewFrameWriter(&buf)
	for _, f := range sampleFrames()[:3] {
		if err := fw.Write(f); err != nil {
			t.Fatal(err)
		}
	}
	whole := buf.Bytes()
	// Cut the last frame in half, as a crash mid-write would.
	cut := whole[:len(whole)-20]
	got, err := ReadFrames(bytes.NewReader(cut))
	if !errors.Is(err, ErrTruncated) {
		t.Fatalf("err = %v, want ErrTruncated", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d complete frames, want 2", len(got))
	}
	// A bad line in the middle is corruption, not truncation.
	mid := append(append([]byte{}, whole...), []byte("{oops}\n")...)
	mid = append(mid, whole...)
	if _, err := ReadFrames(bytes.NewReader(mid)); err == nil || errors.Is(err, ErrTruncated) {
		t.Fatalf("mid-log corruption: err = %v", err)
	}
	// A whole but invalid last line is a validation error, not truncation.
	bad := append(append([]byte{}, whole...), []byte(`{"seq":9,"tap":"net","dir":"in","altitude":"packet","payload":{}}`)...)
	if _, err := ReadFrames(bytes.NewReader(bad)); err == nil || errors.Is(err, ErrTruncated) {
		t.Fatalf("invalid unterminated last frame: err = %v", err)
	}
	// The last frame may lack its newline and still count.
	got, err = ReadFrames(bytes.NewReader(bytes.TrimSuffix(whole, []byte("\n"))))
	if err != nil || len(got) != 3 {
		t.Fatalf("unterminated final frame: %d frames, err %v", len(got), err)
	}
}

func TestFrameValidate(t *testing.T) {
	bad := []Frame{
		frame(1, "net", DirIn, AltPacket, `{}`),
		frame(1, TapCrypto, DirNA, AltPacket, `{}`),
		frame(1, TapCrypto, DirIn, AltRecord, `{}`),
		frame(1, TapStorage, DirOut, AltRecord, `{}`),
		frame(1, TapClock, DirNA, AltTime, `"raw"`),
		frame(1, TapClock, DirNA, AltTime, ``),
	}
	for _, f := range bad {
		if err := f.Validate(); err == nil {
			t.Errorf("accepted %+v", f)
		}
	}
	fw := NewFrameWriter(new(bytes.Buffer))
	ok := frame(2, TapClock, DirNA, AltTime, `{"source":"mono","value":1}`)
	if err := fw.Write(ok); err != nil {
		t.Fatal(err)
	}
	if err := fw.Write(ok); err == nil {
		t.Error("FrameWriter accepted a repeated seq")
	}
}

func TestProject(t *testing.T) {
	in, out, rest, err := Project(nil, sampleFrames())
	if err != nil {
		t.Fatal(err)
	}
	if len(in.Inbound) != 1 || in.Inbound[0].Method != "MSG" {
		t.Errorf("inbound = %+v", in.Inbound)
	}
	if len(in.Clock) != 1 || in.Clock[0].Value != 5 {
		t.Errorf("clock = %+v", in.Clock)
	}
	if len(in.Entropy) != 1 || !bytes.Equal(in.Entropy[0].Data, []byte{1, 2, 3}) {
		t.Errorf("entropy = %+v", in.Entropy)
	}
	if len(out.Outbound) != 1 || out.Outbound[0].Cause != InboundRef(0) {
		t.Errorf("outbound = %+v", out.Outbound)
	}
	if len(out.Decisions) != 1 || out.Decisions[0].Trigger != "unknown-member" {
		t.Errorf("decisions = %+v", out.Decisions)
	}
	if len(out.Records) != 1 || out.Records[0].Op != OpUpdate {
		t.Errorf("records = %+v", out.Records)
	}
	if len(rest) != 1 || rest[0].Tap != TapModel {
		t.Errorf("unprojected = %+v", rest)
	}

	// A payload field the contract does not know is an error, not dropped.
	bad := []Frame{frame(1, TapStorage, DirNA, AltRecord, `{"store":"s","op":"insert","key":"k","extra":1}`)}
	if _, _, _, err := Project(nil, bad); err == nil {
		t.Error("Project accepted an unknown payload field")
	}
	// A cause must resolve within the projected input.
	dangling := []Frame{frame(1, TapDecision, DirNA, AltDecision, `{"request":"X","trigger":"t","cause":"in:0"}`)}
	if _, _, _, err := Project(nil, dangling); err == nil {
		t.Error("Project accepted a dangling cause")
	}
}

// Regression: outputs caused by a driven command must resolve against the
// commands passed in, which never appear on the bus.
func TestProjectCommandCause(t *testing.T) {
	frames := []Frame{
		frame(1, TapCrypto, DirOut, AltPacket, `{"packetId":1,"status":0,"method":"WRITE","bodyType":0,"body":{},"cause":"cmd:c1"}`),
		frame(2, TapDecision, DirNA, AltDecision, `{"request":"WRITE","trigger":"command","cause":"cmd:c1"}`),
	}
	cmds := []Command{{ID: "c1", Action: ActionSend}}
	in, out, _, err := Project(cmds, frames)
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if len(in.Commands) != 1 || in.Commands[0].ID != "c1" {
		t.Errorf("commands = %+v", in.Commands)
	}
	if len(out.Outbound) != 1 || out.Outbound[0].Cause != CommandRef("c1") {
		t.Errorf("outbound = %+v", out.Outbound)
	}
	// Without the command, the cause is dangling.
	if _, _, _, err := Project(nil, frames); err == nil {
		t.Error("Project resolved cmd:c1 with no commands")
	}
}
