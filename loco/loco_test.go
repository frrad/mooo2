package loco

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/frrad/mooo2/contract"
	"github.com/frrad/mooo2/loco/bson"
)

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(strings.Join(strings.Fields(s), ""))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Synthetic vectors. Method names are placeholders, not real LOCO methods.
var vectors = []struct {
	name string
	pkt  Packet
	hex  string
	json string // contract form
}{
	{
		name: "empty body",
		pkt:  Packet{PacketID: 1, Method: "TESTA", Body: bson.D{}},
		hex: "01000000 0000 5445535441 000000000000 00 05000000" +
			" 05000000 00",
		json: `{"packetId":1,"status":0,"method":"TESTA","bodyType":0,"body":{}}`,
	},
	{
		name: "full-width method, negative status",
		pkt: Packet{
			PacketID: 0x01020304,
			Status:   -1,
			Method:   "ABCDEFGHIJK",
			BodyType: 7,
			Body:     bson.D{{Key: "hello", Value: "world"}},
		},
		hex: "04030201 ffff 4142434445464748494a4b 07 16000000" +
			" 16000000 02 68656c6c6f00 06000000 776f726c6400 00",
		json: `{"packetId":16909060,"status":-1,"method":"ABCDEFGHIJK","bodyType":7,"body":{"hello":"world"}}`,
	},
	{
		name: "typed body",
		pkt: Packet{
			PacketID: 2,
			Method:   "TESTB",
			Body: bson.D{
				{Key: "n", Value: int32(5)},
				{Key: "l", Value: int64(5)},
			},
		},
		hex: "02000000 0000 5445535442 000000000000 00 17000000" +
			" 17000000 10 6e00 05000000 12 6c00 0500000000000000 00",
		json: `{"packetId":2,"status":0,"method":"TESTB","bodyType":0,"body":{"n":{"$numberInt":"5"},"l":{"$numberLong":"5"}}}`,
	},
}

func TestVectors(t *testing.T) {
	for _, v := range vectors {
		want := unhex(t, v.hex)
		got, err := v.pkt.Marshal()
		if err != nil {
			t.Fatalf("%s: Marshal: %v", v.name, err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s: Marshal\n got %x\nwant %x", v.name, got, want)
		}
		p, err := Unmarshal(want)
		if err != nil {
			t.Fatalf("%s: Unmarshal: %v", v.name, err)
		}
		if !reflect.DeepEqual(*p, v.pkt) {
			t.Errorf("%s: Unmarshal = %#v", v.name, p)
		}

		cp, err := p.ToContract()
		if err != nil {
			t.Fatalf("%s: ToContract: %v", v.name, err)
		}
		js, _ := json.Marshal(cp)
		if string(js) != v.json {
			t.Errorf("%s: contract form\n got %s\nwant %s", v.name, js, v.json)
		}
		back, err := FromContract(cp)
		if err != nil {
			t.Fatalf("%s: FromContract: %v", v.name, err)
		}
		if again, _ := back.Marshal(); !bytes.Equal(again, want) {
			t.Errorf("%s: wire → contract → wire changed the bytes", v.name)
		}
	}
}

func TestHeaderLen(t *testing.T) {
	b, err := AppendHeader(nil, Header{Method: "X"})
	if err != nil || len(b) != HeaderLen {
		t.Fatalf("header is %d bytes, err %v", len(b), err)
	}
}

func TestReader(t *testing.T) {
	var stream []byte
	for _, v := range vectors {
		stream = append(stream, unhex(t, v.hex)...)
	}
	r := NewReader(bytes.NewReader(stream))
	for _, v := range vectors {
		p, err := r.Next()
		if err != nil {
			t.Fatalf("%s: %v", v.name, err)
		}
		if p.Method != v.pkt.Method {
			t.Errorf("got %s, want %s", p.Method, v.pkt.Method)
		}
	}
	if _, err := r.Next(); err != io.EOF {
		t.Errorf("end of stream: %v, want io.EOF", err)
	}

	// Truncated inside the header and inside the body.
	for _, n := range []int{10, HeaderLen + 2} {
		_, err := NewReader(bytes.NewReader(stream[:n])).Next()
		if !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Errorf("cut at %d: %v, want io.ErrUnexpectedEOF", n, err)
		}
	}

	// A body length over the limit is rejected before allocating.
	big := unhex(t, "01000000 0000 5445535441 000000000000 00 ffffff7f")
	if _, err := NewReader(bytes.NewReader(big)).Next(); err == nil {
		t.Error("oversized body accepted")
	}
}

func TestRejects(t *testing.T) {
	bad := map[string]string{
		"short header":       "01000000 0000",
		"empty method":       "01000000 0000 0000000000000000000000 00 05000000 05000000 00",
		"junk after NUL":     "01000000 0000 5400410000000000000000 00 05000000 05000000 00",
		"non-ASCII method":   "01000000 0000 54c3a9000000000000000000 05000000 05000000 00",
		"length mismatch":    "01000000 0000 5445535441 000000000000 00 06000000 05000000 00",
		"body not BSON":      "01000000 0000 5445535441 000000000000 00 05000000 05000000 01",
		"trailing after pkt": "01000000 0000 5445535441 000000000000 00 05000000 05000000 00 00",
	}
	for name, h := range bad {
		if _, err := Unmarshal(unhex(t, h)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	for _, m := range []string{"", "TWELVECHARSX", "A B"} {
		p := Packet{Method: m, Body: bson.D{}}
		if _, err := p.Marshal(); err == nil {
			t.Errorf("Marshal accepted method %q", m)
		}
	}
	if _, err := FromContract(contract.Packet{Method: "X", Body: json.RawMessage(`{"a":1}`)}); err == nil {
		t.Error("FromContract accepted a bare JSON number")
	}
}

// Every packet in the contract's example bundle must survive
// contract → wire → contract unchanged.
func TestExampleBundle(t *testing.T) {
	f, err := os.Open("../contract/testdata/example.bundle.json")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	b, err := contract.ReadBundle(f)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range b.Steps {
		for _, cp := range append(append([]contract.Packet{}, s.Input.Inbound...), s.Output.Outbound...) {
			p, err := FromContract(cp)
			if err != nil {
				t.Fatalf("%s: %v", cp.Method, err)
			}
			wire, err := p.Marshal()
			if err != nil {
				t.Fatal(err)
			}
			q, err := Unmarshal(wire)
			if err != nil {
				t.Fatal(err)
			}
			back, err := q.ToContract()
			if err != nil {
				t.Fatal(err)
			}
			back.Cause = cp.Cause
			want, _ := json.Marshal(cp)
			got, _ := json.Marshal(back)
			if !bytes.Equal(got, want) {
				t.Errorf("round trip:\n got %s\nwant %s", got, want)
			}
		}
	}
}
