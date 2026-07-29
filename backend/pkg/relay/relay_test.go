package relay

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type testOperator struct {
	pub  ed25519.PublicKey
	priv ed25519.PrivateKey
	id   string
}

func newTestOperator(t *testing.T) *testOperator {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	id, err := DeriveOperatorID(base64.StdEncoding.EncodeToString(pub))
	if err != nil {
		t.Fatalf("derive id: %v", err)
	}
	return &testOperator{pub: pub, priv: priv, id: id}
}

func (o *testOperator) signKeyB64() string {
	return base64.StdEncoding.EncodeToString(o.pub)
}

// connect performs the full handshake and returns a ready socket.
func (o *testOperator) connect(t *testing.T, srv *httptest.Server) *websocket.Conn {
	t.Helper()
	conn := dial(t, srv)

	var challenge AuthChallenge
	if err := conn.ReadJSON(&challenge); err != nil {
		t.Fatalf("read challenge: %v", err)
	}
	nonce, err := base64.StdEncoding.DecodeString(challenge.Nonce)
	if err != nil {
		t.Fatalf("decode nonce: %v", err)
	}

	if err := conn.WriteJSON(AuthResponse{
		Type:       "AUTH_RESPONSE",
		OperatorID: o.id,
		SignKey:    o.signKeyB64(),
		Signature:  base64.StdEncoding.EncodeToString(ed25519.Sign(o.priv, nonce)),
	}); err != nil {
		t.Fatalf("write response: %v", err)
	}

	var result AuthResult
	if err := conn.ReadJSON(&result); err != nil {
		t.Fatalf("read result: %v", err)
	}
	if !result.OK {
		t.Fatalf("authentication rejected: %s", result.Reason)
	}

	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func dial(t *testing.T, srv *httptest.Server) *websocket.Conn {
	t.Helper()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	conn, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return conn
}

func newTestServer(t *testing.T) (*RelayServer, *httptest.Server) {
	t.Helper()
	rs := NewRelayServer(nil)
	srv := httptest.NewServer(http.HandlerFunc(rs.HandleWS))
	t.Cleanup(func() {
		srv.Close()
		rs.Shutdown()
	})
	return rs, srv
}

func TestDeriveOperatorIDIsStableAndKeyBound(t *testing.T) {
	alice := newTestOperator(t)
	bob := newTestOperator(t)

	again, err := DeriveOperatorID(alice.signKeyB64())
	if err != nil {
		t.Fatalf("derive: %v", err)
	}
	if again != alice.id {
		t.Errorf("derivation not stable: %q vs %q", again, alice.id)
	}
	if alice.id == bob.id {
		t.Error("distinct keys produced the same operator ID")
	}
	if !strings.HasPrefix(alice.id, "op-") {
		t.Errorf("unexpected ID format: %q", alice.id)
	}
}

func TestDeriveOperatorIDRejectsBadKeys(t *testing.T) {
	for name, key := range map[string]string{
		"not base64":   "!!!!",
		"wrong length": base64.StdEncoding.EncodeToString([]byte("too short")),
		"empty":        "",
	} {
		if _, err := DeriveOperatorID(key); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestAuthenticatedClientCanConnect(t *testing.T) {
	rs, srv := newTestServer(t)
	alice := newTestOperator(t)
	alice.connect(t, srv)

	waitFor(t, func() bool {
		rs.mu.RLock()
		defer rs.mu.RUnlock()
		_, ok := rs.clients[alice.id]
		return ok
	}, "client to register")
}

// An operator ID that does not match the presented key must be refused, even
// though the signature over the challenge is perfectly valid. This is what stops
// a client from registering under somebody else's name.
func TestImpersonationIsRejected(t *testing.T) {
	_, srv := newTestServer(t)
	mallory := newTestOperator(t)
	victim := newTestOperator(t)

	conn := dial(t, srv)
	defer conn.Close()

	var challenge AuthChallenge
	if err := conn.ReadJSON(&challenge); err != nil {
		t.Fatalf("read challenge: %v", err)
	}
	nonce, _ := base64.StdEncoding.DecodeString(challenge.Nonce)

	if err := conn.WriteJSON(AuthResponse{
		Type:       "AUTH_RESPONSE",
		OperatorID: victim.id, // Claimed
		SignKey:    mallory.signKeyB64(),
		Signature:  base64.StdEncoding.EncodeToString(ed25519.Sign(mallory.priv, nonce)),
	}); err != nil {
		t.Fatalf("write response: %v", err)
	}

	var result AuthResult
	if err := conn.ReadJSON(&result); err != nil {
		t.Fatalf("read result: %v", err)
	}
	if result.OK {
		t.Fatal("relay accepted an operator ID that does not match the presented key")
	}
}

func TestBadSignatureIsRejected(t *testing.T) {
	_, srv := newTestServer(t)
	alice := newTestOperator(t)

	conn := dial(t, srv)
	defer conn.Close()

	var challenge AuthChallenge
	if err := conn.ReadJSON(&challenge); err != nil {
		t.Fatalf("read challenge: %v", err)
	}

	// Sign something other than the challenge we were issued.
	if err := conn.WriteJSON(AuthResponse{
		Type:       "AUTH_RESPONSE",
		OperatorID: alice.id,
		SignKey:    alice.signKeyB64(),
		Signature:  base64.StdEncoding.EncodeToString(ed25519.Sign(alice.priv, []byte("not the nonce"))),
	}); err != nil {
		t.Fatalf("write response: %v", err)
	}

	var result AuthResult
	if err := conn.ReadJSON(&result); err != nil {
		t.Fatalf("read result: %v", err)
	}
	if result.OK {
		t.Fatal("relay accepted a signature over the wrong message")
	}
}

func TestChallengesAreUniquePerConnection(t *testing.T) {
	_, srv := newTestServer(t)
	seen := map[string]bool{}

	for i := 0; i < 8; i++ {
		conn := dial(t, srv)
		var challenge AuthChallenge
		if err := conn.ReadJSON(&challenge); err != nil {
			t.Fatalf("read challenge: %v", err)
		}
		if seen[challenge.Nonce] {
			t.Fatal("challenge nonce was reused across connections")
		}
		seen[challenge.Nonce] = true
		_ = conn.Close()
	}
}

// The sender fields are set by the relay from the authenticated session, so a
// client cannot put someone else's name on an envelope.
func TestRelayOverwritesSenderFields(t *testing.T) {
	_, srv := newTestServer(t)
	alice := newTestOperator(t)
	bob := newTestOperator(t)

	aliceConn := alice.connect(t, srv)
	bobConn := bob.connect(t, srv)

	forged := MessageEnvelope{
		ID:            "m1",
		Type:          TypeChat1to1,
		SenderID:      "op-somebody-else",
		SenderSignKey: "a-key-alice-does-not-own",
		RecipientID:   bob.id,
		EncryptedBody: "ciphertext",
	}
	if err := aliceConn.WriteJSON(forged); err != nil {
		t.Fatalf("write: %v", err)
	}

	_ = bobConn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var got MessageEnvelope
	if err := bobConn.ReadJSON(&got); err != nil {
		t.Fatalf("read: %v", err)
	}

	if got.SenderID != alice.id {
		t.Errorf("sender_id = %q, want %q", got.SenderID, alice.id)
	}
	if got.SenderSignKey != alice.signKeyB64() {
		t.Error("sender_sign_key was not replaced with the authenticated key")
	}
	if got.Timestamp == 0 {
		t.Error("relay did not stamp the envelope")
	}
}

func TestDirectRoutingReachesOnlyTheRecipient(t *testing.T) {
	_, srv := newTestServer(t)
	alice := newTestOperator(t)
	bob := newTestOperator(t)
	carol := newTestOperator(t)

	aliceConn := alice.connect(t, srv)
	bobConn := bob.connect(t, srv)
	carolConn := carol.connect(t, srv)

	if err := aliceConn.WriteJSON(MessageEnvelope{
		ID:            "m1",
		Type:          TypeChat1to1,
		RecipientID:   bob.id,
		EncryptedBody: "for bob",
	}); err != nil {
		t.Fatalf("write: %v", err)
	}

	_ = bobConn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var got MessageEnvelope
	if err := bobConn.ReadJSON(&got); err != nil {
		t.Fatalf("bob should have received the message: %v", err)
	}
	if got.EncryptedBody != "for bob" {
		t.Errorf("body = %q", got.EncryptedBody)
	}

	_ = carolConn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if err := carolConn.ReadJSON(&got); err == nil {
		t.Fatal("carol received a message addressed to bob")
	}
}

func TestOfflineMessagesAreQueuedAndFlushed(t *testing.T) {
	rs, srv := newTestServer(t)
	alice := newTestOperator(t)
	bob := newTestOperator(t)

	aliceConn := alice.connect(t, srv)

	// Bob is not connected yet.
	if err := aliceConn.WriteJSON(MessageEnvelope{
		ID:            "queued-1",
		Type:          TypeChat1to1,
		RecipientID:   bob.id,
		EncryptedBody: "waiting for bob",
	}); err != nil {
		t.Fatalf("write: %v", err)
	}

	waitFor(t, func() bool {
		rs.mu.RLock()
		defer rs.mu.RUnlock()
		return len(rs.offlineStore[bob.id]) == 1
	}, "message to be queued")

	bobConn := bob.connect(t, srv)
	_ = bobConn.SetReadDeadline(time.Now().Add(3 * time.Second))

	var got MessageEnvelope
	if err := bobConn.ReadJSON(&got); err != nil {
		t.Fatalf("bob should have received the queued message: %v", err)
	}
	if got.ID != "queued-1" {
		t.Errorf("id = %q", got.ID)
	}

	rs.mu.RLock()
	remaining := len(rs.offlineStore[bob.id])
	rs.mu.RUnlock()
	if remaining != 0 {
		t.Errorf("queue not drained: %d left", remaining)
	}
}

func TestOfflineStoreIsBoundedPerOperator(t *testing.T) {
	rs := NewRelayServer(nil)
	defer rs.Shutdown()

	for i := 0; i < maxOfflinePerOp+50; i++ {
		rs.storeOfflineMessage("op-target", &MessageEnvelope{ID: fmt.Sprintf("m%d", i)})
	}

	rs.mu.RLock()
	defer rs.mu.RUnlock()
	if got := len(rs.offlineStore["op-target"]); got != maxOfflinePerOp {
		t.Errorf("queue depth = %d, want %d", got, maxOfflinePerOp)
	}
}

func TestOfflineStoreIsBoundedByOperatorCount(t *testing.T) {
	rs := NewRelayServer(nil)
	defer rs.Shutdown()

	// Recipient IDs are attacker-chosen, so the map itself must be capped.
	for i := 0; i < maxOfflineOperators+100; i++ {
		rs.storeOfflineMessage(fmt.Sprintf("op-%d", i), &MessageEnvelope{ID: "m"})
	}

	rs.mu.RLock()
	defer rs.mu.RUnlock()
	if got := len(rs.offlineStore); got > maxOfflineOperators {
		t.Errorf("tracked %d operators, cap is %d", got, maxOfflineOperators)
	}
}

// Regression: RouteEnvelope used to mutate the offline store while holding only
// a read lock, so two goroutines routing to offline recipients could trigger a
// concurrent map write and take the whole node down. Run with -race.
func TestConcurrentRoutingToOfflineRecipients(t *testing.T) {
	rs := NewRelayServer(nil)
	defer rs.Shutdown()

	var wg sync.WaitGroup
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				rs.RouteEnvelope(&MessageEnvelope{
					ID:          fmt.Sprintf("m-%d-%d", n, j),
					Type:        TypeChat1to1,
					SenderID:    "op-sender",
					RecipientID: fmt.Sprintf("op-offline-%d", n%8),
				})
			}
		}(i)
	}
	wg.Wait()
}

func TestConcurrentBroadcastAndDisconnect(t *testing.T) {
	rs, srv := newTestServer(t)

	operators := make([]*testOperator, 6)
	for i := range operators {
		operators[i] = newTestOperator(t)
		operators[i].connect(t, srv)
	}

	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			rs.RouteEnvelope(&MessageEnvelope{
				ID:       fmt.Sprintf("b%d", n),
				Type:     TypeBroadcast,
				SenderID: "op-sender",
			})
		}(i)
	}
	wg.Wait()
}

// A second authenticated connection for the same ID retires the first, and the
// old write loop must exit rather than block on its channel forever.
func TestReconnectRetiresPreviousSession(t *testing.T) {
	rs, srv := newTestServer(t)
	alice := newTestOperator(t)

	first := alice.connect(t, srv)
	waitFor(t, func() bool {
		rs.mu.RLock()
		defer rs.mu.RUnlock()
		return rs.clients[alice.id] != nil
	}, "first session to register")

	rs.mu.RLock()
	firstSession := rs.clients[alice.id]
	rs.mu.RUnlock()

	alice.connect(t, srv)

	select {
	case <-firstSession.done:
		// Old session released.
	case <-time.After(3 * time.Second):
		t.Fatal("previous session was not closed on reconnect")
	}

	_ = first.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := first.ReadMessage(); err == nil {
		t.Error("expected the retired connection to be closed")
	}
}

func TestUnauthenticatedClientCannotSend(t *testing.T) {
	rs, srv := newTestServer(t)

	conn := dial(t, srv)
	defer conn.Close()

	// Skip the handshake entirely and send an envelope.
	if err := conn.WriteJSON(MessageEnvelope{
		ID:          "x",
		Type:        TypeBroadcast,
		SenderID:    "op-anyone",
		RecipientID: "op-victim",
	}); err != nil {
		t.Fatalf("write: %v", err)
	}

	time.Sleep(300 * time.Millisecond)

	rs.mu.RLock()
	defer rs.mu.RUnlock()
	if len(rs.clients) != 0 {
		t.Error("an unauthenticated connection was registered as a client")
	}
	if len(rs.offlineStore) != 0 {
		t.Error("an unauthenticated connection queued a message")
	}
}

func TestOriginIsCheckedForBrowserClients(t *testing.T) {
	rs := NewRelayServer([]string{"https://c2.example.com"})
	defer rs.Shutdown()
	srv := httptest.NewServer(http.HandlerFunc(rs.HandleWS))
	defer srv.Close()

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"

	if _, _, err := websocket.DefaultDialer.Dial(url, http.Header{
		"Origin": []string{"https://evil.example.com"},
	}); err == nil {
		t.Error("upgrade from a disallowed origin was accepted")
	}

	conn, _, err := websocket.DefaultDialer.Dial(url, http.Header{
		"Origin": []string{"https://c2.example.com"},
	})
	if err != nil {
		t.Errorf("upgrade from an allowed origin was refused: %v", err)
	} else {
		_ = conn.Close()
	}
}

func TestEnvelopeJSONRoundTrip(t *testing.T) {
	env := MessageEnvelope{
		ID:            "m1",
		Type:          TypePairRequest,
		SenderID:      "op-abc",
		SenderSignKey: "key",
		RecipientID:   "op-def",
		EncryptedBody: "body",
		Timestamp:     1700000000000,
		Signature:     "sig",
	}

	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got MessageEnvelope
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got != env {
		t.Errorf("round trip changed the envelope:\n got %+v\nwant %+v", got, env)
	}
}

func waitFor(t *testing.T, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}
