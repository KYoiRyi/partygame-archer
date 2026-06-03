package main

import (
	"fmt"
	"sync"
)

type Hub struct {
	rooms map[string]*Room
	mu    sync.Mutex
}

func NewHub() *Hub {
	return &Hub{
		rooms: make(map[string]*Room),
	}
}

func (h *Hub) GetAvailableRoom() *Room {
	h.mu.Lock()
	defer h.mu.Unlock()

	// Look for an existing room that has space (< 10 players)
	for _, r := range h.rooms {
		r.mu.RLock()
		playerCount := len(r.Players)
		r.mu.RUnlock()
		
		if playerCount < 10 {
			return r
		}
	}

	// If no rooms have space, spawn a new room instance
	roomID := fmt.Sprintf("room_%d", len(h.rooms)+1)
	room := NewRoom(roomID)
	h.rooms[roomID] = room
	room.Start()
	
	return room
}
