package relay

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

// TestDartClientInterop verifies that the Go node agrees with the Dart client on
// the two things the handshake depends on: how an operator ID is derived from a
// signing key, and what bytes a challenge response signs.
//
// The fixture in testdata was produced by the Dart implementation
// (client/test/interop_vector_test.dart). If either side changes its base64
// alphabet, digest truncation, or signed payload, this fails — without it, the
// mismatch would only show up as "no client can connect", with both unit suites
// still green.
func TestDartClientInterop(t *testing.T) {
	raw, err := os.ReadFile("testdata/dart_interop.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	var v struct {
		OperatorID string `json:"operator_id"`
		SignKey    string `json:"sign_key"`
		Nonce      string `json:"nonce"`
		Signature  string `json:"signature"`
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}

	derived, err := DeriveOperatorID(v.SignKey)
	if err != nil {
		t.Fatalf("derive: %v", err)
	}
	if derived != v.OperatorID {
		t.Fatalf("operator ID derivation disagrees with the Dart client:\n  go   = %q\n  dart = %q", derived, v.OperatorID)
	}

	nonce, err := base64.StdEncoding.DecodeString(v.Nonce)
	if err != nil {
		t.Fatalf("decode nonce: %v", err)
	}

	resp := &AuthResponse{
		Type:       "AUTH_RESPONSE",
		OperatorID: v.OperatorID,
		SignKey:    v.SignKey,
		Signature:  v.Signature,
	}
	if err := verifyAuthResponse(resp, nonce); err != nil {
		t.Fatalf("Go relay rejected a handshake signed by the Dart client: %v", err)
	}
}
