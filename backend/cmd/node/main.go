package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"vector/backend/pkg/mesh"
	"vector/backend/pkg/relay"
)

func main() {
	portFlag := flag.Int("port", 0, "Port for the HTTP/WebSocket node server")
	nodeIDFlag := flag.String("node-id", "", "Unique Node ID (defaults to hostname-port)")
	tlsCertFlag := flag.String("tls-cert", "", "Path to TLS certificate (enables HTTPS/WSS)")
	tlsKeyFlag := flag.String("tls-key", "", "Path to TLS private key")
	originsFlag := flag.String("allowed-origins", "", "Comma-separated browser origins permitted to open WebSockets")
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

	tlsCert := firstNonEmpty(*tlsCertFlag, os.Getenv("TLS_CERT_FILE"))
	tlsKey := firstNonEmpty(*tlsKeyFlag, os.Getenv("TLS_KEY_FILE"))
	tlsEnabled := tlsCert != "" && tlsKey != ""

	var allowedOrigins []string
	if raw := firstNonEmpty(*originsFlag, os.Getenv("ALLOWED_ORIGINS")); raw != "" {
		for _, o := range strings.Split(raw, ",") {
			if trimmed := strings.TrimSpace(o); trimmed != "" {
				allowedOrigins = append(allowedOrigins, trimmed)
			}
		}
	}

	transport := "ws:// (PLAINTEXT)"
	if tlsEnabled {
		transport = "wss:// (TLS)"
	}

	log.Printf("==================================================")
	log.Printf("  VECTOR C2 MESH RELAY NODE                       ")
	log.Printf("==================================================")
	log.Printf("  Node ID   : %s", nodeID)
	log.Printf("  Listen    : :%d", port)
	log.Printf("  Transport : %s", transport)
	log.Printf("  Auth      : Ed25519 challenge/response per connection")
	log.Printf("  Payloads  : Opaque to this node (client-side E2EE)")
	log.Printf("==================================================")

	if !tlsEnabled {
		log.Printf("[NODE] WARNING: TLS is not configured. Envelope bodies stay encrypted,")
		log.Printf("[NODE] WARNING: but routing metadata is exposed to the network path.")
		log.Printf("[NODE] WARNING: Set TLS_CERT_FILE and TLS_KEY_FILE before any real use.")
	}

	meshNode := mesh.NewMeshNode(nodeID, port)
	relayServer := relay.NewRelayServer(allowedOrigins)

	mux := http.NewServeMux()
	mux.HandleFunc("/ping", meshNode.PingHandler)
	mux.HandleFunc("/peers", meshNode.PeersHandler)
	mux.HandleFunc("/announce", meshNode.AnnounceHandler)
	mux.HandleFunc("/ws", relayServer.HandleWS)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	})

	server := &http.Server{
		Addr:              fmt.Sprintf(":%d", port),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		// No ReadTimeout/WriteTimeout: they would apply to the hijacked
		// WebSocket connections too and sever long-lived field sessions. The
		// relay applies its own per-frame deadlines and a ping/pong keepalive.
		IdleTimeout: 120 * time.Second,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go meshNode.StartPeerReaper(ctx)

	go func() {
		log.Printf("[NODE] Server listening on :%d", port)
		var err error
		if tlsEnabled {
			err = server.ListenAndServeTLS(tlsCert, tlsKey)
		} else {
			err = server.ListenAndServe()
		}
		if err != nil && err != http.ErrServerClosed {
			log.Fatalf("[NODE] Server error: %v", err)
		}
	}()

	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, os.Interrupt, syscall.SIGTERM)

	<-stopChan
	log.Printf("[NODE] Shutting down mesh node daemon gracefully...")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()

	relayServer.Shutdown()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("[NODE] Shutdown error: %v", err)
	}

	log.Printf("[NODE] Mesh node offline.")
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
