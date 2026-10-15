// Package loco frames LOCO packets: a fixed header followed by a BSON body.
// It works on plaintext packets, the representation the crypto tap captures
// (docs/instrumentation.md §3.1). Transport encryption is out of scope.
//
// # Sources
//
// Written only from public descriptions of the LOCO wire format, from the
// source list in docs/native-ipc-findings.md. The header layout below was
// checked against the request builders in carpedm20/kakaotalk (kakao.py),
// which label each field and its width. The other sources there
// (hallazzang/pykakao, NetRiceCake/loco-wrapper, the 2012 bpak.org
// analysis) describe the same protocol. The layout is a 22-byte
// little-endian header:
//
//	offset  size  field
//	0       4     packet id   (uint32)
//	4       2     status      (int16; signedness not stated)
//	6       11    method      (ASCII, NUL-padded)
//	17      1     body type   (uint8)
//	18      4     body length (uint32; equals the BSON length prefix)
//	22      n     body        (BSON document)
//
// # Status: provisional
//
// None of this has been checked against frames from the reference's
// inbound-decrypt tap. In particular, the meaning of the body-type byte is
// not described by the sources above, so it is carried through opaquely, and
// the body is always parsed as BSON. Test vectors are synthetic.
package loco

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"github.com/frrad/mooo2/contract"
	"github.com/frrad/mooo2/loco/bson"
)

// HeaderLen is the size of the LOCO packet header.
const HeaderLen = 22

// DefaultMaxBody bounds the body length a Reader accepts, so a corrupt
// length field cannot cause a huge allocation. Provisional: not taken from
// any source.
const DefaultMaxBody = 16 << 20

// Header is a decoded LOCO packet header.
type Header struct {
	PacketID uint32
	Status   int16
	Method   string
	BodyType uint8
	BodyLen  uint32
}

// AppendHeader appends the 22-byte encoding of h to b.
func AppendHeader(b []byte, h Header) ([]byte, error) {
	if err := checkMethod(h.Method); err != nil {
		return nil, err
	}
	b = binary.LittleEndian.AppendUint32(b, h.PacketID)
	b = binary.LittleEndian.AppendUint16(b, uint16(h.Status))
	var m [contract.MaxMethodLen]byte
	copy(m[:], h.Method)
	b = append(b, m[:]...)
	b = append(b, h.BodyType)
	return binary.LittleEndian.AppendUint32(b, h.BodyLen), nil
}

// ParseHeader decodes the first HeaderLen bytes of b.
func ParseHeader(b []byte) (Header, error) {
	if len(b) < HeaderLen {
		return Header{}, fmt.Errorf("header: have %d bytes, want %d", len(b), HeaderLen)
	}
	m := b[6:17]
	method := m
	if i := bytes.IndexByte(m, 0); i >= 0 {
		method = m[:i]
		// Padding must be all NUL, so encoding is unambiguous.
		for _, c := range m[i:] {
			if c != 0 {
				return Header{}, errors.New("header: data after method terminator")
			}
		}
	}
	h := Header{
		PacketID: binary.LittleEndian.Uint32(b[0:]),
		Status:   int16(binary.LittleEndian.Uint16(b[4:])),
		Method:   string(method),
		BodyType: b[17],
		BodyLen:  binary.LittleEndian.Uint32(b[18:]),
	}
	if err := checkMethod(h.Method); err != nil {
		return Header{}, err
	}
	return h, nil
}

func checkMethod(m string) error {
	if m == "" || len(m) > contract.MaxMethodLen {
		return fmt.Errorf("method %q: want 1 to %d bytes", m, contract.MaxMethodLen)
	}
	for i := 0; i < len(m); i++ {
		if c := m[i]; c <= ' ' || c > '~' {
			return fmt.Errorf("method %q: not printable ASCII", m)
		}
	}
	return nil
}

// Packet is one plaintext LOCO packet with its body decoded.
type Packet struct {
	PacketID uint32
	Status   int16
	Method   string
	BodyType uint8
	Body     bson.D
}

// Marshal encodes p as header + BSON body.
func (p *Packet) Marshal() ([]byte, error) {
	body, err := bson.Marshal(p.Body)
	if err != nil {
		return nil, fmt.Errorf("%s body: %w", p.Method, err)
	}
	b, err := AppendHeader(make([]byte, 0, HeaderLen+len(body)), Header{
		PacketID: p.PacketID,
		Status:   p.Status,
		Method:   p.Method,
		BodyType: p.BodyType,
		BodyLen:  uint32(len(body)),
	})
	if err != nil {
		return nil, err
	}
	return append(b, body...), nil
}

// Unmarshal decodes one packet that fills b exactly.
func Unmarshal(b []byte) (*Packet, error) {
	h, err := ParseHeader(b)
	if err != nil {
		return nil, err
	}
	if uint64(len(b)-HeaderLen) != uint64(h.BodyLen) {
		return nil, fmt.Errorf("body length %d, but %d bytes follow the header", h.BodyLen, len(b)-HeaderLen)
	}
	return withBody(h, b[HeaderLen:])
}

func withBody(h Header, body []byte) (*Packet, error) {
	d, err := bson.Unmarshal(body)
	if err != nil {
		return nil, fmt.Errorf("%s body: %w", h.Method, err)
	}
	return &Packet{PacketID: h.PacketID, Status: h.Status, Method: h.Method, BodyType: h.BodyType, Body: d}, nil
}

// Reader reads consecutive packets from a plaintext stream.
type Reader struct {
	r       io.Reader
	MaxBody uint32
}

// NewReader returns a Reader with MaxBody set to DefaultMaxBody.
func NewReader(r io.Reader) *Reader { return &Reader{r: r, MaxBody: DefaultMaxBody} }

// Next reads one packet. It returns io.EOF at a clean end of stream and
// io.ErrUnexpectedEOF if the stream ends inside a packet.
func (r *Reader) Next() (*Packet, error) {
	var hb [HeaderLen]byte
	if _, err := io.ReadFull(r.r, hb[:]); err != nil {
		return nil, err
	}
	h, err := ParseHeader(hb[:])
	if err != nil {
		return nil, err
	}
	if h.BodyLen > r.MaxBody {
		return nil, fmt.Errorf("%s: body length %d exceeds limit %d", h.Method, h.BodyLen, r.MaxBody)
	}
	body := make([]byte, h.BodyLen)
	if _, err := io.ReadFull(r.r, body); err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return withBody(h, body)
}

// ToContract converts p to the contract's text form, with the body as
// canonical Extended JSON. The Cause is left for the caller.
func (p *Packet) ToContract() (contract.Packet, error) {
	body, err := bson.ToExtJSON(p.Body)
	if err != nil {
		return contract.Packet{}, fmt.Errorf("%s body: %w", p.Method, err)
	}
	return contract.Packet{
		PacketID: p.PacketID,
		Status:   p.Status,
		Method:   p.Method,
		BodyType: p.BodyType,
		Body:     body,
	}, nil
}

// FromContract converts a contract packet back to wire form. The Cause is
// dropped: it is not part of the packet.
func FromContract(cp contract.Packet) (*Packet, error) {
	if err := checkMethod(cp.Method); err != nil {
		return nil, err
	}
	d, err := bson.FromExtJSON(cp.Body)
	if err != nil {
		return nil, fmt.Errorf("%s body: %w", cp.Method, err)
	}
	return &Packet{PacketID: cp.PacketID, Status: cp.Status, Method: cp.Method, BodyType: cp.BodyType, Body: d}, nil
}
