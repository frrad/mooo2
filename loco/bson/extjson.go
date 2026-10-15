package bson

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
)

// ToExtJSON renders d as compact canonical Extended JSON. Every value keeps
// its BSON type: int32 is {"$numberInt":"…"}, int64 is {"$numberLong":"…"},
// and so on. Element order is kept, so FromExtJSON(ToExtJSON(d)) gives back
// a document that marshals to the same bytes.
func ToExtJSON(d D) ([]byte, error) {
	var b bytes.Buffer
	if err := writeDoc(&b, d); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func writeDoc(b *bytes.Buffer, d D) error {
	b.WriteByte('{')
	for i, e := range d {
		if i > 0 {
			b.WriteByte(',')
		}
		if strings.HasPrefix(e.Key, "$") {
			// Would be read back as a type wrapper.
			return fmt.Errorf("key %q: keys starting with $ are not supported", e.Key)
		}
		writeString(b, e.Key)
		b.WriteByte(':')
		if err := writeValue(b, e.Value); err != nil {
			return fmt.Errorf("%s: %w", e.Key, err)
		}
	}
	b.WriteByte('}')
	return nil
}

func writeString(b *bytes.Buffer, s string) {
	enc := json.NewEncoder(b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s) // a string always encodes
	b.Truncate(b.Len() - 1)
}

func wrap(b *bytes.Buffer, key, val string) {
	b.WriteString(`{"` + key + `":`)
	writeString(b, val)
	b.WriteByte('}')
}

func writeValue(b *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case float64:
		wrap(b, "$numberDouble", formatDouble(x))
	case string:
		writeString(b, x)
	case D:
		return writeDoc(b, x)
	case A:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeValue(b, e); err != nil {
				return fmt.Errorf("[%d]: %w", i, err)
			}
		}
		b.WriteByte(']')
	case Binary:
		b.WriteString(`{"$binary":{"base64":`)
		writeString(b, base64.StdEncoding.EncodeToString(x.Data))
		b.WriteString(`,"subType":`)
		writeString(b, hex.EncodeToString([]byte{x.Subtype}))
		b.WriteString(`}}`)
	case bool:
		b.WriteString(strconv.FormatBool(x))
	case DateTime:
		b.WriteString(`{"$date":`)
		wrap(b, "$numberLong", strconv.FormatInt(int64(x), 10))
		b.WriteByte('}')
	case nil:
		b.WriteString("null")
	case int32:
		wrap(b, "$numberInt", strconv.FormatInt(int64(x), 10))
	case int64:
		wrap(b, "$numberLong", strconv.FormatInt(int64(x), 10))
	default:
		return fmt.Errorf("unsupported value type %T", v)
	}
	return nil
}

// formatDouble gives a decimal string that round-trips through
// strconv.ParseFloat, with the spec's names for the non-finite values.
func formatDouble(f float64) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	}
	s := strconv.FormatFloat(f, 'G', -1, 64)
	if !strings.ContainsAny(s, ".E") {
		s += ".0"
	}
	return s
}

func parseDouble(s string) (float64, error) {
	switch s {
	case "NaN":
		return math.NaN(), nil
	case "Infinity":
		return math.Inf(1), nil
	case "-Infinity":
		return math.Inf(-1), nil
	}
	return strconv.ParseFloat(s, 64)
}

// FromExtJSON parses canonical Extended JSON into a document. Plain JSON
// numbers are rejected: canonical form always names the BSON number type,
// and guessing it would break byte-exact re-encoding.
func FromExtJSON(b []byte) (D, error) {
	v, err := readJSONValue(json.RawMessage(b))
	if err != nil {
		return nil, err
	}
	d, ok := v.(D)
	if !ok {
		return nil, errors.New("top level is not a document")
	}
	return d, nil
}

type member struct {
	key string
	raw json.RawMessage
}

// members splits a JSON object into its members, in order. ok is false if
// raw is not an object.
func members(raw json.RawMessage) (ms []member, ok bool, err error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	tok, err := dec.Token()
	if err != nil {
		return nil, false, err
	}
	if tok != json.Delim('{') {
		return nil, false, nil
	}
	for dec.More() {
		k, err := dec.Token()
		if err != nil {
			return nil, true, err
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, true, err
		}
		ms = append(ms, member{k.(string), v})
	}
	if _, err := dec.Token(); err != nil {
		return nil, true, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, true, errors.New("trailing data after JSON value")
	}
	return ms, true, nil
}

func readJSONValue(raw json.RawMessage) (any, error) {
	ms, isObj, err := members(raw)
	if err != nil {
		return nil, err
	}
	if isObj {
		if len(ms) > 0 && strings.HasPrefix(ms[0].key, "$") {
			return readWrapper(ms)
		}
		d := D{}
		for _, m := range ms {
			if strings.HasPrefix(m.key, "$") {
				return nil, fmt.Errorf("key %q: keys starting with $ are not supported", m.key)
			}
			v, err := readJSONValue(m.raw)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", m.key, err)
			}
			d = append(d, E{m.key, v})
		}
		return d, nil
	}

	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim: // '['
		var elems []json.RawMessage
		if err := json.Unmarshal(raw, &elems); err != nil {
			return nil, err
		}
		a := A{}
		for i, e := range elems {
			v, err := readJSONValue(e)
			if err != nil {
				return nil, fmt.Errorf("[%d]: %w", i, err)
			}
			a = append(a, v)
		}
		return a, nil
	case string:
		return t, nil
	case bool:
		return t, nil
	case nil:
		return nil, nil
	case json.Number:
		return nil, fmt.Errorf("bare number %s: use $numberInt, $numberLong or $numberDouble", t)
	}
	return nil, fmt.Errorf("unexpected token %v", tok)
}

// readWrapper decodes a one-member type wrapper such as {"$numberInt":"1"}.
func readWrapper(ms []member) (any, error) {
	if len(ms) != 1 {
		return nil, fmt.Errorf("type wrapper %s has %d members, want 1", ms[0].key, len(ms))
	}
	key, raw := ms[0].key, ms[0].raw
	str := func() (string, error) {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return "", fmt.Errorf("%s: want a string", key)
		}
		return s, nil
	}
	switch key {
	case "$numberInt":
		s, err := str()
		if err != nil {
			return nil, err
		}
		n, err := strconv.ParseInt(s, 10, 32)
		return int32(n), err
	case "$numberLong":
		s, err := str()
		if err != nil {
			return nil, err
		}
		return strconv.ParseInt(s, 10, 64)
	case "$numberDouble":
		s, err := str()
		if err != nil {
			return nil, err
		}
		return parseDouble(s)
	case "$date":
		inner, _, err := members(raw)
		if err != nil || len(inner) != 1 || inner[0].key != "$numberLong" {
			return nil, errors.New(`$date: want {"$numberLong": "<ms>"}`)
		}
		v, err := readWrapper(inner)
		if err != nil {
			return nil, err
		}
		return DateTime(v.(int64)), nil
	case "$binary":
		inner, _, err := members(raw)
		if err != nil {
			return nil, fmt.Errorf("$binary: %w", err)
		}
		var b64, sub string
		var haveB64, haveSub bool
		for _, m := range inner {
			var s string
			if err := json.Unmarshal(m.raw, &s); err != nil {
				return nil, fmt.Errorf("$binary.%s: want a string", m.key)
			}
			switch m.key {
			case "base64":
				b64, haveB64 = s, true
			case "subType":
				sub, haveSub = s, true
			default:
				return nil, fmt.Errorf("$binary: unknown member %q", m.key)
			}
		}
		if !haveB64 || !haveSub || len(inner) != 2 {
			return nil, errors.New("$binary: want base64 and subType")
		}
		data, err := base64.StdEncoding.Strict().DecodeString(b64)
		if err != nil {
			return nil, fmt.Errorf("$binary.base64: %w", err)
		}
		st, err := hex.DecodeString(sub)
		if err != nil || len(st) != 1 {
			return nil, errors.New("$binary.subType: want two hex digits")
		}
		return Binary{Subtype: st[0], Data: data}, nil
	}
	return nil, fmt.Errorf("unsupported type wrapper %s", key)
}
