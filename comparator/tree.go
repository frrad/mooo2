package comparator

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// node is a parsed JSON value that keeps object key order. BSON documents
// are ordered and their byte form depends on that order, so the comparator
// cannot use map[string]any.
type node struct {
	kind  byte // 'o' object, 'a' array, 'v' leaf
	keys  []string
	vals  []*node
	elems []*node
	leaf  string // compact JSON text of a leaf
}

// parseTree parses one JSON value. An object whose keys all start with "$"
// is an Extended JSON type wrapper such as {"$numberLong":"5"}, and becomes
// a leaf, so a type change is reported as one value change.
func parseTree(raw []byte) (*node, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	n, err := parseValue(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("trailing data after JSON value")
	}
	return n, nil
}

func parseValue(dec *json.Decoder) (*node, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			n := &node{kind: 'o'}
			for dec.More() {
				k, err := dec.Token()
				if err != nil {
					return nil, err
				}
				v, err := parseValue(dec)
				if err != nil {
					return nil, err
				}
				n.keys = append(n.keys, k.(string))
				n.vals = append(n.vals, v)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			if isWrapper(n) {
				return &node{kind: 'v', leaf: n.text()}, nil
			}
			return n, nil
		case '[':
			n := &node{kind: 'a'}
			for dec.More() {
				v, err := parseValue(dec)
				if err != nil {
					return nil, err
				}
				n.elems = append(n.elems, v)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return n, nil
		}
		return nil, fmt.Errorf("unexpected %v", t)
	default:
		b, err := json.Marshal(t)
		if err != nil {
			return nil, err
		}
		return &node{kind: 'v', leaf: string(b)}, nil
	}
}

func isWrapper(n *node) bool {
	if len(n.keys) == 0 {
		return false
	}
	for _, k := range n.keys {
		if !strings.HasPrefix(k, "$") {
			return false
		}
	}
	return true
}

// text is n's compact JSON form.
func (n *node) text() string {
	switch n.kind {
	case 'o':
		var b strings.Builder
		b.WriteByte('{')
		for i, k := range n.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(strconv.Quote(k))
			b.WriteByte(':')
			b.WriteString(n.vals[i].text())
		}
		b.WriteByte('}')
		return b.String()
	case 'a':
		var b strings.Builder
		b.WriteByte('[')
		for i, e := range n.elems {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(e.text())
		}
		b.WriteByte(']')
		return b.String()
	}
	return n.leaf
}

func (n *node) get(key string) (*node, bool) {
	for i, k := range n.keys {
		if k == key {
			return n.vals[i], true
		}
	}
	return nil, false
}

// diffTree reports every field where a and b differ. path is the field path
// of a and b; emit receives (path, want, got), with "" for an absent side.
func diffTree(path string, a, b *node, emit func(path, want, got string)) {
	if a.kind != b.kind || (a.kind == 'v' && a.leaf != b.leaf) {
		emit(path, a.text(), b.text())
		return
	}
	switch a.kind {
	case 'o':
		for i, k := range a.keys {
			if bv, ok := b.get(k); ok {
				diffTree(join(path, k), a.vals[i], bv, emit)
			} else {
				emit(join(path, k), a.vals[i].text(), "")
			}
		}
		common := 0
		for i, k := range b.keys {
			if _, ok := a.get(k); !ok {
				emit(join(path, k), "", b.vals[i].text())
			} else {
				common++
			}
		}
		// Same keys, different order: the BSON bytes differ.
		if common == len(a.keys) && common == len(b.keys) && !equalStrings(a.keys, b.keys) {
			emit(path, "key order "+strings.Join(a.keys, ","), "key order "+strings.Join(b.keys, ","))
		}
	case 'a':
		for i := 0; i < len(a.elems) || i < len(b.elems); i++ {
			p := path + "[" + strconv.Itoa(i) + "]"
			switch {
			case i >= len(b.elems):
				emit(p, a.elems[i].text(), "")
			case i >= len(a.elems):
				emit(p, "", b.elems[i].text())
			default:
				diffTree(p, a.elems[i], b.elems[i], emit)
			}
		}
	}
}

func join(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
