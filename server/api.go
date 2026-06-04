package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// ---- Account Types ----

type RegisterRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type AuthResponse struct {
	OK        bool   `json:"ok"`
	Error     string `json:"error,omitempty"`
	Token     string `json:"token,omitempty"`
	AccountID int    `json:"account_id,omitempty"`
	Username  string `json:"username,omitempty"`
	Hero      string `json:"hero,omitempty"`
	TotalKills int   `json:"total_kills,omitempty"`
	TotalWins  int   `json:"total_wins,omitempty"`
	GamesPlayed int  `json:"games_played,omitempty"`
}

type UpdateHeroRequest struct {
	Token string `json:"token"`
	Hero  string `json:"hero"`
}

// ---- Simple in-memory token store ----
// (for production: use Redis or JWT)

var tokenStore = struct {
	tokens    map[string]int    // token -> accountID
	usernames map[string]string // token -> username
}{
	tokens:    make(map[string]int),
	usernames: make(map[string]string),
}

func generateToken() string {
	import_rand := make([]byte, 16)
	for i := range import_rand {
		import_rand[i] = byte(time.Now().UnixNano()%256) ^ byte(i*31+7)
	}
	return encodeHex(import_rand)
}

func encodeHex(b []byte) string {
	const hexChars = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, v := range b {
		out[i*2] = hexChars[v>>4]
		out[i*2+1] = hexChars[v&0x0f]
	}
	return string(out)
}

func GetAccountIDFromToken(token string) (int, bool) {
	id, ok := tokenStore.tokens[token]
	return id, ok
}

// ---- HTTP Handlers ----

func corsHandler(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}
		next(w, r)
	}
}

func jsonResponse(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// POST /api/register
func handleRegisterAccount(w http.ResponseWriter, r *http.Request) {
	if DB == nil {
		jsonResponse(w, 503, AuthResponse{Error: "Database not available"})
		return
	}
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonResponse(w, 400, AuthResponse{Error: "Invalid JSON"})
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if len(req.Username) < 2 || len(req.Username) > 20 {
		jsonResponse(w, 400, AuthResponse{Error: "Username must be 2-20 characters"})
		return
	}
	if len(req.Password) < 4 {
		jsonResponse(w, 400, AuthResponse{Error: "Password must be at least 4 characters"})
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		jsonResponse(w, 500, AuthResponse{Error: "Server error"})
		return
	}

	var accountID int
	err = DB.QueryRow(`
		INSERT INTO accounts (username, password_hash) VALUES ($1, $2)
		RETURNING id
	`, req.Username, string(hash)).Scan(&accountID)
	if err != nil {
		if strings.Contains(err.Error(), "unique") {
			jsonResponse(w, 409, AuthResponse{Error: "Username already taken"})
		} else {
			log.Printf("Register error: %v", err)
			jsonResponse(w, 500, AuthResponse{Error: "Server error"})
		}
		return
	}

	token := generateToken()
	tokenStore.tokens[token] = accountID
	tokenStore.usernames[token] = req.Username

	jsonResponse(w, 200, AuthResponse{
		OK: true, Token: token, AccountID: accountID, Username: req.Username, Hero: "ranger",
	})
}

// POST /api/login
func handleLogin(w http.ResponseWriter, r *http.Request) {
	if DB == nil {
		jsonResponse(w, 503, AuthResponse{Error: "Database not available. Registration is mandatory."})
		return
	}

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonResponse(w, 400, AuthResponse{Error: "Invalid JSON"})
		return
	}

	var (
		accountID   int
		passwordHash string
		hero        string
		totalKills  int
		totalWins   int
		gamesPlayed int
	)
	err := DB.QueryRow(`
		SELECT id, password_hash, hero, total_kills, total_wins, games_played
		FROM accounts WHERE username = $1
	`, req.Username).Scan(&accountID, &passwordHash, &hero, &totalKills, &totalWins, &gamesPlayed)

	if err == sql.ErrNoRows {
		jsonResponse(w, 401, AuthResponse{Error: "Invalid username or password"})
		return
	}
	if err != nil {
		jsonResponse(w, 500, AuthResponse{Error: "Server error"})
		return
	}

	if bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(req.Password)) != nil {
		jsonResponse(w, 401, AuthResponse{Error: "Invalid username or password"})
		return
	}

	token := generateToken()
	tokenStore.tokens[token] = accountID
	tokenStore.usernames[token] = req.Username

	jsonResponse(w, 200, AuthResponse{
		OK: true, Token: token, AccountID: accountID, Username: req.Username, Hero: hero,
		TotalKills: totalKills, TotalWins: totalWins, GamesPlayed: gamesPlayed,
	})
}

// POST /api/update_hero
func handleUpdateHero(w http.ResponseWriter, r *http.Request) {
	if DB == nil {
		jsonResponse(w, 200, AuthResponse{OK: true})
		return
	}
	var req UpdateHeroRequest
	json.NewDecoder(r.Body).Decode(&req)
	accountID, ok := GetAccountIDFromToken(req.Token)
	if !ok || accountID < 0 {
		jsonResponse(w, 401, AuthResponse{Error: "Unauthorized"})
		return
	}
	DB.Exec(`UPDATE accounts SET hero = $1 WHERE id = $2`, req.Hero, accountID)
	jsonResponse(w, 200, AuthResponse{OK: true})
}

// GET /api/profile?token=xxx
func handleProfile(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	accountID, ok := GetAccountIDFromToken(token)
	if !ok {
		jsonResponse(w, 401, AuthResponse{Error: "Unauthorized"})
		return
	}
	if DB == nil || accountID < 0 {
		username := tokenStore.usernames[token]
		jsonResponse(w, 200, AuthResponse{OK: true, AccountID: accountID, Username: username, Hero: "ranger"})
		return
	}

	var (
		username    string
		hero        string
		totalKills  int
		totalWins   int
		gamesPlayed int
	)
	DB.QueryRow(`
		SELECT username, hero, total_kills, total_wins, games_played
		FROM accounts WHERE id = $1
	`, accountID).Scan(&username, &hero, &totalKills, &totalWins, &gamesPlayed)

	jsonResponse(w, 200, AuthResponse{
		OK: true, AccountID: accountID, Username: username, Hero: hero,
		TotalKills: totalKills, TotalWins: totalWins, GamesPlayed: gamesPlayed,
	})
}

// GET /api/rooms
func handleListRooms(hub *Hub, w http.ResponseWriter, r *http.Request) {
	hub.mu.Lock()
	defer hub.mu.Unlock()

	type RoomInfo struct {
		ID          string `json:"id"`
		PlayerCount int    `json:"player_count"`
		MaxPlayers  int    `json:"max_players"`
	}
	rooms := []RoomInfo{}
	for _, room := range hub.rooms {
		room.mu.RLock()
		human := 0
		for _, p := range room.Players {
			if !p.IsBot { human++ }
		}
		room.mu.RUnlock()
		rooms = append(rooms, RoomInfo{
			ID:          room.ID,
			PlayerCount: human,
			MaxPlayers:  4,
		})
	}
	jsonResponse(w, 200, rooms)
}

// POST /api/rooms/create
func handleCreateRoom(hub *Hub, w http.ResponseWriter, r *http.Request) {
	hub.mu.Lock()
	defer hub.mu.Unlock()

	roomID := generateToken()[:8]
	room := NewRoom("room_" + roomID)
	hub.rooms["room_"+roomID] = room
	room.Start()

	type CreateRoomResponse struct {
		OK     bool   `json:"ok"`
		RoomID string `json:"room_id"`
	}
	jsonResponse(w, 200, CreateRoomResponse{OK: true, RoomID: "room_" + roomID})
}

func RegisterAPIRoutes(hub *Hub) {
	http.HandleFunc("/api/register", corsHandler(handleRegisterAccount))
	http.HandleFunc("/api/login", corsHandler(handleLogin))
	http.HandleFunc("/api/update_hero", corsHandler(handleUpdateHero))
	http.HandleFunc("/api/profile", corsHandler(handleProfile))
	http.HandleFunc("/api/rooms", corsHandler(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			handleCreateRoom(hub, w, r)
		} else {
			handleListRooms(hub, w, r)
		}
	}))
}
