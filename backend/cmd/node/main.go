package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"vector/backend/pkg/mesh"
	"vector/backend/pkg/relay"
)

func main() {
	portFlag := flag.Int("port", 0, "Port for the HTTP/WebSocket node server")
	nodeIDFlag := flag.String("node-id", "", "Unique Node ID (defaults to hostname-port)")
	flag.Parse()

	port := *portFlag
	if port == 0 {
		if envPort := os.Getenv("PORT"); envPort != "" {
			var p int
			if _, err := fmt.Sscanf(envPort, "%d", &p); err == nil && p > 0 {
				port = p
			}
		}
	}
	if port == 0 {
		port = 8080
	}

	hostname, _ := os.Hostname()
	if hostname == "" {
		hostname = "field-node"
	}
	nodeID := *nodeIDFlag
	if nodeID == "" {
		nodeID = os.Getenv("NODE_ID")
	}
	if nodeID == "" {
		nodeID = fmt.Sprintf("%s-%d", hostname, port)
	}

	log.Printf("==================================================")
	log.Printf("  TACTICAL C2 DECENTRALIZED MESH BACKEND NODE    ")
	log.Printf("==================================================")
	log.Printf("  Node ID   : %s", nodeID)
	log.Printf("  Listen    : :%d", port)
	log.Printf("  Mode      : Zero-Knowledge Mesh Relay + mDNS Discovery")
	log.Printf("==================================================")

	meshNode := mesh.NewMeshNode(nodeID, port)
	relayServer := relay.NewRelayServer()

	// HTTP routes
	mux := http.NewServeMux()
	mux.HandleFunc("/ping", meshNode.PingHandler)
	mux.HandleFunc("/peers", meshNode.PeersHandler)
	mux.HandleFunc("/ws", relayServer.HandleWS)

	// Health check route
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	})

	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", port),
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Launch local network peer discovery listener
	go meshNode.StartDiscoveryListener(ctx)

	// Launch HTTP/WebSocket server in goroutine
	go func() {
		log.Printf("[NODE] Server listening on http://0.0.0.0:%d", port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[NODE] Server error: %v", err)
		}
	}()

	// Graceful shutdown handling
	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, os.Interrupt, syscall.SIGTERM)

	<-stopChan
	log.Printf("[NODE] Shutting down mesh node daemon gracefully...")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("[NODE] Shutdown error: %v", err)
	}

	log.Printf("[NODE] Mesh node offline.")
}
