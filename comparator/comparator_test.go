package comparator

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/frrad/mooo2/contract"
)

func pkt(method, body string, cause contract.Ref) contract.Packet {
	return contract.Packet{PacketID: 1, Method: method, Body: json.RawMessage(body), Cause: cause}
}

func base() *contract.Output {
	return &contract.Output{
		Outbound: []contract.Packet{
			pkt("WRITE", `{"chatId":"C1","msg":"hi","n":{"$numberInt":"1"}}`, "cmd:a"),
			pkt("WRITE", `{"chatId":"C1","msg":"again"}`, "cmd:a"),
			pkt("GETMEM", `{"chatId":"C1"}`, "in:0"),
		},
		Events:    []contract.Event{{Kind: "message", Cause: "in:0"}},
		Records:   []contract.Record{{Store: "logs", Op: contract.OpInsert, Key: "L1", Cause: "cmd:a"}},
		Decisions: []contract.Decision{{Request: "GETMEM", Trigger: "unknown-member", Cause: "in:0"}},
	}
}

func compare(t *testing.T, p *Policy, want, got *contract.Output) *Report {
	t.Helper()
	r, err := p.Compare(want, got)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func where(r *Report) []string {
	var s []string
	for _, d := range r.Diffs {
		s = append(s, string(d.Class)+" "+d.Where())
	}
	return s
}

func expect(t *testing.T, r *Report, want ...string) {
	t.Helper()
	got := where(r)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("diffs:\n  %s\nwant:\n  %s", strings.Join(got, "\n  "), strings.Join(want, "\n  "))
	}
}

func TestEqual(t *testing.T) {
	r := compare(t, &Policy{}, base(), base())
	expect(t, r)
	if r.Failed() || r.NeedsReview() || !strings.HasPrefix(r.Summary(), "PASS") {
		t.Errorf("identical outputs: %s", r.Summary())
	}
}

func TestMachineExactField(t *testing.T) {
	got := base()
	got.Outbound[0].Body = json.RawMessage(`{"chatId":"C1","msg":"HI","n":{"$numberInt":"1"}}`)
	got.Outbound[2].Status = -1
	r := compare(t, &Policy{}, base(), got)
	expect(t, r,
		"bug outbound[cmd:a][0].body.msg",
		"bug outbound[in:0][0].status",
	)
	if !r.Failed() || !strings.HasPrefix(r.Summary(), "FAIL") {
		t.Error("a machine-exact diff must fail")
	}
}

func TestBSONTypeAndKeyOrder(t *testing.T) {
	got := base()
	// int32 → int64 is a different BSON value even if the number is equal.
	got.Outbound[0].Body = json.RawMessage(`{"chatId":"C1","msg":"hi","n":{"$numberLong":"1"}}`)
	// Same keys, different order: different BSON bytes.
	got.Outbound[1].Body = json.RawMessage(`{"msg":"again","chatId":"C1"}`)
	r := compare(t, &Policy{}, base(), got)
	expect(t, r,
		"bug outbound[cmd:a][0].body.n",
		"bug outbound[cmd:a][1].body",
	)
}

func TestMissingAndExtraKeys(t *testing.T) {
	got := base()
	got.Outbound[2].Body = json.RawMessage(`{"chatId":"C1","x":[1,2]}`)
	want := base()
	want.Outbound[2].Body = json.RawMessage(`{"chatId":"C1","y":true,"x":[1]}`)
	r := compare(t, &Policy{}, want, got)
	expect(t, r,
		"bug outbound[in:0][0].body.y",
		"bug outbound[in:0][0].body.x[1]",
	)
	if d := r.Diffs[0]; d.Want != "true" || d.Got != "" {
		t.Errorf("missing key: want %q got %q", d.Want, d.Got)
	}
}

func TestDecisionIsReviewGated(t *testing.T) {
	got := base()
	got.Decisions[0].Trigger = "periodic-refresh"
	r := compare(t, &Policy{}, base(), got)
	expect(t, r, "review decisions[in:0][0].trigger")
	if r.Failed() || !r.NeedsReview() || !strings.HasPrefix(r.Summary(), "REVIEW") {
		t.Errorf("decision diff: %s", r.Summary())
	}
}

func TestCausalOrdering(t *testing.T) {
	// Interleaving across causes and across streams is not compared: move the
	// in:0 packet ahead of the cmd:a packets.
	got := base()
	got.Outbound = []contract.Packet{got.Outbound[2], got.Outbound[0], got.Outbound[1]}
	expect(t, compare(t, &Policy{}, base(), got))

	// Order within one causal chain is compared.
	got = base()
	got.Outbound[0], got.Outbound[1] = got.Outbound[1], got.Outbound[0]
	r := compare(t, &Policy{}, base(), got)
	if !r.Failed() {
		t.Error("reordering within one cause must fail")
	}

	// Attributing an item to a different cause is a missing + extra item.
	got = base()
	got.Events[0].Cause = "cmd:a"
	expect(t, compare(t, &Policy{}, base(), got),
		"bug events[in:0][0]",
		"bug events[cmd:a][0]",
	)
}

func withIDs(out *contract.Output, ids ...uint32) *contract.Output {
	for i, id := range ids {
		out.Outbound[i].PacketID = id
	}
	return out
}

func TestPacketIDRenaming(t *testing.T) {
	// The in:0 chain ran first in the candidate, so its request took the
	// first id. The numbering is consistent, so nothing differs.
	want := withIDs(base(), 1, 2, 3)
	got := base()
	got.Outbound = []contract.Packet{got.Outbound[2], got.Outbound[0], got.Outbound[1]}
	withIDs(got, 1, 2, 3)
	expect(t, compare(t, &Policy{}, want, got))

	// Two reference requests share one candidate id.
	got = withIDs(base(), 5, 5, 6)
	r := compare(t, &Policy{}, want, got)
	expect(t, r, "bug outbound[cmd:a][1].packetId")
	if d := r.Diffs[0]; d.Want != "2" || d.Got != "5" {
		t.Errorf("packetId diff: want %q got %q", d.Want, d.Got)
	}

	// One reference id (a reused id) maps to two candidate ids.
	want = withIDs(base(), 1, 1, 2)
	got = withIDs(base(), 7, 8, 9)
	expect(t, compare(t, &Policy{}, want, got), "bug outbound[cmd:a][1].packetId")

	// A rule can still cover packetId.
	p := &Policy{Rules: []Rule{{ID: "ids", Kind: KindFree, Stream: Outbound, Field: "packetId", Rationale: "synthetic"}}}
	expect(t, compare(t, p, want, got), "free outbound[cmd:a][1].packetId")

	// A missing packet still shows its id.
	got = withIDs(base(), 1, 1, 2)
	got.Outbound = got.Outbound[:2]
	r = compare(t, &Policy{}, want, got)
	expect(t, r, "bug outbound[in:0][0]")
	if !strings.Contains(r.Diffs[0].Want, `"packetId":2`) {
		t.Errorf("missing item text: %s", r.Diffs[0].Want)
	}
}

func TestRuleMatchesCandidateSide(t *testing.T) {
	got := base()
	got.Outbound[2].Method = "GETMEMBER"
	p := &Policy{Rules: []Rule{{ID: "rename", Kind: KindDeviation, Stream: Outbound, Match: "GETMEMBER", Field: "method", Rationale: "synthetic"}}}
	r := compare(t, p, base(), got)
	expect(t, r, "deviation outbound[in:0][0].method")
	if d := r.Diffs[0]; d.Match != "GETMEM" || d.GotMatch != "GETMEMBER" {
		t.Errorf("Match %q GotMatch %q", d.Match, d.GotMatch)
	}
}

func TestWrapperSubfieldOrder(t *testing.T) {
	want := base()
	want.Outbound[2].Body = json.RawMessage(`{"b":{"$binary":{"base64":"3q0=","subType":"00"}}}`)
	got := base()
	got.Outbound[2].Body = json.RawMessage(`{"b":{"$binary":{"subType":"00","base64":"3q0="}}}`)
	expect(t, compare(t, &Policy{}, want, got))

	// A different value is still one diff on the whole wrapper.
	got.Outbound[2].Body = json.RawMessage(`{"b":{"$binary":{"subType":"80","base64":"3q0="}}}`)
	expect(t, compare(t, &Policy{}, want, got), "bug outbound[in:0][0].body.b")
}

func TestMissingAndExtraItems(t *testing.T) {
	got := base()
	got.Records = nil
	got.Outbound = append(got.Outbound, pkt("PING", `{}`, ""))
	r := compare(t, &Policy{}, base(), got)
	expect(t, r,
		"bug outbound[-][0]",
		"bug records[cmd:a][0]",
	)
	if s := r.Diffs[0].String(); !strings.Contains(s, "extra in candidate") {
		t.Errorf("extra item: %s", s)
	}
	if s := r.Diffs[1].String(); !strings.Contains(s, "missing in candidate") {
		t.Errorf("missing item: %s", s)
	}
}

func TestRules(t *testing.T) {
	p := &Policy{Rules: []Rule{
		{ID: "free-n", Kind: KindFree, Stream: Outbound, Match: "WRITE", Field: "body.n", Rationale: "synthetic: client's choice"},
		{ID: "dev-ping", Kind: KindDeviation, Stream: Outbound, Match: "PING", Rationale: "synthetic: candidate pings eagerly"},
		{ID: "free-data", Kind: KindFree, Stream: Events, Field: "data.*", Rationale: "synthetic"},
	}}
	if err := p.Validate(); err != nil {
		t.Fatal(err)
	}
	got := base()
	got.Outbound[0].Body = json.RawMessage(`{"chatId":"C1","msg":"hi","n":{"$numberInt":"2"}}`)
	got.Outbound[2].Body = json.RawMessage(`{"chatId":"C1","n":{"$numberInt":"2"}}`) // GETMEM: rule does not match
	got.Outbound = append(got.Outbound, pkt("PING", `{}`, ""))
	got.Events[0].Data = json.RawMessage(`{"a":{"b":1}}`)
	r := compare(t, p, base(), got)
	expect(t, r,
		"free outbound[cmd:a][0].body.n",
		"bug outbound[in:0][0].body.n",
		"deviation outbound[-][0]",
		"bug events[in:0][0].data",
	)
	if r.Diffs[0].Rule != "free-n" || r.Diffs[2].Rule != "dev-ping" {
		t.Errorf("rule ids: %+v", r.Diffs)
	}

	// "data.*" covers fields under data, not data itself appearing.
	want := base()
	want.Events[0].Data = json.RawMessage(`{"a":1}`)
	expect(t, compare(t, p, want, got),
		"free outbound[cmd:a][0].body.n",
		"bug outbound[in:0][0].body.n",
		"deviation outbound[-][0]",
		"free events[in:0][0].data.a",
	)
}

func TestRuleFieldMatching(t *testing.T) {
	r := Rule{Stream: Outbound, Field: "body.items.*.ts"}
	cases := map[string]bool{
		"body.items[3].x.ts":    true,
		"body.items[3].x.ts.$n": true,
		"body.items[3].x":       false,
		"body.items.x.id":       false,
		"":                      false,
	}
	for f, want := range cases {
		if got := r.covers(Diff{Stream: Outbound, Field: f}); got != want {
			t.Errorf("covers(%q) = %v", f, got)
		}
	}
	if r.covers(Diff{Stream: Events, Field: "body.items.x.ts"}) {
		t.Error("rule matched the wrong stream")
	}
}

func TestPolicyValidation(t *testing.T) {
	bad := []string{
		`{"rules":[{"id":"a","kind":"free","stream":"outbound"}]}`,
		`{"rules":[{"id":"a","kind":"ignore","stream":"outbound","rationale":"x"}]}`,
		`{"rules":[{"id":"a","kind":"free","stream":"inbound","rationale":"x"}]}`,
		`{"rules":[{"kind":"free","stream":"outbound","rationale":"x"}]}`,
		`{"rules":[{"id":"a","kind":"free","stream":"events","rationale":"x"},{"id":"a","kind":"free","stream":"events","rationale":"y"}]}`,
		`{"rules":[],"extra":1}`,
	}
	for _, s := range bad {
		if _, err := ReadPolicy(strings.NewReader(s)); err == nil {
			t.Errorf("accepted %s", s)
		}
	}
	p, err := ReadPolicy(strings.NewReader(`{"rules":[{"id":"a","kind":"deviation","stream":"records","match":"logs","field":"data","rationale":"x"}]}`))
	if err != nil || len(p.Rules) != 1 {
		t.Fatalf("valid policy: %v", err)
	}
}

func TestStringHidesValues(t *testing.T) {
	got := base()
	got.Outbound[0].Body = json.RawMessage(`{"chatId":"C1","msg":"SECRET","n":{"$numberInt":"1"}}`)
	r := compare(t, &Policy{}, base(), got)
	for _, d := range r.Diffs {
		if strings.Contains(d.String(), "SECRET") || strings.Contains(d.String(), "hi") {
			t.Errorf("String leaks a value: %s", d)
		}
	}
	if r.Diffs[0].Got != `"SECRET"` {
		t.Errorf("Got = %q", r.Diffs[0].Got)
	}
}
