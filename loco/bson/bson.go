// Package bson is a minimal BSON codec for LOCO packet bodies, written from
// the public BSON 1.1 specification (https://bsonspec.org/spec.html), plus
// conversion to and from MongoDB canonical Extended JSON v2
// (https://github.com/mongodb/specifications, extended-json.md), which the
// contract uses to carry bodies as text.
//
// Only the element types listed on [D] are supported. Others are rejected
// rather than guessed at. Provisional: add types only when a real decoded
// body needs them.
package bson

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"unicode/utf8"
)

// D is an ordered BSON document. Order matters: it is part of the encoding.
//
// Supported value types and their BSON element types:
//
//	float64   0x01 double
//	string    0x02 string (must be valid UTF-8)
//	D         0x03 embedded document
//	A         0x04 array
//	Binary    0x05 binary
//	bool      0x08 boolean
//	DateTime  0x09 UTC datetime
//	nil       0x0A null
//	int32     0x10 int32
//	int64     0x12 int64
type D []E

// E is one document element.
type E struct {
	Key   string
	Value any
}

// A is a BSON array.
type A []any

// Binary is BSON binary data with its subtype.
type Binary struct {
	Subtype byte
	Data    []byte
}

// DateTime is a UTC datetime in milliseconds since the Unix epoch.
type DateTime int64

const (
	tDouble   = 0x01
	tString   = 0x02
	tDocument = 0x03
	tArray    = 0x04
	tBinary   = 0x05
	tBool     = 0x08
	tDateTime = 0x09
	tNull     = 0x0A
	tInt32    = 0x10
	tInt64    = 0x12
)

// minDocLen is the size of the empty document: int32 length + 0x00.
const minDocLen = 5

// Marshal encodes d as a BSON document.
func Marshal(d D) ([]byte, error) {
	return appendDoc(nil, d, nil)
}

// appendDoc appends a document. If arr is non-nil, it is an array and the
// element keys are "0", "1", ... (BSON spec, "Array").
func appendDoc(b []byte, d D, arr A) ([]byte, error) {
	start := len(b)
	b = append(b, 0, 0, 0, 0)
	var err error
	if arr != nil {
		for i, v := range arr {
			if b, err = appendElem(b, fmt.Sprint(i), v); err != nil {
				return nil, fmt.Errorf("[%d]: %w", i, err)
			}
		}
	} else {
		for _, e := range d {
			if b, err = appendElem(b, e.Key, e.Value); err != nil {
				return nil, fmt.Errorf("%s: %w", e.Key, err)
			}
		}
	}
	b = append(b, 0)
	n := len(b) - start
	if n > math.MaxInt32 {
		return nil, errors.New("document too large")
	}
	binary.LittleEndian.PutUint32(b[start:], uint32(n))
	return b, nil
}

func appendElem(b []byte, key string, v any) ([]byte, error) {
	if !utf8.ValidString(key) || bytes.IndexByte([]byte(key), 0) >= 0 {
		return nil, errors.New("key is not a valid cstring")
	}
	head := func(t byte) []byte {
		b = append(b, t)
		b = append(b, key...)
		return append(b, 0)
	}
	switch x := v.(type) {
	case float64:
		b = head(tDouble)
		return binary.LittleEndian.AppendUint64(b, math.Float64bits(x)), nil
	case string:
		if !utf8.ValidString(x) {
			return nil, errors.New("string is not valid UTF-8")
		}
		b = head(tString)
		b = binary.LittleEndian.AppendUint32(b, uint32(len(x)+1))
		b = append(b, x...)
		return append(b, 0), nil
	case D:
		return appendDoc(head(tDocument), x, nil)
	case A:
		if x == nil {
			x = A{}
		}
		return appendDoc(head(tArray), nil, x)
	case Binary:
		b = head(tBinary)
		b = binary.LittleEndian.AppendUint32(b, uint32(len(x.Data)))
		b = append(b, x.Subtype)
		return append(b, x.Data...), nil
	case bool:
		b = head(tBool)
		if x {
			return append(b, 1), nil
		}
		return append(b, 0), nil
	case DateTime:
		b = head(tDateTime)
		return binary.LittleEndian.AppendUint64(b, uint64(x)), nil
	case nil:
		return head(tNull), nil
	case int32:
		b = head(tInt32)
		return binary.LittleEndian.AppendUint32(b, uint32(x)), nil
	case int64:
		b = head(tInt64)
		return binary.LittleEndian.AppendUint64(b, uint64(x)), nil
	}
	return nil, fmt.Errorf("unsupported value type %T", v)
}

// Unmarshal decodes one BSON document that fills b exactly.
func Unmarshal(b []byte) (D, error) {
	d, _, n, err := readDoc(b, false)
	if err != nil {
		return nil, err
	}
	if n != len(b) {
		return nil, fmt.Errorf("%d trailing bytes after document", len(b)-n)
	}
	return d, nil
}

// readDoc reads a document from the front of b and returns its length. If
// array is set, keys must be "0", "1", ... and the result is an A.
func readDoc(b []byte, array bool) (D, A, int, error) {
	if len(b) < minDocLen {
		return nil, nil, 0, errors.New("short document")
	}
	n := int(int32(binary.LittleEndian.Uint32(b)))
	if n < minDocLen || n > len(b) {
		return nil, nil, 0, fmt.Errorf("document length %d out of range", n)
	}
	if b[n-1] != 0 {
		return nil, nil, 0, errors.New("document missing terminator")
	}
	body := b[4 : n-1]
	d := D{}
	arr := A{}
	for len(body) > 0 {
		t := body[0]
		key, rest, err := cstring(body[1:])
		if err != nil {
			return nil, nil, 0, err
		}
		v, used, err := readValue(t, rest)
		if err != nil {
			return nil, nil, 0, fmt.Errorf("%s: %w", key, err)
		}
		if array {
			if key != fmt.Sprint(len(arr)) {
				return nil, nil, 0, fmt.Errorf("array key %q out of sequence", key)
			}
			arr = append(arr, v)
		} else {
			d = append(d, E{key, v})
		}
		body = rest[used:]
	}
	return d, arr, n, nil
}

func cstring(b []byte) (string, []byte, error) {
	i := bytes.IndexByte(b, 0)
	if i < 0 {
		return "", nil, errors.New("unterminated cstring")
	}
	if !utf8.Valid(b[:i]) {
		return "", nil, errors.New("key is not valid UTF-8")
	}
	return string(b[:i]), b[i+1:], nil
}

func need(b []byte, n int) error {
	if len(b) < n {
		return errors.New("truncated element")
	}
	return nil
}

// readValue decodes one element value of type t from the front of b and
// returns the bytes it used.
func readValue(t byte, b []byte) (any, int, error) {
	switch t {
	case tDouble:
		if err := need(b, 8); err != nil {
			return nil, 0, err
		}
		return math.Float64frombits(binary.LittleEndian.Uint64(b)), 8, nil
	case tString:
		if err := need(b, 4); err != nil {
			return nil, 0, err
		}
		n := int(int32(binary.LittleEndian.Uint32(b)))
		if n < 1 || n > len(b)-4 {
			return nil, 0, fmt.Errorf("string length %d out of range", n)
		}
		s := b[4 : 4+n]
		if s[n-1] != 0 {
			return nil, 0, errors.New("string missing terminator")
		}
		if !utf8.Valid(s[:n-1]) {
			return nil, 0, errors.New("string is not valid UTF-8")
		}
		return string(s[:n-1]), 4 + n, nil
	case tDocument:
		d, _, n, err := readDoc(b, false)
		return d, n, err
	case tArray:
		_, a, n, err := readDoc(b, true)
		return a, n, err
	case tBinary:
		if err := need(b, 5); err != nil {
			return nil, 0, err
		}
		n := int(int32(binary.LittleEndian.Uint32(b)))
		if n < 0 || n > len(b)-5 {
			return nil, 0, fmt.Errorf("binary length %d out of range", n)
		}
		data := append([]byte{}, b[5:5+n]...)
		return Binary{Subtype: b[4], Data: data}, 5 + n, nil
	case tBool:
		if err := need(b, 1); err != nil {
			return nil, 0, err
		}
		switch b[0] {
		case 0:
			return false, 1, nil
		case 1:
			return true, 1, nil
		}
		return nil, 0, fmt.Errorf("boolean byte %#x", b[0])
	case tDateTime:
		if err := need(b, 8); err != nil {
			return nil, 0, err
		}
		return DateTime(binary.LittleEndian.Uint64(b)), 8, nil
	case tNull:
		return nil, 0, nil
	case tInt32:
		if err := need(b, 4); err != nil {
			return nil, 0, err
		}
		return int32(binary.LittleEndian.Uint32(b)), 4, nil
	case tInt64:
		if err := need(b, 8); err != nil {
			return nil, 0, err
		}
		return int64(binary.LittleEndian.Uint64(b)), 8, nil
	}
	return nil, 0, fmt.Errorf("unsupported element type %#x", t)
}
