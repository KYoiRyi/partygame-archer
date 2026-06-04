package main

import (
	"database/sql"
	"log"
	"os"

	_ "github.com/lib/pq"
)

var DB *sql.DB

func InitDB() {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		// Default local dev DSN
		dsn = "host=localhost user=postgres password=postgres dbname=partygame sslmode=disable"
	}

	var err error
	DB, err = sql.Open("postgres", dsn)
	if err != nil {
		log.Fatalf("DB open error: %v", err)
	}

	if err = DB.Ping(); err != nil {
		log.Printf("WARNING: Database not available (%v). Running without persistence.", err)
		DB = nil
		return
	}

	log.Println("Database connected successfully.")
	migrateDB()
}

func migrateDB() {
	schema := `
	CREATE TABLE IF NOT EXISTS accounts (
		id           SERIAL PRIMARY KEY,
		username     VARCHAR(32) UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		hero         VARCHAR(16) NOT NULL DEFAULT 'ranger',
		total_kills  INT NOT NULL DEFAULT 0,
		total_wins   INT NOT NULL DEFAULT 0,
		games_played INT NOT NULL DEFAULT 0,
		created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
	);

	CREATE TABLE IF NOT EXISTS game_sessions (
		id          SERIAL PRIMARY KEY,
		account_id  INT REFERENCES accounts(id),
		hero        VARCHAR(16),
		kills       INT DEFAULT 0,
		score       INT DEFAULT 0,
		won         BOOLEAN DEFAULT FALSE,
		played_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
	);
	`
	if _, err := DB.Exec(schema); err != nil {
		log.Printf("DB migrate error: %v", err)
	}
}

// SaveSessionStats persists kill/score data for a player after a game
func SaveSessionStats(accountID int, hero string, kills, score int, won bool) {
	if DB == nil {
		return
	}
	go func() {
		_, err := DB.Exec(`
			INSERT INTO game_sessions (account_id, hero, kills, score, won)
			VALUES ($1, $2, $3, $4, $5)
		`, accountID, hero, kills, score, won)
		if err != nil {
			log.Printf("SaveSessionStats error: %v", err)
			return
		}
		// Update account totals
		_, err = DB.Exec(`
			UPDATE accounts SET
				total_kills  = total_kills  + $2,
				total_wins   = total_wins   + $3,
				games_played = games_played + 1
			WHERE id = $1
		`, accountID, kills, map[bool]int{true: 1, false: 0}[won])
		if err != nil {
			log.Printf("UpdateAccountStats error: %v", err)
		}
	}()
}
