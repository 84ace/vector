package mesh

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
)

const (
	peerTTL          = 60 * time.Second
	peerSweepPeriod  = 10 * time.Second
	maxKnownPeers    = 512
	maxAnnounceBytes = 4 * 1024
)

// NodeInfo represents metadata about a mesh node.
type NodeInfo struct {
	NodeID      string    `json:"node_id"`
	Address     string    `json:"address"`
	HTTPPort    int       `json:"http_port"`
	ActivePeers int       `json:"active_peers"`
	UptimeSec   int64     `json:"uptime_sec"`
	Timestamp   time.Time `json:"timestamp"`
	IsLocalLAN  bool      `json:"is_local_lan"`
}

// MeshNode handles peer registration, ping probing, and node status.
type MeshNode struct {
	ID         string
	HTTPPort   int
	StartTime  time.Time
	mu         sync.RWMutex
	KnownPeers map[string]*NodeInfo
}

// NewMeshNode initializes a new C2 backend node.
func NewMeshNode(id string, port int) *MeshNode {
	return &MeshNode{
		ID:         id,
		HTTPPort:   port,
		StartTime:  time.Now(),
		KnownPeers: make(map[string]*NodeInfo),
	}
}

// PingHandler responds to dynamic latency measurement probes from clients.
func (mn *MeshNode) PingHandler(w http.ResponseWriter, r *http.Request) {
	mn.mu.RLock()
	peerCount := len(mn.KnownPeers)
	mn.mu.RUnlock()

	info := NodeInfo{
		NodeID:      mn.ID,
		Address:     r.Host,
		HTTPPort:    mn.HTTPPort,
		ActivePeers: peerCount,
		UptimeSec:   int64(time.Since(mn.StartTime).Seconds()),
		Timestamp:   time.Now(),
		IsLocalLAN:  isPrivateIP(r.RemoteAddr),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(info)
}

// AnnounceHandler registers a sibling node discovered on the local network.
//
// Restricted to callers on a private/loopback address: peer records steer where
// clients look for relays, so accepting them from the open internet would let
// anyone inject themselves into the mesh's view of itself. Node-to-node
// federation across untrusted networks needs node identity keys, which this
// build does not implement — the client's own signature checks are what protect
// message traffic in the meantime.
func (mn *MeshNode) AnnounceHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !isPrivateIP(r.RemoteAddr) {
		http.Error(w, "announcements are accepted from the local network only", http.StatusForbidden)
		return
	}

	var peer NodeInfo
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAnnounceBytes)).Decode(&peer); err != nil {
		http.Error(w, "invalid peer payload", http.StatusBadRequest)
		return
	}
	if peer.NodeID == "" {
		http.Error(w, "missing node_id", http.StatusBadRequest)
		return
	}

	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		peer.Address = host // Trust the observed source address, not the claim.
	}
	peer.Timestamp = time.Now()
	peer.IsLocalLAN = true

	if !mn.RegisterPeer(&peer) {
		http.Error(w, "peer table full", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// RegisterPeer adds or updates a discovered mesh node. Returns false if the
// peer table is full.
func (mn *MeshNode) RegisterPeer(peer *NodeInfo) bool {
	mn.mu.Lock()
	defer mn.mu.Unlock()

	if peer.NodeID == mn.ID {
		return true // Ignore self-announcements.
	}
	if _, known := mn.KnownPeers[peer.NodeID]; !known && len(mn.KnownPeers) >= maxKnownPeers {
		return false
	}

	mn.KnownPeers[peer.NodeID] = peer
	log.Printf("[MESH] Registered peer node: %s at %s:%d", peer.NodeID, peer.Address, peer.HTTPPort)
	return true
}

// PeersHandler returns all known active nodes in the mesh.
func (mn *MeshNode) PeersHandler(w http.ResponseWriter, r *http.Request) {
	mn.mu.RLock()
	peers := make([]*NodeInfo, 0, len(mn.KnownPeers))
	for _, p := range mn.KnownPeers {
		peers = append(peers, p)
	}
	mn.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(peers)
}

// Helper to determine if remote IP is local LAN.
func isPrivateIP(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
}

// StartPeerReaper drops peers that have stopped announcing.
func (mn *MeshNode) StartPeerReaper(ctx context.Context) {
	ticker := time.NewTicker(peerSweepPeriod)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			mn.mu.Lock()
			now := time.Now()
			for id, peer := range mn.KnownPeers {
				if now.Sub(peer.Timestamp) > peerTTL {
					log.Printf("[MESH] Removing stale peer node: %s", id)
					delete(mn.KnownPeers, id)
				}
			}
			mn.mu.Unlock()
		}
	}
}
