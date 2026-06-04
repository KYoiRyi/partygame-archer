package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"flag"
	"log"
	"math/big"
	"net/http"
	"time"
)

func getSelfSignedTLSConfig() (*tls.Config, error) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}

	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"Archer MOBA LAN Server"},
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return nil, err
	}

	cert := tls.Certificate{
		Certificate: [][]byte{derBytes},
		PrivateKey:  priv,
	}

	return &tls.Config{Certificates: []tls.Certificate{cert}}, nil
}

func main() {
	port := flag.String("port", "8080", "HTTP service port")
	ssl := flag.Bool("ssl", false, "Use self-signed SSL/TLS for secure contexts (HTTPS) in LAN")
	flag.Parse()

	hub := NewHub()

	// Initialize database (graceful if unavailable)
	InitDB()

	// Register REST API routes (auth, rooms, profile)
	RegisterAPIRoutes(hub)

	// 1. WebSocket endpoint for game logic
	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		ServeWs(hub, w, r)
	})

	// 2. Static file serving with SharedArrayBuffer Headers (COOP / COEP)
	// These headers are mandatory for Godot 4.x exported Web Assembly to load
	fileServer := http.FileServer(http.Dir("./dist"))
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
		w.Header().Set("Cross-Origin-Embedder-Policy", "require-corp")
		w.Header().Set("Cross-Origin-Resource-Policy", "cross-origin")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
		w.Header().Set("Pragma", "no-cache")
		fileServer.ServeHTTP(w, r)
	})

	if *ssl {
		tlsConfig, err := getSelfSignedTLSConfig()
		if err != nil {
			log.Fatalf("Failed to generate self-signed TLS config: %v", err)
		}
		
		log.Printf("Multiplayer game backend listening on HTTPS port %s (SSL enabled)", *port)
		log.Printf("Serving Godot web client from ./dist")
		
		server := &http.Server{
			Addr:      ":" + *port,
			TLSConfig: tlsConfig,
		}
		if err := server.ListenAndServeTLS("", ""); err != nil {
			log.Fatalf("ListenAndServeTLS error: %v", err)
		}
	} else {
		log.Printf("Multiplayer game backend listening on HTTP port %s", *port)
		log.Printf("Serving Godot web client from ./dist")
		
		if err := http.ListenAndServe(":"+*port, nil); err != nil {
			log.Fatalf("ListenAndServe error: %v", err)
		}
	}
}
