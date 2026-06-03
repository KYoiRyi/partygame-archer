package main

import (
	"flag"
	"log"
	"net/http"
)

func main() {
	port := flag.String("port", "8080", "HTTP service port")
	flag.Parse()

	hub := NewHub()

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
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fileServer.ServeHTTP(w, r)
	})

	log.Printf("Multiplayer game backend listening on port %s", *port)
	log.Printf("Serving Godot web client from ./dist")
	
	if err := http.ListenAndServe(":"+*port, nil); err != nil {
		log.Fatalf("ListenAndServe error: %v", err)
	}
}
