// Package comparator diffs two contract.Outputs under the equality policy
// of DESIGN.md §7 and §9. docs/contract.md records the policy; this package
// implements it.
//
// In short:
//
//   - Outbound packets, events and records are machine-exact. Any
//     difference is a bug unless a [Rule] covers it.
//   - Decisions are review-gated. A difference is flagged for review, not
//     failed.
//   - A Rule either whitelists a field the protocol leaves to client choice
//     ([Free]) or records a deliberate, documented deviation ([Deviation]).
//     Every rule carries its rationale.
//   - Ordering is causal, not interleaved. Items are grouped by their Cause.
//     Within one group and one stream, order must match. Across groups and
//     across streams, order is not compared.
package comparator

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/frrad/mooo2/contract"
)

// Stream names one Output slice.
type Stream string

// Streams.
const (
	Outbound  Stream = "outbound"
	Events    Stream = "events"
	Records   Stream = "records"
	Decisions Stream = "decisions"
)

// reviewGated reports whether s is compared for review rather than
// machine-exactly (DESIGN.md §7, §12).
func (s Stream) reviewGated() bool { return s == Decisions }

func (s Stream) valid() bool {
	switch s {
	case Outbound, Events, Records, Decisions:
		return true
	}
	return false
}

// Class is the verdict on one difference.
type Class string

// Classes.
const (
	// Bug: a machine-exact field differs and no rule covers it. By default
	// the candidate is wrong (DESIGN.md §3).
	Bug Class = "bug"
	// Review: a review-gated (decision-layer) field differs and no rule
	// covers it. A person classifies it as a bug or a deviation.
	Review Class = "review"
	// Deviation: a documented deliberate deviation covers the difference.
	Deviation Class = "deviation"
	// Free: the field is whitelisted as left to client choice.
	Free Class = "free"
)

// RuleKind says what a Rule does to the differences it covers.
type RuleKind string

// Rule kinds.
const (
	// KindFree whitelists a field the protocol leaves to client choice.
	KindFree RuleKind = "free"
	// KindDeviation records a deliberate candidate deviation that is still
	// correct for interop.
	KindDeviation RuleKind = "deviation"
)

// Rule covers a set of differences. All of Stream, Match and Field must
// match for the rule to apply.
type Rule struct {
	// ID names the rule in reports. Unique within a policy.
	ID   string   `json:"id"`
	Kind RuleKind `json:"kind"`
	// Stream is the Output slice the rule applies to.
	Stream Stream `json:"stream"`
	// Match, if set, limits the rule to items with this discriminator:
	// the packet method, event kind, record store, or decision request.
	Match string `json:"match,omitempty"`
	// Field is a dotted field path such as "body.ts". "*" matches any one
	// segment, and array indexes are ignored. A rule covers its field and
	// everything below it. The empty Field covers the whole item, including
	// an item that is missing on one side.
	Field string `json:"field,omitempty"`
	// Rationale says why the difference is acceptable. Required.
	Rationale string `json:"rationale"`
}

// Policy is the equality policy: strict by default, plus explicit rules.
// The zero Policy is fully strict.
type Policy struct {
	Rules []Rule `json:"rules"`
}

// Validate checks every rule is complete and IDs are unique.
func (p *Policy) Validate() error {
	ids := map[string]bool{}
	for i, r := range p.Rules {
		switch {
		case r.ID == "":
			return fmt.Errorf("rules[%d]: empty id", i)
		case ids[r.ID]:
			return fmt.Errorf("rules[%d]: duplicate id %q", i, r.ID)
		case r.Kind != KindFree && r.Kind != KindDeviation:
			return fmt.Errorf("rule %s: unknown kind %q", r.ID, r.Kind)
		case !r.Stream.valid():
			return fmt.Errorf("rule %s: unknown stream %q", r.ID, r.Stream)
		case strings.TrimSpace(r.Rationale) == "":
			return fmt.Errorf("rule %s: a rule needs a rationale", r.ID)
		}
		ids[r.ID] = true
	}
	return nil
}

// ReadPolicy decodes and validates a JSON policy.
func ReadPolicy(r io.Reader) (*Policy, error) {
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	var p Policy
	if err := dec.Decode(&p); err != nil {
		return nil, fmt.Errorf("policy: %w", err)
	}
	if err := p.Validate(); err != nil {
		return nil, fmt.Errorf("policy: %w", err)
	}
	return &p, nil
}

// Diff is one difference between the reference ("want") and candidate
// ("got") outputs.
type Diff struct {
	Stream Stream
	// Cause is the causal group the item belongs to.
	Cause contract.Ref
	// Index is the item's position within its causal group and stream.
	Index int
	// Match is the item's discriminator (method, kind, store, request).
	Match string
	// Field is the dotted path of the differing field, or "" when the
	// whole item is missing on one side.
	Field string
	// Want and Got are compact JSON, or "" when absent on that side. They
	// may hold scrubbed corpus values, so String omits them.
	Want, Got string
	Class     Class
	// Rule is the ID of the rule that classified the diff, if any.
	Rule string
}

// Where locates the diff, for example `outbound[cmd:c1][0].body.msg`.
// Spontaneous items (empty Cause) are shown as "-".
func (d Diff) Where() string {
	cause := string(d.Cause)
	if cause == "" {
		cause = "-"
	}
	s := fmt.Sprintf("%s[%s][%d]", d.Stream, cause, d.Index)
	if d.Field != "" {
		s += "." + d.Field
	}
	return s
}

// String gives the class and location, but no values: CI logs are public.
func (d Diff) String() string {
	s := fmt.Sprintf("%-9s %s", d.Class, d.Where())
	switch {
	case d.Field == "" && d.Got == "":
		s += " (missing in candidate)"
	case d.Field == "" && d.Want == "":
		s += " (extra in candidate)"
	}
	if d.Rule != "" {
		s += " [" + d.Rule + "]"
	}
	return s
}

// Report is the result of comparing one pair of Outputs.
type Report struct {
	Diffs []Diff
}

// Failed reports whether any diff is a bug.
func (r *Report) Failed() bool { return r.count(Bug) > 0 }

// NeedsReview reports whether any diff awaits review.
func (r *Report) NeedsReview() bool { return r.count(Review) > 0 }

func (r *Report) count(c Class) int {
	n := 0
	for _, d := range r.Diffs {
		if d.Class == c {
			n++
		}
	}
	return n
}

// Summary is one line: the verdict and the count per class.
func (r *Report) Summary() string {
	verdict := "PASS"
	switch {
	case r.Failed():
		verdict = "FAIL"
	case r.NeedsReview():
		verdict = "REVIEW"
	}
	return fmt.Sprintf("%s: %d bug, %d review, %d deviation, %d free",
		verdict, r.count(Bug), r.count(Review), r.count(Deviation), r.count(Free))
}

// item is one Output entry, flattened for comparison.
type item struct {
	cause contract.Ref
	match string
	tree  *node
}

// Compare diffs the candidate output got against the reference output want.
// It returns an error only if an item cannot be encoded; differences are in
// the Report.
func (p *Policy) Compare(want, got *contract.Output) (*Report, error) {
	r := &Report{}
	for _, s := range []Stream{Outbound, Events, Records, Decisions} {
		w, err := items(want, s)
		if err != nil {
			return nil, fmt.Errorf("reference %s: %w", s, err)
		}
		g, err := items(got, s)
		if err != nil {
			return nil, fmt.Errorf("candidate %s: %w", s, err)
		}
		p.compareStream(r, s, w, g)
	}
	return r, nil
}

func (p *Policy) compareStream(r *Report, s Stream, want, got []item) {
	wg, order := group(want, nil)
	gg, order := group(got, order)
	for _, cause := range order {
		w, g := wg[cause], gg[cause]
		for i := 0; i < len(w) || i < len(g); i++ {
			d := Diff{Stream: s, Cause: cause, Index: i}
			switch {
			case i >= len(g):
				d.Match, d.Want = w[i].match, w[i].tree.text()
				r.add(p.classify(d))
			case i >= len(w):
				d.Match, d.Got = g[i].match, g[i].tree.text()
				r.add(p.classify(d))
			default:
				d.Match = w[i].match
				diffTree("", w[i].tree, g[i].tree, func(field, want, got string) {
					d.Field, d.Want, d.Got = field, want, got
					r.add(p.classify(d))
				})
			}
		}
	}
}

func (r *Report) add(d Diff) { r.Diffs = append(r.Diffs, d) }

// group splits items by cause, keeping order within each group. order lists
// causes by first appearance, extended with any new causes.
func group(items []item, order []contract.Ref) (map[contract.Ref][]item, []contract.Ref) {
	seen := map[contract.Ref]bool{}
	for _, c := range order {
		seen[c] = true
	}
	g := map[contract.Ref][]item{}
	for _, it := range items {
		if !seen[it.cause] {
			seen[it.cause] = true
			order = append(order, it.cause)
		}
		g[it.cause] = append(g[it.cause], it)
	}
	return g, order
}

// classify applies the first matching rule, or the stream's default class.
func (p *Policy) classify(d Diff) Diff {
	for _, rule := range p.Rules {
		if rule.covers(d) {
			d.Rule = rule.ID
			if rule.Kind == KindFree {
				d.Class = Free
			} else {
				d.Class = Deviation
			}
			return d
		}
	}
	if d.Stream.reviewGated() {
		d.Class = Review
	} else {
		d.Class = Bug
	}
	return d
}

func (r *Rule) covers(d Diff) bool {
	if r.Stream != d.Stream || (r.Match != "" && r.Match != d.Match) {
		return false
	}
	if r.Field == "" {
		return true
	}
	if d.Field == "" {
		// A field rule never excuses a whole missing or extra item.
		return false
	}
	pat := strings.Split(r.Field, ".")
	path := strings.Split(stripIndexes(d.Field), ".")
	if len(pat) > len(path) {
		return false
	}
	for i, seg := range pat {
		if seg != "*" && seg != path[i] {
			return false
		}
	}
	return true
}

// stripIndexes removes array indexes: "a[0].b[12]" → "a.b".
func stripIndexes(field string) string {
	var b strings.Builder
	skip := false
	for _, c := range field {
		switch {
		case c == '[':
			skip = true
		case c == ']':
			skip = false
		case !skip:
			b.WriteRune(c)
		}
	}
	return b.String()
}

// items flattens one stream. The Cause is the grouping key, so it is
// removed from the compared tree.
func items(out *contract.Output, s Stream) ([]item, error) {
	var res []item
	add := func(v any, cause contract.Ref, match string) error {
		raw, err := json.Marshal(v)
		if err != nil {
			return err
		}
		t, err := parseTree(raw)
		if err != nil {
			return err
		}
		if t.kind != 'o' {
			return errors.New("item is not an object")
		}
		for i, k := range t.keys {
			if k == "cause" {
				t.keys = append(t.keys[:i:i], t.keys[i+1:]...)
				t.vals = append(t.vals[:i:i], t.vals[i+1:]...)
				break
			}
		}
		res = append(res, item{cause: cause, match: match, tree: t})
		return nil
	}
	var err error
	switch s {
	case Outbound:
		for _, x := range out.Outbound {
			if err = add(x, x.Cause, x.Method); err != nil {
				break
			}
		}
	case Events:
		for _, x := range out.Events {
			if err = add(x, x.Cause, x.Kind); err != nil {
				break
			}
		}
	case Records:
		for _, x := range out.Records {
			if err = add(x, x.Cause, x.Store); err != nil {
				break
			}
		}
	case Decisions:
		for _, x := range out.Decisions {
			if err = add(x, x.Cause, x.Request); err != nil {
				break
			}
		}
	}
	return res, err
}
