// Package contract defines the I/O contract both clients present: the
// reference (the boxed official client, through its grey-box taps) and the
// candidate (the Go client, natively). See DESIGN.md §6.
//
// The contract sits at the decrypted-packet + command/event boundary. An
// [Input] is everything a client consumes for one scenario step. An [Output]
// is everything it produces in response. The comparator diffs two Outputs
// for one Input.
//
// # Status: v0, provisional
//
// No inbound-decrypt tap works yet, so none of these types has been checked
// against the reference's real decoded models (DESIGN.md §12, "contract
// boundary placement"). Fields marked "Provisional" are placeholders shaped
// by the design docs only. Expect them to change once the taps produce real
// frames. Nothing here is guessed from the binary.
//
// # Text only
//
// Recorded bundles are committed to testdata/corpus/, and corpus-lint
// rejects binary files (DESIGN.md §10.1). Every type here therefore has a
// JSON form: a scenario [Bundle] is one indented JSON document, and a
// capture-bus log is JSON Lines of [Frame] values. Byte strings are base64.
// Packet bodies are BSON on the wire, so they are carried as MongoDB
// canonical Extended JSON, which keeps BSON's types and key order.
package contract
