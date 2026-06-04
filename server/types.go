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
	Kills         int            `json:"kills"`
	Skills        map[string]int `json:"skills"` // SkillName -> current level (up to 5)
	Dead          bool           `json:"dead"`
	RespawnTimer  float64        `json:"respawn_timer"`
	ShootCooldown float64        `json:"-"`
	Moving        bool           `json:"moving"`
	MoveDir       Vector2        `json:"move_dir"`
	FireTimer     float64        `json:"fire_timer"`
	IceTimer      float64        `json:"ice_timer"`
	PoisonTimer   float64        `json:"poison_timer"`
	InvincibleTimer float64      `json:"invincible_timer"`
	GiantTimer    float64        `json:"giant_timer"`
	HasteTimer    float64        `json:"haste_timer"`
	DashTimer       float64        `json:"dash_timer"`
	DashCooldown    float64        `json:"-"`
	TeleportCooldown float64       `json:"-"`
	IsBot           bool           `json:"is_bot"`
	Hero          string         `json:"hero"`
	AccountID     int            `json:"-"` // DB account ID, -1 = guest
	Knockback     Vector2        `json:"-"`
	HasCrown      bool           `json:"has_crown"`

	// Send/Receive
	send chan []byte
	conn *websocket.Conn
	room *Room
}

type Projectile struct {
	ID        string   `json:"id"`
	OwnerID   string   `json:"owner_id"`
	OwnerType string   `json:"owner_type"` // "player"
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
	Type     string  `json:"type"` // "xp", "hp", "bomb", "mushroom", "star", "haste"
}

type Wall struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"w"`
	Height float64 `json:"h"`
}

type Portal struct {
	ID        string  `json:"id"`
	Position  Vector2 `json:"pos"`
	TargetPos Vector2 `json:"target_pos"`
	Radius    float64 `json:"radius"`
}

type HealZone struct {
	ID       string  `json:"id"`
	Position Vector2 `json:"pos"`
	Radius   float64 `json:"radius"`
	HealRate float64 `json:"heal_rate"`
}

type TrapZone struct {
	ID         string  `json:"id"`
	Position   Vector2 `json:"pos"`
	Radius     float64 `json:"radius"`
	DamageRate float64 `json:"damage_rate"`
}

type Crate struct {
	ID       string  `json:"id"`
	Position Vector2 `json:"pos"`
	HP       int     `json:"hp"`
	Radius   float64 `json:"radius"`
}

// Map Dimensions
const (
	MapWidth  = 3000.0
	MapHeight = 1200.0
)

// Network Message Structures
type ClientMessage struct {
	Type     string  `json:"type"` // "join", "move", "shoot", "select_skill", "chat", "update_hero"
	Name     string  `json:"name,omitempty"`
	X        float64 `json:"x,omitempty"`
	Y        float64 `json:"y,omitempty"`
	Angle    float64 `json:"angle,omitempty"`
	Skill    string  `json:"skill,omitempty"`
	ChatMsg  string  `json:"chat_msg,omitempty"`
	IsMoving bool    `json:"is_moving,omitempty"`
	Hero     string  `json:"hero,omitempty"`
}

type GameStateMessage struct {
	Players     []*Player     `json:"players"`
	Projectiles []*Projectile `json:"projectiles"`
	Gems        []*Gem        `json:"gems"`
	Crates      []*Crate      `json:"crates"`
	GlobalEvent string        `json:"global_event,omitempty"`
}

type RoomPlayerInfo struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Hero   string `json:"hero"`
	IsHost bool   `json:"is_host"`
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
	Portals       []Portal          `json:"portals,omitempty"`
	HealZones     []HealZone        `json:"heal_zones,omitempty"`
	TrapZones     []TrapZone        `json:"trap_zones,omitempty"`
	EffectType    string            `json:"effect_type,omitempty"`
	EffectX       float64           `json:"effect_x,omitempty"`
	EffectY       float64           `json:"effect_y,omitempty"`
	RoomPlayers   []RoomPlayerInfo  `json:"room_players,omitempty"`
	RoomState     string            `json:"room_state,omitempty"`
	HostID        string            `json:"host_id,omitempty"`
}
