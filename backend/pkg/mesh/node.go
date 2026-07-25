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

// MeshNode handles peer discovery, ping probing, and node status.
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
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(info)
}

// RegisterPeer adds or updates a discovered mesh node.
func (mn *MeshNode) RegisterPeer(peer *NodeInfo) {
	mn.mu.Lock()
	defer mn.mu.Unlock()
	if peer.NodeID == mn.ID {
		return
	}
	mn.KnownPeers[peer.NodeID] = peer
	log.Printf("[MESH] Discovered/Updated peer node: %s at %s:%d", peer.NodeID, peer.Address, peer.HTTPPort)
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
	w.Header().Set("Access-Control-Allow-Origin", "*")
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

// StartDiscoveryListener runs periodic subnet broadcast/mDNS sync simulation.
func (mn *MeshNode) StartDiscoveryListener(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Cleanup stale peers older than 60s
			mn.mu.Lock()
			now := time.Now()
			for id, peer := range mn.KnownPeers {
				if now.Sub(peer.Timestamp) > 60*time.Second {
					log.Printf("[MESH] Removing stale peer node: %s", id)
					delete(mn.KnownPeers, id)
				}
			}
			mn.mu.Unlock()
		}
	}
}
