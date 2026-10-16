package contract

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// BundleFormat identifies the bundle encoding. Bump it on any incompatible
// change to the contract types.
const BundleFormat = "mooo2.contract/v0"

// Bundle is one recorded scenario: a sequence of steps, each an Input and
// the Output the reference produced for it. This is the unit committed to
// testdata/corpus/ (DESIGN.md §10.1).
type Bundle struct {
	Format   string `json:"format"`
	Scenario string `json:"scenario"`
	Steps    []Step `json:"steps"`
}

// Step is one scenario step.
type Step struct {
	Input  Input  `json:"input"`
	Output Output `json:"output"`
}

// Validate checks the format tag and every step.
func (b *Bundle) Validate() error {
	if b.Format != BundleFormat {
		return fmt.Errorf("bundle format %q: want %q", b.Format, BundleFormat)
	}
	if b.Scenario == "" {
		return errors.New("bundle: empty scenario")
	}
	for i := range b.Steps {
		s := &b.Steps[i]
		if err := s.Input.Validate(); err != nil {
			return fmt.Errorf("steps[%d].input.%w", i, err)
		}
		if err := s.Output.Validate(&s.Input); err != nil {
			return fmt.Errorf("steps[%d].output.%w", i, err)
		}
	}
	return nil
}

// MarshalBundle validates b and encodes it as indented JSON with a trailing
// newline. The encoding is deterministic: the same bundle always gives the
// same bytes, so corpus diffs stay reviewable.
func MarshalBundle(b *Bundle) ([]byte, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(b); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ReadBundle decodes and validates one bundle. Unknown fields and trailing
// data are errors, so a typo in a hand-edited bundle fails loudly.
func ReadBundle(r io.Reader) (*Bundle, error) {
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	var b Bundle
	if err := dec.Decode(&b); err != nil {
		return nil, fmt.Errorf("bundle: %w", err)
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("bundle: trailing data after document")
	}
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return &b, nil
}
