package bson

import (
	"bytes"
	"encoding/hex"
	"math"
	"reflect"
	"strings"
	"testing"
)

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(strings.Join(strings.Fields(s), ""))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Vectors: the two examples from the bsonspec.org FAQ, plus synthetic ones
// covering every supported type.
var vectors = []struct {
	name string
	doc  D
	hex  string
	ext  string
}{
	{
		name: "spec hello world",
		doc:  D{{"hello", "world"}},
		hex:  "16000000 02 68656c6c6f00 06000000 776f726c6400 00",
		ext:  `{"hello":"world"}`,
	},
	{
		name: "spec BSON array",
		doc:  D{{"BSON", A{"awesome", 5.05, int32(1986)}}},
		hex: "31000000 04 42534f4e00 26000000" +
			" 02 3000 08000000 617765736f6d6500" +
			" 01 3100 3333333333331440" +
			" 10 3200 c2070000" +
			" 00 00",
		ext: `{"BSON":["awesome",{"$numberDouble":"5.05"},{"$numberInt":"1986"}]}`,
	},
	{
		name: "empty",
		doc:  D{},
		hex:  "05000000 00",
		ext:  `{}`,
	},
	{
		name: "scalar types",
		doc: D{
			{"t", true},
			{"f", false},
			{"n", nil},
			{"i", int32(-2)},
			{"l", int64(1) << 40},
			{"d", DateTime(1000)},
			{"x", 1.0},
			{"b", Binary{Subtype: 0, Data: []byte{0xde, 0xad}}},
		},
		hex: "42000000" +
			" 08 7400 01" +
			" 08 6600 00" +
			" 0a 6e00" +
			" 10 6900 feffffff" +
			" 12 6c00 0000000000010000" +
			" 09 6400 e803000000000000" +
			" 01 7800 000000000000f03f" +
			" 05 6200 02000000 00 dead" +
			" 00",
		ext: `{"t":true,"f":false,"n":null,"i":{"$numberInt":"-2"},` +
			`"l":{"$numberLong":"1099511627776"},"d":{"$date":{"$numberLong":"1000"}},` +
			`"x":{"$numberDouble":"1.0"},"b":{"$binary":{"base64":"3q0=","subType":"00"}}}`,
	},
	{
		name: "nested",
		doc:  D{{"m", D{{"z", "<&>"}, {"a", A{}}}}},
		hex: "20000000 03 6d00 18000000" +
			" 02 7a00 04000000 3c263e00" +
			" 04 6100 05000000 00" +
			" 00 00",
		ext: `{"m":{"z":"<&>","a":[]}}`,
	},
}

func TestVectors(t *testing.T) {
	for _, v := range vectors {
		want := unhex(t, v.hex)
		got, err := Marshal(v.doc)
		if err != nil {
			t.Fatalf("%s: Marshal: %v", v.name, err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s: Marshal\n got %x\nwant %x", v.name, got, want)
		}
		d, err := Unmarshal(want)
		if err != nil {
			t.Fatalf("%s: Unmarshal: %v", v.name, err)
		}
		if !reflect.DeepEqual(d, v.doc) {
			t.Errorf("%s: Unmarshal = %#v", v.name, d)
		}
		ext, err := ToExtJSON(d)
		if err != nil {
			t.Fatalf("%s: ToExtJSON: %v", v.name, err)
		}
		if string(ext) != v.ext {
			t.Errorf("%s: ToExtJSON\n got %s\nwant %s", v.name, ext, v.ext)
		}
		back, err := FromExtJSON(ext)
		if err != nil {
			t.Fatalf("%s: FromExtJSON: %v", v.name, err)
		}
		again, _ := Marshal(back)
		if !bytes.Equal(again, want) {
			t.Errorf("%s: BSON → ExtJSON → BSON changed the bytes", v.name)
		}
	}
}

func TestDoubles(t *testing.T) {
	for _, f := range []float64{0, math.Copysign(0, -1), 1, -1.5, 1e300, 5e-324, math.Inf(1), math.Inf(-1)} {
		ext, err := ToExtJSON(D{{"f", f}})
		if err != nil {
			t.Fatal(err)
		}
		d, err := FromExtJSON(ext)
		if err != nil {
			t.Fatalf("%s: %v", ext, err)
		}
		g := d[0].Value.(float64)
		if math.Float64bits(g) != math.Float64bits(f) {
			t.Errorf("%v → %s → %v", f, ext, g)
		}
	}
	d, err := FromExtJSON([]byte(`{"f":{"$numberDouble":"NaN"}}`))
	if err != nil || !math.IsNaN(d[0].Value.(float64)) {
		t.Errorf("NaN: %v %v", d, err)
	}
}

func TestUnmarshalRejects(t *testing.T) {
	bad := map[string]string{
		"short":            "0400 0000",
		"length too large": "06000000 00",
		"no terminator":    "05000000 01",
		"trailing bytes":   "05000000 00 00",
		"unknown type":     "08000000 07 6100 00",
		"string no NUL":    "0e000000 02 6100 02000000 6162 00",
		"string len 0":     "0c000000 02 6100 00000000 00",
		"bad bool":         "09000000 08 6100 02 00",
		"truncated int64":  "0c000000 12 6100 01000000 00",
		"array keys":       "14000000 04 6100 0c000000 10 3100 01000000 00 00",
		"bad utf8 string":  "0e000000 02 6100 02000000 ff00 00",
		"binary too long":  "0f000000 05 6100 09000000 00 dead 00",
	}
	for name, h := range bad {
		if _, err := Unmarshal(unhex(t, h)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestMarshalRejects(t *testing.T) {
	bad := []D{
		{{"a\x00b", "x"}},
		{{"a", "\xff"}},
		{{"a", 3}}, // plain int: the BSON width is ambiguous
		{{"a", A{uint8(1)}}},
	}
	for _, d := range bad {
		if _, err := Marshal(d); err == nil {
			t.Errorf("Marshal(%#v) succeeded", d)
		}
	}
}

func TestFromExtJSONRejects(t *testing.T) {
	bad := []string{
		`{"a":1}`,
		`{"a":{"$numberInt":"2147483648"}}`,
		`{"a":{"$numberInt":1}}`,
		`{"a":{"$numberLong":"1","x":1}}`,
		`{"a":{"$oid":"x"}}`,
		`{"a":{"$date":"1970-01-01T00:00:00Z"}}`,
		`{"a":{"$binary":{"base64":"3q0="}}}`,
		`{"a":{"$binary":{"base64":"3q0=","subType":"0"}}}`,
		`{"a":{"$binary":{"base64":"!!","subType":"00"}}}`,
		`{"$a":"x"}`,
		`{"a":"x"} {}`,
		`["a"]`,
	}
	for _, s := range bad {
		if _, err := FromExtJSON([]byte(s)); err == nil {
			t.Errorf("FromExtJSON(%s) succeeded", s)
		}
	}
	if _, err := ToExtJSON(D{{"$x", "y"}}); err == nil {
		t.Error("ToExtJSON accepted a $ key")
	}
}
