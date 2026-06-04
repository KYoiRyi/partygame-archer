package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

const (
	writeWait      = 10 * time.Second
	pongWait       = 60 * time.Second
	pingPeriod     = (pongWait * 9) / 10
	maxMessageSize = 4096
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  2048,
	WriteBufferSize: 2048,
	CheckOrigin: func(r *http.Request) bool {
		return true // Web-compatible game server upgrades any origin
	},
}

func (p *Player) readPump(room *Room) {
	defer func() {
		room.UnregisterPlayer(p)
		close(p.send)
		p.conn.Close()
	}()

	p.conn.SetReadLimit(maxMessageSize)
	p.conn.SetReadDeadline(time.Now().Add(pongWait))
	p.conn.SetPongHandler(func(string) error {
		p.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, message, err := p.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("error: %v", err)
			}
			break
		}

		var msg ClientMessage
		if err := json.Unmarshal(message, &msg); err != nil {
			log.Printf("invalid client message JSON: %v", err)
			continue
		}

		room.HandleInput(p.ID, msg)
	}
}

func (p *Player) writePump(conn *websocket.Conn) {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		conn.Close()
	}()

	for {
		select {
		case message, ok := <-p.send:
			conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			w, err := conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			w.Write(message)

			// Add queued state updates to this single packet transmission
			n := len(p.send)
			for i := 0; i < n; i++ {
				w.Write([]byte{'\n'})
				w.Write(<-p.send)
			}

			if err := w.Close(); err != nil {
				return
			}
		case <-ticker.C:
			conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// ServeWs handles websocket requests from the client.
func ServeWs(hub *Hub, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println(err)
		return
	}

	// 1. Parse player details from query params
	token := r.URL.Query().Get("token")
	name := r.URL.Query().Get("name")
	heroCode := r.URL.Query().Get("hero")
	roomID := r.URL.Query().Get("room_id")

	// Resolve name and accountID from token
	accountID := -1
	if token != "" {
		if id, ok := GetAccountIDFromToken(token); ok {
			accountID = id
			if uname, ok2 := tokenStore.usernames[token]; ok2 && name == "" {
				name = uname
			}
		}
	}
	if name == "" {
		name = "Archer"
	}

	// Map heroCode string to hero class name
	heroClass := "ranger"
	switch heroCode {
	case "1":
		heroClass = "knight"
	case "2":
		heroClass = "mage"
	case "3":
		heroClass = "assassin"
	case "4":
		heroClass = "sniper"
	}

	playerID := fmt.Sprintf("player_%d", time.Now().UnixNano())

	p := &Player{
		ID:        playerID,
		Name:      name,
		send:      make(chan []byte, 256),
		conn:      conn,
		Hero:      heroClass,
		AccountID: accountID,
	}

	// 2. Fetch or join a game room
	var room *Room
	if roomID != "" {
		hub.mu.Lock()
		room = hub.rooms[roomID]
		hub.mu.Unlock()
	}
	if room == nil {
		room = hub.GetAvailableRoom()
	}
	p.room = room

	room.RegisterPlayer(p)

	// 3. Start pumps
	go p.writePump(conn)
	go p.readPump(room)
}
