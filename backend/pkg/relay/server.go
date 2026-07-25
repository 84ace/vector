package relay

import (
	"encoding/json"
	"log"
	"net/http"
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
	TypeWaypoint       EnvelopeType = "WAYPOINT"
	TypePing          EnvelopeType = "PING"
)

// MessageEnvelope is the zero-knowledge encrypted packet container.
// Nodes only inspect recipient_id/group_id for routing, without reading encrypted_body.
type MessageEnvelope struct {
	ID            string       `json:"id"`
	Type          EnvelopeType `json:"type"`
	SenderID      string       `json:"sender_id"`
	RecipientID   string       `json:"recipient_id,omitempty"`
	GroupID       string       `json:"group_id,omitempty"`
	EncryptedBody string       `json:"encrypted_body"` // Zero-knowledge ciphertext
	Timestamp     int64        `json:"timestamp"`
}

// ClientSession represents a connected operator client.
type ClientSession struct {
	OperatorID string
	Conn       *websocket.Conn
	SendChan   chan *MessageEnvelope
}

// RelayServer manages real-time WebSocket client connections and store-and-forward buffers.
type RelayServer struct {
	mu           sync.RWMutex
	clients      map[string]*ClientSession     // OperatorID -> Session
	offlineStore map[string][]*MessageEnvelope // OperatorID -> queued envelopes
	upgrader     websocket.Upgrader
}

// NewRelayServer initializes the relay server.
func NewRelayServer() *RelayServer {
	return &RelayServer{
		clients:      make(map[string]*ClientSession),
		offlineStore: make(map[string][]*MessageEnvelope),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool {
				return true // Allow all cross-origin connections for tactical field clients
			},
		},
	}
}

// HandleWS handles incoming client WebSocket connections.
func (rs *RelayServer) HandleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := rs.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[RELAY] WebSocket upgrade failed: %v", err)
		return
	}

	operatorID := r.URL.Query().Get("operator_id")
	if operatorID == "" {
		log.Printf("[RELAY] Connection rejected: missing operator_id parameter")
		_ = conn.Close()
		return
	}

	session := &ClientSession{
		OperatorID: operatorID,
		Conn:       conn,
		SendChan:   make(chan *MessageEnvelope, 256),
	}

	rs.registerClient(session)
	defer rs.unregisterClient(session)

	// Launch write loop
	go session.writeLoop()

	// Flush queued offline messages if any
	rs.flushOfflineQueue(session)

	log.Printf("[RELAY] Client connected: %s", operatorID)

	// Read loop
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

		env.SenderID = operatorID
		if env.Timestamp == 0 {
			env.Timestamp = time.Now().UnixMilli()
		}

		rs.RouteEnvelope(&env)
	}
}

func (rs *RelayServer) registerClient(s *ClientSession) {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	if old, exists := rs.clients[s.OperatorID]; exists {
		_ = old.Conn.Close()
	}
	rs.clients[s.OperatorID] = s
}

func (rs *RelayServer) unregisterClient(s *ClientSession) {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	if curr, exists := rs.clients[s.OperatorID]; exists && curr == s {
		delete(rs.clients, s.OperatorID)
		close(s.SendChan)
	}
}

// RouteEnvelope routes packets to specific recipients, groups, or broadcasts.
func (rs *RelayServer) RouteEnvelope(env *MessageEnvelope) {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	switch env.Type {
	case TypeBroadcast, TypeTelemetry, TypeSOSAlert, TypeWaypoint:
		// Broadcast telemetry, SOS alerts, waypoints or operational broadcasts to all connected operators except sender
		for id, session := range rs.clients {
			if id != env.SenderID {
				select {
				case session.SendChan <- env:
				default:
					log.Printf("[RELAY] Buffer full for operator %s, dropping broadcast packet", id)
				}
			}
		}

	case TypeChat1to1, TypeCallSignaling:
		if targetSession, online := rs.clients[env.RecipientID]; online {
			select {
			case targetSession.SendChan <- env:
			default:
				log.Printf("[RELAY] Buffer full for target operator %s", env.RecipientID)
			}
		} else if env.RecipientID != "" {
			// Store for offline delivery
			rs.storeOfflineMessage(env.RecipientID, env)
		}

	case TypeChatGroup:
		// Relay to all active clients (client E2EE layer discards if not group member)
		for id, session := range rs.clients {
			if id != env.SenderID {
				select {
				case session.SendChan <- env:
				default:
				}
			}
		}
	}
}

func (rs *RelayServer) storeOfflineMessage(operatorID string, env *MessageEnvelope) {
	queue := rs.offlineStore[operatorID]
	if len(queue) >= 500 {
		queue = queue[1:] // Drop oldest
	}
	rs.offlineStore[operatorID] = append(queue, env)
	log.Printf("[RELAY] Queued offline message for operator %s (queue size: %d)", operatorID, len(rs.offlineStore[operatorID]))
}

func (rs *RelayServer) flushOfflineQueue(s *ClientSession) {
	rs.mu.Lock()
	queue, exists := rs.offlineStore[s.OperatorID]
	if exists {
		delete(rs.offlineStore, s.OperatorID)
	}
	rs.mu.Unlock()

	if len(queue) > 0 {
		log.Printf("[RELAY] Flushing %d queued offline messages for operator %s", len(queue), s.OperatorID)
		for _, env := range queue {
			s.SendChan <- env
		}
	}
}

func (s *ClientSession) writeLoop() {
	for env := range s.SendChan {
		_ = s.Conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if err := s.Conn.WriteJSON(env); err != nil {
			log.Printf("[RELAY] Write error for %s: %v", s.OperatorID, err)
			break
		}
	}
}
