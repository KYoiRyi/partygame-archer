package main

import (
	"github.com/gorilla/websocket"
)

// Skills that players can choose when leveling up
const (
	SkillMultiShot   = "multi_shot"   // Extra arrows (front + back + sides)
	SkillDiagonal    = "diagonal"     // Shoot diagonally
	SkillRearShot    = "rear_shot"     // Shoot backward
	SkillPiercing    = "piercing"      // Arrow pierces enemies
	SkillBouncing    = "bouncing"      // Arrow bounces off walls
	SkillFireArrow   = "fire_arrow"    // Burn damage over time
	SkillIceArrow    = "ice_arrow"     // Slow movement speed
	SkillPoisonArrow = "poison_arrow"   // Poison damage over time
	SkillHpBoost     = "hp_boost"      // Increase Max HP
	SkillSpeedBoost  = "speed_boost"   // Increase movement speed
	SkillAtkSpeed    = "atk_speed"     // Increase attack speed
	SkillDamageBoost = "damage_boost"  // Increase damage
)

type Vector2 struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

type Player struct {
	ID            string         `json:"id"`
	Name          string         `json:"name"`
	Team          string         `json:"team"` // "blue" or "red"
	Position      Vector2        `json:"pos"`
	Angle         float64        `json:"angle"` // Aiming / facing angle
	Speed         float64        `json:"speed"`
	HP            float64        `json:"hp"`
	MaxHP         float64        `json:"max_hp"`
	Level         int            `json:"level"`
	XP            int            `json:"xp"`
	XPToNext      int            `json:"xp_to_next"`
	Score         int            `json:"score"`
	Skills        map[string]int `json:"skills"` // SkillName -> current level (up to 5)
	Dead          bool           `json:"dead"`
	RespawnTimer  float64        `json:"respawn_timer"`
	ShootCooldown float64        `json:"-"`
	Moving        bool           `json:"moving"`
	MoveDir       Vector2        `json:"move_dir"`
	FireTimer     float64        `json:"fire_timer"`
	IceTimer      float64        `json:"ice_timer"`
	PoisonTimer   float64        `json:"poison_timer"`
	IsBot         bool           `json:"is_bot"`

	// Send/Receive
	send chan []byte
	conn *websocket.Conn
	room *Room
}

type Minion struct {
	ID       string  `json:"id"`
	Team     string  `json:"team"` // "blue" or "red"
	Position Vector2 `json:"pos"`
	HP       float64 `json:"hp"`
	MaxHP    float64 `json:"max_hp"`
	Speed    float64 `json:"speed"`
	TargetX  float64 `json:"target_x"`
	TargetY  float64 `json:"target_y"`
	State    string  `json:"state"` // "march", "attack"
	Cooldown float64 `json:"-"`
	FireTimer     float64 `json:"fire_timer"`
	IceTimer      float64 `json:"ice_timer"`
	PoisonTimer   float64 `json:"poison_timer"`
}

type Tower struct {
	ID       string  `json:"id"`
	Team     string  `json:"team"` // "blue" or "red"
	Position Vector2 `json:"pos"`
	HP       float64 `json:"hp"`
	MaxHP    float64 `json:"max_hp"`
	IsBase   bool    `json:"is_base"`
	Cooldown float64 `json:"-"`
}

type Projectile struct {
	ID        string   `json:"id"`
	OwnerID   string   `json:"owner_id"`
	OwnerType string   `json:"owner_type"` // "player", "minion", "tower"
	Team      string   `json:"team"`
	Position  Vector2  `json:"pos"`
	Velocity  Vector2  `json:"vel"`
	Damage    float64  `json:"damage"`
	Life      float64  `json:"life"`
	Bounces   int      `json:"bounces"`
	Pierces   int      `json:"pierces"`
	Effects   []string `json:"effects"`
}

type Gem struct {
	ID       string  `json:"id"`
	Position Vector2 `json:"pos"`
	XPValue  int     `json:"xp"`
	Type     string  `json:"type"` // "xp", "hp"
}

type Wall struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"w"`
	Height float64 `json:"h"`
}

// Map Dimensions
const (
	MapWidth  = 3000.0
	MapHeight = 1200.0
)

// Network Message Structures
type ClientMessage struct {
	Type     string  `json:"type"` // "join", "move", "shoot", "select_skill", "chat"
	Name     string  `json:"name,omitempty"`
	X        float64 `json:"x,omitempty"`
	Y        float64 `json:"y,omitempty"`
	Angle    float64 `json:"angle,omitempty"`
	Skill    string  `json:"skill,omitempty"`
	ChatMsg  string  `json:"chat_msg,omitempty"`
	IsMoving bool    `json:"is_moving,omitempty"`
}

type GameStateMessage struct {
	Players     []*Player     `json:"players"`
	Minions     []*Minion     `json:"minions"`
	Towers      []*Tower      `json:"towers"`
	Projectiles []*Projectile `json:"projectiles"`
	Gems        []*Gem        `json:"gems"`
}

type ServerMessage struct {
	Type          string            `json:"type"` // "init", "state", "levelup", "game_over", "chat", "kill_feed"
	ClientID      string            `json:"client_id,omitempty"`
	Team          string            `json:"team,omitempty"`
	State         *GameStateMessage `json:"state,omitempty"`
	SkillChoices  []string          `json:"skill_choices,omitempty"`
	WinnerTeam    string            `json:"winner_team,omitempty"`
	ChatMsg       string            `json:"chat_msg,omitempty"`
	SenderName    string            `json:"sender_name,omitempty"`
	KillerName    string            `json:"killer_name,omitempty"`
	VictimName    string            `json:"victim_name,omitempty"`
	Walls         []Wall            `json:"walls,omitempty"`
}
