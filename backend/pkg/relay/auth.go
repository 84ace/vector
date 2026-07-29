package relay

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
)

// challengeSize is the length of the random nonce a client must sign to prove
// it holds the private key behind the operator ID it claims.
const challengeSize = 32

// AuthChallenge is sent by the node immediately after the WebSocket upgrade.
type AuthChallenge struct {
	Type  string `json:"type"`
	Nonce string `json:"nonce"`
}

// AuthResponse is the client's signed answer to an AuthChallenge.
type AuthResponse struct {
	Type       string `json:"type"`
	OperatorID string `json:"operator_id"`
	SignKey    string `json:"sign_key"`
	Signature  string `json:"signature"`
}

// AuthResult tells the client whether it may proceed.
type AuthResult struct {
	Type   string `json:"type"`
	OK     bool   `json:"ok"`
	Reason string `json:"reason,omitempty"`
}

// newChallenge returns a fresh random nonce and its base64 encoding.
func newChallenge() ([]byte, string, error) {
	nonce := make([]byte, challengeSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, "", err
	}
	return nonce, base64.StdEncoding.EncodeToString(nonce), nil
}

// DeriveOperatorID reproduces the client's ID derivation: the first 16 hex
// characters of SHA-256 over the raw Ed25519 public key, prefixed with "op-".
//
// Because the ID is a function of the key, an operator ID is self-certifying:
// there is no directory to consult and no way to claim someone else's ID
// without their private key.
func DeriveOperatorID(signKeyBase64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(signKeyBase64)
	if err != nil {
		return "", fmt.Errorf("sign key is not valid base64: %w", err)
	}
	if len(raw) != ed25519.PublicKeySize {
		return "", fmt.Errorf("sign key is %d bytes, want %d", len(raw), ed25519.PublicKeySize)
	}
	sum := sha256.Sum256(raw)
	return "op-" + hex.EncodeToString(sum[:])[:16], nil
}

// verifyAuthResponse checks that resp proves ownership of the claimed operator ID.
//
// Both properties must hold: the signature validates over the challenge we
// issued, and the claimed ID is the one derived from the presented key. The
// second check is what stops a client with a perfectly valid signature from
// registering under somebody else's name.
func verifyAuthResponse(resp *AuthResponse, challenge []byte) error {
	if resp.Type != "AUTH_RESPONSE" {
		return fmt.Errorf("expected AUTH_RESPONSE, got %q", resp.Type)
	}

	derived, err := DeriveOperatorID(resp.SignKey)
	if err != nil {
		return err
	}
	if derived != resp.OperatorID {
		return fmt.Errorf("operator ID %q does not match key (derived %q)", resp.OperatorID, derived)
	}

	rawKey, err := base64.StdEncoding.DecodeString(resp.SignKey)
	if err != nil {
		return fmt.Errorf("sign key is not valid base64: %w", err)
	}
	sig, err := base64.StdEncoding.DecodeString(resp.Signature)
	if err != nil {
		return fmt.Errorf("signature is not valid base64: %w", err)
	}
	if len(sig) != ed25519.SignatureSize {
		return fmt.Errorf("signature is %d bytes, want %d", len(sig), ed25519.SignatureSize)
	}

	if !ed25519.Verify(ed25519.PublicKey(rawKey), challenge, sig) {
		return fmt.Errorf("signature does not verify over challenge")
	}
	return nil
}
