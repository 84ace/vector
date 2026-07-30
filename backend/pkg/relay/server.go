package relay

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// EnvelopeType demarcates encrypted message payloads.
type EnvelopeType string

const (
	TypeTelemetry     EnvelopeType = "TELEMETRY"
	TypeChat1to1      EnvelopeType = "CHAT_1TO1"
	TypeChatGroup     EnvelopeType = "CHAT_GROUP"
	TypeBroadcast     EnvelopeType = "BROADCAST"
	TypeCallSignaling EnvelopeType = "CALL_SIGNALING"
	TypeSOSAlert      EnvelopeType = "SOS_ALERT"
	TypeWaypoint      EnvelopeType = "WAYPOINT"
	TypePing          EnvelopeType = "PING"
	TypePairRequest   EnvelopeType = "PAIR_REQUEST"
)

// Connection and resource limits. The relay is reachable by anyone who can
// complete the identity handshake, so every buffer it keeps has to be bounded.
const (
	authTimeout         = 10 * time.Second
	maxEnvelopeBytes    = 512 * 1024 // Largest single frame: a PTT audio chunk.
	pongWait            = 60 * time.Second
	pingInterval        = (pongWait * 9) / 10
	writeWait           = 10 * time.Second
	sendBuffer          = 256
	maxOfflinePerOp     = 500
	maxOfflineOperators = 5000
	offlineTTL          = 24 * time.Hour
	janitorInterval     = 5 * time.Minute
)

// MessageEnvelope is the encrypted packet container.
//
// The node routes on recipient_id/group_id and never reads encrypted_body — it
// holds no key material and cannot decrypt traffic. It does see routing
// metadata (who talks to whom, when, and how much), which is not hidden.
type MessageEnvelope struct {
	ID            string       `json:"id"`
	Type          EnvelopeType `json:"type"`
	SenderID      string       `json:"sender_id"`
	SenderSignKey string       `json:"sender_sign_key,omitempty"`
	RecipientID   string       `json:"recipient_id,omitempty"`
	GroupID       string       `json:"group_id,omitempty"`
	EncryptedBody string       `json:"encrypted_body"`
	Timestamp     int64        `json:"timestamp"`
	Signature     string       `json:"signature,omitempty"`
}

type queuedEnvelope struct {
	env      *MessageEnvelope
	queuedAt time.Time
}

// ClientSession represents a connected operator client.
type ClientSession struct {
	OperatorID string
	SignKey    string
	Conn       *websocket.Conn
	SendChan   chan *MessageEnvelope

	// done is closed exactly once when the session ends. SendChan is never
	// closed: routers may hold a reference to this session concurrently, and
	// closing a channel out from under them would panic on send. The write loop
	// exits on done instead, and any envelopes still buffered are collected.
	done      chan struct{}
	closeOnce sync.Once
}

func (s *ClientSession) close() {
	s.closeOnce.Do(func() { close(s.done) })
}

// enqueue hands an envelope to the session's write loop, dropping it if the
// peer has stopped reading or the session has ended.
func (s *ClientSession) enqueue(env *MessageEnvelope) bool {
	select {
	case <-s.done:
		return false
	default:
	}

	select {
	case s.SendChan <- env:
		return true
	default:
		return false
	}
}

// RelayServer manages real-time WebSocket client connections and store-and-forward buffers.
type RelayServer struct {
	mu           sync.RWMutex
	clients      map[string]*ClientSession
	offlineStore map[string][]queuedEnvelope
	upgrader     websocket.Upgrader
	stop         chan struct{}

	// logRouting logs every routing decision, including the successful ones.
	//
	// Off unless RELAY_LOG_ROUTING is set, and deliberately so: a permanent
	// record of who sent what to whom, when, is precisely the metadata
	// SECURITY.md warns this node is in a position to collect, and it would be
	// dominated by telemetry — every operator, every few seconds.
	//
	// It exists because the alternative, while diagnosing why a message did not
	// arrive, is having no way to tell "the sender never transmitted" from "the
	// relay delivered it and the recipient discarded it". Those need opposite
	// fixes. Turn it on for a test, read the answer, turn it off.
	logRouting bool
}

// NewRelayServer initializes the relay server.
//
// allowedOrigins gates browser-originated upgrades. An empty list rejects every
// request that carries an Origin header, which is the right default for native
// field clients: they send no Origin, so they are unaffected, while a hostile
// web page cannot open a socket using a visitor's network position.
func NewRelayServer(allowedOrigins []string) *RelayServer {
	allowed := make(map[string]struct{}, len(allowedOrigins))
	for _, o := range allowedOrigins {
		allowed[o] = struct{}{}
	}

	rs := &RelayServer{
		clients:      make(map[string]*ClientSession),
		offlineStore: make(map[string][]queuedEnvelope),
		stop:         make(chan struct{}),
		logRouting:   os.Getenv("RELAY_LOG_ROUTING") != "",
		upgrader: websocket.Upgrader{
			HandshakeTimeout: 10 * time.Second,
			CheckOrigin: func(r *http.Request) bool {
				origin := r.Header.Get("Origin")
				if origin == "" {
					return true // Native client; no browser same-origin context to abuse.
				}
				_, ok := allowed[origin]
				if !ok {
					log.Printf("[RELAY] Rejected upgrade from disallowed origin %q", origin)
				}
				return ok
			},
		},
	}

	go rs.janitor()
	return rs
}

// Shutdown stops background maintenance and disconnects every client.
func (rs *RelayServer) Shutdown() {
	close(rs.stop)

	rs.mu.Lock()
	sessions := make([]*ClientSession, 0, len(rs.clients))
	for _, s := range rs.clients {
		sessions = append(sessions, s)
	}
	rs.clients = make(map[string]*ClientSession)
	rs.offlineStore = make(map[string][]queuedEnvelope)
	rs.mu.Unlock()

	for _, s := range sessions {
		s.close()
		_ = s.Conn.Close()
	}
}

// janitor expires stale offline queues so a peer that never returns cannot pin
// memory forever.
func (rs *RelayServer) janitor() {
	ticker := time.NewTicker(janitorInterval)
	defer ticker.Stop()

	for {
		select {
		case <-rs.stop:
			return
		case <-ticker.C:
			cutoff := time.Now().Add(-offlineTTL)
			rs.mu.Lock()
			for id, queue := range rs.offlineStore {
				kept := queue[:0]
				for _, q := range queue {
					if q.queuedAt.After(cutoff) {
						kept = append(kept, q)
					}
				}
				if len(kept) == 0 {
					delete(rs.offlineStore, id)
				} else {
					rs.offlineStore[id] = kept
				}
			}
			rs.mu.Unlock()
		}
	}
}

// HandleWS handles incoming client WebSocket connections.
func (rs *RelayServer) HandleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := rs.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[RELAY] WebSocket upgrade failed: %v", err)
		return
	}

	conn.SetReadLimit(maxEnvelopeBytes)

	// The operator ID is established by the signed handshake below. It is never
	// taken from a query parameter, which anyone could set to anything.
	operatorID, signKey, err := rs.authenticate(conn)
	if err != nil {
		log.Printf("[RELAY] Authentication failed from %s: %v", r.RemoteAddr, err)
		_ = conn.WriteJSON(AuthResult{Type: "AUTH_RESULT", OK: false, Reason: "authentication failed"})
		_ = conn.Close()
		return
	}

	if err := conn.WriteJSON(AuthResult{Type: "AUTH_RESULT", OK: true}); err != nil {
		_ = conn.Close()
		return
	}

	session := &ClientSession{
		OperatorID: operatorID,
		SignKey:    signKey,
		Conn:       conn,
		SendChan:   make(chan *MessageEnvelope, sendBuffer),
		done:       make(chan struct{}),
	}

	rs.registerClient(session)
	defer rs.unregisterClient(session)

	go session.writeLoop()
	rs.flushOfflineQueue(session)

	log.Printf("[RELAY] Client authenticated and connected: %s", operatorID)

	_ = conn.SetReadDeadline(time.Now().Add(pongWait))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(pongWait))
	})

	for {
		_, rawMsg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[RELAY] Client disconnected: %s (%v)", operatorID, err)
			break
		}

		var env MessageEnvelope
		if err := json.Unmarshal(rawMsg, &env); err != nil {
			log.Printf("[RELAY] Invalid envelope JSON from %s: %v", operatorID, err)
			continue
		}

		// Bind the envelope to the authenticated session. A client cannot send
		// on behalf of anyone else, and cannot swap in a different identity key
		// than the one it proved ownership of — recipients verify the envelope
		// signature against exactly this key.
		env.SenderID = operatorID
		env.SenderSignKey = signKey
		if env.Timestamp == 0 {
			env.Timestamp = time.Now().UnixMilli()
		}

		rs.RouteEnvelope(&env)
	}

	session.close()
}

// authenticate runs the challenge/response handshake and returns the proven
// operator ID and identity key.
func (rs *RelayServer) authenticate(conn *websocket.Conn) (string, string, error) {
	nonce, nonceB64, err := newChallenge()
	if err != nil {
		return "", "", err
	}

	_ = conn.SetWriteDeadline(time.Now().Add(authTimeout))
	if err := conn.WriteJSON(AuthChallenge{Type: "AUTH_CHALLENGE", Nonce: nonceB64}); err != nil {
		return "", "", err
	}

	_ = conn.SetReadDeadline(time.Now().Add(authTimeout))
	var resp AuthResponse
	if err := conn.ReadJSON(&resp); err != nil {
		return "", "", err
	}

	if err := verifyAuthResponse(&resp, nonce); err != nil {
		return "", "", err
	}

	_ = conn.SetWriteDeadline(time.Time{})
	return resp.OperatorID, resp.SignKey, nil
}

func (rs *RelayServer) registerClient(s *ClientSession) {
	rs.mu.Lock()
	old, exists := rs.clients[s.OperatorID]
	rs.clients[s.OperatorID] = s
	rs.mu.Unlock()

	// A second authenticated connection for the same ID can only come from a
	// device holding the same private key, so this is a genuine reconnect or a
	// second device. Retire the old session and release its write loop, which
	// previously leaked a goroutine per reconnect.
	if exists {
		old.close()
		_ = old.Conn.Close()
	}
}

func (rs *RelayServer) unregisterClient(s *ClientSession) {
	s.close()

	rs.mu.Lock()
	defer rs.mu.Unlock()
	if curr, exists := rs.clients[s.OperatorID]; exists && curr == s {
		delete(rs.clients, s.OperatorID)
	}
}

// RouteEnvelope routes packets to specific recipients, groups, or broadcasts.
//
// Delivery targets are collected under a read lock and written to afterwards.
// Sending while holding the lock, or mutating the offline store under a *read*
// lock as an earlier version did, produced concurrent map writes that crashed
// the whole node.
func (rs *RelayServer) RouteEnvelope(env *MessageEnvelope) {
	var targets []*ClientSession
	var queueFor string
	var undeliverable bool

	rs.mu.RLock()
	switch env.Type {
	case TypeBroadcast, TypeTelemetry, TypeSOSAlert, TypeWaypoint, TypeChatGroup:
		// Fan out to every other connected operator. Non-members cannot read the
		// body: it is sealed under the team key.
		for id, session := range rs.clients {
			if id != env.SenderID {
				targets = append(targets, session)
			}
		}

	case TypeChat1to1, TypeCallSignaling, TypePairRequest:
		if session, online := rs.clients[env.RecipientID]; online {
			targets = append(targets, session)
		} else if env.RecipientID != "" {
			queueFor = env.RecipientID
		} else {
			// A directed type with no recipient has nowhere to go. This used to
			// fall through silently, which is indistinguishable from delivery
			// from the sender's side.
			undeliverable = true
		}

	case TypePing:
		if session, online := rs.clients[env.SenderID]; online {
			targets = append(targets, session)
		}
	}
	rs.mu.RUnlock()

	if rs.logRouting {
		names := make([]string, 0, len(targets))
		for _, t := range targets {
			names = append(names, t.OperatorID)
		}
		log.Printf("[ROUTE] %s id=%s from=%s to=%q targets=%v queue=%q",
			env.Type, env.ID, env.SenderID, env.RecipientID, names, queueFor)
	}

	for _, session := range targets {
		if !session.enqueue(env) {
			log.Printf("[RELAY] Buffer full for operator %s, dropping %s packet", session.OperatorID, env.Type)
		}
	}

	if queueFor != "" {
		rs.storeOfflineMessage(queueFor, env)
		// The one case that most needs saying out loud. A message addressed to an
		// operator ID that never connects is indistinguishable, from the sender's
		// side, from one that was delivered — and the commonest cause is not an
		// absent operator but a stale contact record: an operator ID is derived
		// from the identity key, so a reinstall gives the same person a new ID
		// while their peer keeps addressing the old one. Comparing the recipient
		// here against the IDs that actually authenticate is what tells those
		// apart in seconds instead of hours.
		//
		// This does record who addressed whom, which is the metadata SECURITY.md
		// warns this node can see. It is limited to traffic that was *not*
		// delivered, which is the trade being made deliberately: an undelivered
		// message is already a fault worth reconstructing.
		log.Printf("[RELAY] %s from %s queued: recipient %s is not connected",
			env.Type, env.SenderID, queueFor)
	}

	// Deliberately only the failures. Logging every successful route would build
	// exactly the record of who-talks-to-whom that SECURITY.md warns this node
	// can see, and would be dominated by telemetry besides. A packet that went
	// nowhere is the case an operator needs to be able to reconstruct.
	if undeliverable {
		log.Printf("[RELAY] Undeliverable %s from %s: no recipient addressed", env.Type, env.SenderID)
	}
	if len(targets) == 0 && queueFor == "" && !undeliverable && env.Type != TypePing {
		log.Printf("[RELAY] %s from %s reached no connected operator", env.Type, env.SenderID)
	}
}

// storeOfflineMessage queues an envelope for a recipient that is not connected.
//
// Both the per-operator depth and the number of distinct operators are capped:
// recipient IDs are attacker-chosen, so an unbounded map here is a memory
// exhaustion primitive.
func (rs *RelayServer) storeOfflineMessage(operatorID string, env *MessageEnvelope) {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	queue, exists := rs.offlineStore[operatorID]
	if !exists && len(rs.offlineStore) >= maxOfflineOperators {
		log.Printf("[RELAY] Offline store at capacity, dropping message for %s", operatorID)
		return
	}

	if len(queue) >= maxOfflinePerOp {
		// Dropping the oldest is the right choice — in a comms backlog the newest
		// traffic is the useful part — but it was silent, so an operator who came
		// back to a truncated backlog had no way to know anything was missing.
		log.Printf("[RELAY] Offline queue for %s is full (%d), discarding oldest message",
			operatorID, maxOfflinePerOp)
		queue = queue[1:]
	}
	rs.offlineStore[operatorID] = append(queue, queuedEnvelope{env: env, queuedAt: time.Now()})
}

func (rs *RelayServer) flushOfflineQueue(s *ClientSession) {
	rs.mu.Lock()
	queue, exists := rs.offlineStore[s.OperatorID]
	if exists {
		delete(rs.offlineStore, s.OperatorID)
	}
	rs.mu.Unlock()

	if len(queue) == 0 {
		return
	}

	log.Printf("[RELAY] Flushing %d queued messages for operator %s", len(queue), s.OperatorID)
	for i, q := range queue {
		// Non-blocking: the queue can exceed the send buffer, and a peer that
		// stops reading must not wedge this goroutine.
		if s.enqueue(q.env) {
			continue
		}

		// The queue was removed from the store before delivery began, so simply
		// returning here discarded every remaining message permanently — a slow
		// reader on reconnect silently lost the tail of its own backlog. Put the
		// undelivered remainder back and let the next reconnect try again.
		remaining := queue[i:]
		log.Printf("[RELAY] Send buffer full for %s while flushing, re-queueing %d message(s)",
			s.OperatorID, len(remaining))
		rs.requeueOffline(s.OperatorID, remaining)
		return
	}
}

// requeueOffline puts undelivered messages back at the front of the operator's
// queue, preserving order against anything that arrived while the flush ran.
func (rs *RelayServer) requeueOffline(operatorID string, undelivered []queuedEnvelope) {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	restored := append(append([]queuedEnvelope{}, undelivered...), rs.offlineStore[operatorID]...)
	if len(restored) > maxOfflinePerOp {
		// Keep the newest, consistent with storeOfflineMessage.
		restored = restored[len(restored)-maxOfflinePerOp:]
	}
	rs.offlineStore[operatorID] = restored
}

func (s *ClientSession) writeLoop() {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-s.done:
			return

		case env := <-s.SendChan:
			_ = s.Conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := s.Conn.WriteJSON(env); err != nil {
				log.Printf("[RELAY] Write error for %s: %v", s.OperatorID, err)
				s.close()
				_ = s.Conn.Close()
				return
			}

		case <-ticker.C:
			// Keepalive so half-open connections are detected instead of
			// occupying an operator ID indefinitely.
			_ = s.Conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := s.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				s.close()
				_ = s.Conn.Close()
				return
			}
		}
	}
}
