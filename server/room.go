package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"math/rand"
	"sync"
	"time"
)

type Room struct {
	ID          string
	Players     map[string]*Player
	Projectiles map[string]*Projectile
	Gems        map[string]*Gem
	Walls       []Wall
	
	mu          sync.RWMutex
	register    chan *Player
	unregister  chan *Player
	inputChan   chan playerInput
	stopChan    chan struct{}
	
	blueBaseHP  float64
	redBaseHP   float64

	spawnTimer  float64
	gemTimer    float64
	entityIDSeq int64
}

type playerInput struct {
	playerID string
	msg      ClientMessage
}

func NewRoom(id string) *Room {
	r := &Room{
		ID:          id,
		Players:     make(map[string]*Player),
		Projectiles: make(map[string]*Projectile),
		Gems:        make(map[string]*Gem),
		Walls:       make([]Wall, 0),
		register:    make(chan *Player, 10),
		unregister:  make(chan *Player, 10),
		inputChan:   make(chan playerInput, 200),
		stopChan:    make(chan struct{}),
	}
	
	r.initMap()
	return r
}

func (r *Room) initMap() {
	// 1. Setup Walls/Obstacles
	// Middle wall barriers
	r.Walls = []Wall{
		// Central blockades
		{X: 1450, Y: 200, Width: 100, Height: 300},
		{X: 1450, Y: 700, Width: 100, Height: 300},
		// Left side blockades (protecting blue territory)
		{X: 800, Y: 150, Width: 80, Height: 250},
		{X: 800, Y: 800, Width: 80, Height: 250},
		// Right side blockades (protecting red territory)
		{X: 2120, Y: 150, Width: 80, Height: 250},
		{X: 2120, Y: 800, Width: 80, Height: 250},
		// Small cover blocks
		{X: 1100, Y: 550, Width: 120, Height: 100},
		{X: 1780, Y: 550, Width: 120, Height: 100},
	}

	// No towers in FFA Mode
	
	// Initial XP Gems
	for i := 0; i < 25; i++ {
		r.spawnGem("xp")
	}
	for i := 0; i < 5; i++ {
		r.spawnGem("hp")
	}

	r.fillRoomWithBots()
}

func (r *Room) Start() {
	ticker := time.NewTicker(33 * time.Millisecond) // ~30 FPS
	go func() {
		defer ticker.Stop()
		lastTick := time.Now()
		ticks := 0
		for {
			select {
			case <-r.stopChan:
				log.Printf("Room %s: stopping main loop", r.ID)
				return
			case p := <-r.register:
				r.handleRegister(p)
			case p := <-r.unregister:
				r.handleUnregister(p)
			case input := <-r.inputChan:
				r.handlePlayerInput(input.playerID, input.msg)
			case <-ticker.C:
				now := time.Now()
				dt := now.Sub(lastTick).Seconds()
				lastTick = now
				
				r.mu.Lock()
				r.tick(dt)
				r.mu.Unlock()

				ticks++
				if ticks%150 == 0 {
					r.mu.Lock()
					numPlayers := len(r.Players)
					numProjectiles := len(r.Projectiles)
					numGems := len(r.Gems)
					r.mu.Unlock()
					log.Printf("Room %s status: %d players, %d projectiles, %d gems. Loop is running smoothly.", r.ID, numPlayers, numProjectiles, numGems)
				}
			}
		}
	}()
}

func (r *Room) Stop() {
	close(r.stopChan)
}

func (r *Room) RegisterPlayer(p *Player) {
	r.register <- p
}

func (r *Room) UnregisterPlayer(p *Player) {
	r.unregister <- p
}

func (r *Room) HandleInput(playerID string, msg ClientMessage) {
	r.inputChan <- playerInput{playerID: playerID, msg: msg}
}

func initPlayerStats(p *Player, hero string) {
	p.Hero = hero
	p.Skills = make(map[string]int)
	p.Level = 1
	p.XP = 0
	p.XPToNext = 50
	p.Score = 0
	p.Dead = false

	switch hero {
	case "knight":
		p.MaxHP = 150.0
		p.HP = 150.0
		p.Speed = 240.0
		p.Skills[SkillHpBoost] = 1
	case "mage":
		p.MaxHP = 90.0
		p.HP = 90.0
		p.Speed = 260.0
		p.Skills[SkillFireArrow] = 1
	case "ranger":
		fallthrough
	default:
		p.Hero = "ranger"
		p.MaxHP = 100.0
		p.HP = 100.0
		p.Speed = 300.0
		p.Skills[SkillMultiShot] = 1
	}
}

func (r *Room) handleRegister(p *Player) {
	r.mu.Lock()
	defer r.mu.Unlock()

	log.Printf("Registering player ID: %s, Name: %s, Hero: %s", p.ID, p.Name, p.Hero)

	// Free-For-All: Everyone is their own team
	p.Team = p.ID

	// Kick an AI bot to free up a slot for the human player, keep max 10 players total
	var botToKick *Player
	for len(r.Players) >= 10 {
		for _, pl := range r.Players {
			if pl.IsBot {
				botToKick = pl
				break
			}
		}
		if botToKick != nil {
			delete(r.Players, botToKick.ID)
			botToKick = nil
		} else {
			break
		}
	}
	
	initPlayerStats(p, p.Hero)
	r.respawnPlayer(p)
	
	r.Players[p.ID] = p

	// Send init message
	initMsg := ServerMessage{
		Type:     "init",
		ClientID: p.ID,
		Team:     p.Team,
		Walls:    r.Walls,
	}
	if data, err := json.Marshal(initMsg); err == nil {
		select {
		case p.send <- data:
		default:
			log.Printf("Warning: failed to send init msg to player %s, channel full/closed", p.ID)
		}
	}

	// Chat broadcast join
	r.broadcastChat("system", fmt.Sprintf("%s (%s) joined the arena!", p.Name, p.Hero))
}

func (r *Room) handleUnregister(p *Player) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.Players[p.ID]; ok {
		delete(r.Players, p.ID)
		r.broadcastChat("system", fmt.Sprintf("%s has left the game.", p.Name))
		
		// Fill room with bots to keep the match busy
		r.fillRoomWithBots()
	}
}

func (r *Room) handlePlayerInput(playerID string, msg ClientMessage) {
	r.mu.Lock()
	defer r.mu.Unlock()

	p, ok := r.Players[playerID]
	if !ok || p.Dead {
		return
	}

	switch msg.Type {
	case "move":
		p.Moving = msg.IsMoving
		p.MoveDir = Vector2{X: msg.X, Y: msg.Y}
		p.Angle = msg.Angle
	case "dash":
		if p.DashCooldown <= 0 {
			p.DashTimer = 0.2
			p.DashCooldown = 2.0 // 2 seconds cooldown
		}
	case "shoot":
		r.playerShoot(p, msg.Angle)
	case "select_skill":
		r.playerSelectSkill(p, msg.Skill)
	case "chat":
		r.broadcastChat(p.Name, msg.ChatMsg)
	}
}

func (r *Room) respawnPlayer(p *Player) {
	p.Dead = false
	p.HP = p.MaxHP
	p.Position = Vector2{
		X: 100 + rand.Float64()*(MapWidth-200),
		Y: 100 + rand.Float64()*(MapHeight-200),
	}
}

func (r *Room) nextID(prefix string) string {
	r.entityIDSeq++
	return fmt.Sprintf("%s_%d", prefix, r.entityIDSeq)
}

func (r *Room) spawnGem(gemType string) {
	id := r.nextID("gem")
	
	// Spawn anywhere on the map evenly
	x := 100 + rand.Float64()*(MapWidth-200)
	y := 100 + rand.Float64()*(MapHeight-200)

	g := &Gem{
		ID:       id,
		Position: Vector2{X: x, Y: y},
		XPValue:  15,
		Type:     gemType,
	}
	if gemType == "hp" {
		g.XPValue = 0 // HP gem gives health instead of XP
	}
	r.Gems[id] = g
}


func (r *Room) playerShoot(p *Player, baseAngle float64) {
	if p.ShootCooldown > 0 {
		return
	}
	
	// Base Stats
	baseDamage := 15.0 + float64(p.Skills[SkillDamageBoost])*5
	atkSpeedLvl := float64(p.Skills[SkillAtkSpeed])
	
	baseCooldown := 0.25
	switch p.Hero {
	case "knight":
		baseCooldown = 0.40
	case "mage":
		baseCooldown = 0.35
	case "ranger":
		baseCooldown = 0.25
	}
	p.ShootCooldown = baseCooldown * math.Pow(0.85, atkSpeedLvl) // 15% CDR per level
	if p.IsBot {
		p.ShootCooldown += 1.0 + rand.Float64()*0.5 // Bots shoot much slower, +1~1.5s delay
	}

	projectileSpeed := 600.0
	life := 1.2 // seconds
	
	// Determine directions
	angles := []float64{baseAngle}
	
	// Multi Shot skill gives extra forward/side directions
	multiLvl := p.Skills[SkillMultiShot]
	if multiLvl > 0 {
		// Rear Shot (shoots 180 deg backward)
		rearLvl := p.Skills[SkillRearShot]
		if rearLvl > 0 {
			angles = append(angles, baseAngle+math.Pi)
		}
		
		// Diagonal Shot (shoots +- 45 degrees)
		diagLvl := p.Skills[SkillDiagonal]
		if diagLvl > 0 {
			angles = append(angles, baseAngle - math.Pi/4)
			angles = append(angles, baseAngle + math.Pi/4)
		}
		
		// Multi shot itself splits forward (e.g. +-10 degrees split)
		for i := 1; i <= multiLvl; i++ {
			spread := float64(i) * 0.15 // Rads
			angles = append(angles, baseAngle - spread)
			angles = append(angles, baseAngle + spread)
		}
	} else {
		// Even without multi_shot, check rear/diagonal if unlocked (rare, but supported)
		if p.Skills[SkillRearShot] > 0 {
			angles = append(angles, baseAngle+math.Pi)
		}
		if p.Skills[SkillDiagonal] > 0 {
			angles = append(angles, baseAngle - math.Pi/4)
			angles = append(angles, baseAngle + math.Pi/4)
		}
	}

	// Effects
	var effects []string
	if p.Skills[SkillFireArrow] > 0 {
		effects = append(effects, "fire")
	}
	if p.Skills[SkillIceArrow] > 0 {
		effects = append(effects, "ice")
	}
	if p.Skills[SkillPoisonArrow] > 0 {
		effects = append(effects, "poison")
	}

	bounces := p.Skills[SkillBouncing]
	pierces := p.Skills[SkillPiercing]

	for _, angle := range angles {
		projID := r.nextID("proj")
		dx := math.Cos(angle)
		dy := math.Sin(angle)
		
		r.Projectiles[projID] = &Projectile{
			ID:        projID,
			OwnerID:   p.ID,
			OwnerType: "player",
			Team:      p.Team,
			Position:  p.Position,
			Velocity:  Vector2{X: dx * projectileSpeed, Y: dy * projectileSpeed},
			Damage:    baseDamage,
			Life:      life,
			Bounces:   bounces,
			Pierces:   pierces,
			Effects:   effects,
		}
	}
}

func (r *Room) playerSelectSkill(p *Player, skill string) {
	// Verify skill is available
	p.Skills[skill]++
	
	// Apply instant stat changes
	switch skill {
	case SkillHpBoost:
		p.MaxHP += 30.0
		p.HP += 30.0
	case SkillSpeedBoost:
		p.Speed += 30.0
	}
	
	r.broadcastChat("system", fmt.Sprintf("%s upgraded skill: %s (Lvl %d)", p.Name, skill, p.Skills[skill]))
}

// 30Hz Game Tick logic
func (r *Room) tick(dt float64) {
	r.spawnTimer += dt
	r.gemTimer += dt
	
	// Spawn XP/HP Gems if below cap
	if r.gemTimer >= 4.0 {
		if len(r.Gems) < 50 {
			r.spawnGem("xp")
			randVal := rand.Float64()
			if randVal < 0.10 {
				r.spawnGem("hp")
			} else if randVal < 0.15 {
				r.spawnGem("bomb")
			} else if randVal < 0.20 {
				r.spawnGem("mushroom")
			} else if randVal < 0.25 {
				r.spawnGem("star")
			} else if randVal < 0.30 {
				r.spawnGem("haste")
			}
		}
		r.gemTimer = 0.0
	}

	// Update Players
	for _, p := range r.Players {
		if p.Dead {
			p.RespawnTimer -= dt
			if p.RespawnTimer <= 0 {
				r.respawnPlayer(p)
			}
			continue
		}
		
		// Tick elemental debuffs
		if p.FireTimer > 0 {
			p.FireTimer -= dt
			r.damagePlayer(p, 12.0 * dt, "")
		}
		if p.PoisonTimer > 0 {
			p.PoisonTimer -= dt
			r.damagePlayer(p, 6.0 * dt, "")
		}
		
		if p.InvincibleTimer > 0 {
			p.InvincibleTimer -= dt
		}
		if p.GiantTimer > 0 {
			p.GiantTimer -= dt
		}
		if p.HasteTimer > 0 {
			p.HasteTimer -= dt
		}
		if p.DashTimer > 0 {
			p.DashTimer -= dt
		}
		if p.DashCooldown > 0 {
			p.DashCooldown -= dt
		}
		
		speedMultiplier := 1.0
		if p.IceTimer > 0 {
			p.IceTimer -= dt
			speedMultiplier = 0.55
		}
		if p.HasteTimer > 0 {
			speedMultiplier *= 1.8
		}
		if p.GiantTimer > 0 {
			speedMultiplier *= 0.6 // Giant is slower
		}
		if p.DashTimer > 0 {
			speedMultiplier *= 5.0 // Dash burst speed
		}
		
		if p.ShootCooldown > 0 {
			p.ShootCooldown -= dt
		}

		if p.IsBot {
			r.updateBotAI(p, dt)
		}
		
		// Update position
		isDashing := p.DashTimer > 0
		if p.Moving || isDashing {
			moveX, moveY := p.MoveDir.X, p.MoveDir.Y
			if isDashing && moveX == 0 && moveY == 0 {
				moveX = math.Cos(p.Angle)
				moveY = math.Sin(p.Angle)
			}
			p.Position.X += moveX * p.Speed * speedMultiplier * dt
			p.Position.Y += moveY * p.Speed * speedMultiplier * dt
			
			// Stay within borders
			if p.Position.X < 20 { p.Position.X = 20 }
			if p.Position.X > MapWidth-20 { p.Position.X = MapWidth-20 }
			if p.Position.Y < 20 { p.Position.Y = 20 }
			if p.Position.Y > MapHeight-20 { p.Position.Y = MapHeight-20 }
			
			// Resolve walls
			r.resolveWallCollisions(&p.Position, 25.0)
		}
		
		// If standing still, Auto-Shoot nearest enemy in range
		if !p.Moving && p.ShootCooldown <= 0 {
			nearestEnemy, _ := r.findNearestEnemy(p.Position, p.Team, 500.0)
			if nearestEnemy != nil {
				angle := math.Atan2(nearestEnemy.Y - p.Position.Y, nearestEnemy.X - p.Position.X)
				r.playerShoot(p, angle)
			}
		}
	}

	// Update Projectiles
	for pID, p := range r.Projectiles {
		p.Life -= dt
		if p.Life <= 0 {
			delete(r.Projectiles, pID)
			continue
		}
		
		// Move projectile
		p.Position.X += p.Velocity.X * dt
		p.Position.Y += p.Velocity.Y * dt
		
		// Collide with boundary walls
		if p.Position.X < 5 || p.Position.X > MapWidth-5 || p.Position.Y < 5 || p.Position.Y > MapHeight-5 {
			if p.Bounces > 0 {
				p.Bounces--
				if p.Position.X < 5 || p.Position.X > MapWidth-5 {
					p.Velocity.X = -p.Velocity.X
				} else {
					p.Velocity.Y = -p.Velocity.Y
				}
			} else {
				delete(r.Projectiles, pID)
				continue
			}
		}
		
		// Collide with physical obstacle walls
		wallHit := false
		for _, w := range r.Walls {
			if p.Position.X >= w.X && p.Position.X <= w.X+w.Width && p.Position.Y >= w.Y && p.Position.Y <= w.Y+w.Height {
				wallHit = true
				if p.Bounces > 0 {
					p.Bounces--
					// Reflect velocity depending on which side it hit
					// Find closest side
					leftDist := math.Abs(p.Position.X - w.X)
					rightDist := math.Abs(p.Position.X - (w.X + w.Width))
					topDist := math.Abs(p.Position.Y - w.Y)
					bottomDist := math.Abs(p.Position.Y - (w.Y + w.Height))
					
					min := math.Min(math.Min(leftDist, rightDist), math.Min(topDist, bottomDist))
					if min == leftDist || min == rightDist {
						p.Velocity.X = -p.Velocity.X
					} else {
						p.Velocity.Y = -p.Velocity.Y
					}
					// Nudge out of wall
					p.Position.X += p.Velocity.X * 0.05
					p.Position.Y += p.Velocity.Y * 0.05
				} else {
					delete(r.Projectiles, pID)
					break
				}
			}
		}
		if wallHit {
			continue
		}

		// Collide with enemies (Towers, Minions, Players)
		r.checkProjectileHit(p)
	}

	// Update Gems collection by Players
	for gID, g := range r.Gems {
		for _, p := range r.Players {
			if p.Dead { continue }
			dx := p.Position.X - g.Position.X
			dy := p.Position.Y - g.Position.Y
			dist := math.Sqrt(dx*dx + dy*dy)
			
			// Grab radius
			if dist < 35.0 {
				r.collectGem(p, g)
				delete(r.Gems, gID)
				break
			}
		}
	}

	// Broadcast updated states to all players
	r.sendStateToAll()
}

func (r *Room) collectGem(p *Player, g *Gem) {
	switch g.Type {
	case "hp":
		p.HP += 30.0
		if p.HP > p.MaxHP {
			p.HP = p.MaxHP
		}
		return
	case "bomb":
		r.triggerExplosion(g.Position.X, g.Position.Y, 200.0, 150.0, p.Team)
		r.broadcastChat("system", fmt.Sprintf("💣 %s picked up a BOMB! BOOM!", p.Name))
		return
	case "mushroom":
		p.GiantTimer = 10.0
		p.MaxHP += 50.0
		p.HP += 50.0
		r.broadcastChat("system", fmt.Sprintf("🍄 %s grew GIANT!", p.Name))
		return
	case "star":
		p.InvincibleTimer = 8.0
		r.broadcastChat("system", fmt.Sprintf("⭐ %s became INVINCIBLE!", p.Name))
		return
	case "haste":
		p.HasteTimer = 8.0
		r.broadcastChat("system", fmt.Sprintf("⚡ %s got a HASTE boost!", p.Name))
		return
	}
	
	// Collect XP
	p.XP += g.XPValue
	if p.XP >= p.XPToNext {
		p.XP -= p.XPToNext
		p.Level++
		p.XPToNext = p.Level*50 + 50
		p.MaxHP += 10.0
		p.HP += 10.0 // Heal slightly on level up
		if p.HP > p.MaxHP {
			p.HP = p.MaxHP
		}
		
		// Send level up skills choices (random 3)
		r.triggerLevelUp(p)
	}
}

func (r *Room) triggerExplosion(x, y, radius, damage float64, safeTeam string) {
	// Broadcast effect to clients
	r.broadcastEffect("bomb", x, y)
	
	// Damage players
	for _, p := range r.Players {
		if p.Dead || p.Team == safeTeam || p.InvincibleTimer > 0 {
			continue
		}
		dx := p.Position.X - x
		dy := p.Position.Y - y
		if math.Sqrt(dx*dx + dy*dy) <= radius {
			r.damagePlayer(p, damage, "")
		}
	}
}

func (r *Room) broadcastEffect(effectType string, x, y float64) {
	msg := ServerMessage{
		Type:       "effect",
		EffectType: effectType,
		EffectX:    x,
		EffectY:    y,
	}
	if data, err := json.Marshal(msg); err == nil {
		for _, p := range r.Players {
			select {
			case p.send <- data:
			default:
			}
		}
	}
}

func (r *Room) triggerLevelUp(p *Player) {
	if p.IsBot {
		skillsPool := []string{
			SkillMultiShot, SkillDiagonal, SkillRearShot, SkillPiercing,
			SkillBouncing, SkillFireArrow, SkillIceArrow, SkillPoisonArrow,
			SkillHpBoost, SkillSpeedBoost, SkillAtkSpeed, SkillDamageBoost,
		}
		selectedSkill := skillsPool[rand.Intn(len(skillsPool))]
		r.playerSelectSkill(p, selectedSkill)
		log.Printf("Bot %s (level %d) auto-selected skill: %s", p.Name, p.Level, selectedSkill)
		return
	}

	skillsPool := []string{
		SkillMultiShot, SkillDiagonal, SkillRearShot, SkillPiercing,
		SkillBouncing, SkillFireArrow, SkillIceArrow, SkillPoisonArrow,
		SkillHpBoost, SkillSpeedBoost, SkillAtkSpeed, SkillDamageBoost,
	}
	
	// Select 3 unique random choices
	rand.Shuffle(len(skillsPool), func(i, j int) {
		skillsPool[i], skillsPool[j] = skillsPool[j], skillsPool[i]
	})
	
	choices := skillsPool[:3]
	
	msg := ServerMessage{
		Type:         "levelup",
		SkillChoices: choices,
	}
	
	if data, err := json.Marshal(msg); err == nil {
		select {
		case p.send <- data:
		default:
			log.Printf("Warning: failed to send levelup choices to player %s, channel full/closed", p.ID)
		}
	}
}

func (r *Room) checkProjectileHit(proj *Projectile) {
	targetHit := false
	
	// Hit Players
	for _, enemy := range r.Players {
		if enemy.Dead || enemy.Team == proj.Team {
			continue
		}
		if enemy.InvincibleTimer > 0 {
			continue // Invincible to projectiles
		}
		dx := proj.Position.X - enemy.Position.X
		dy := proj.Position.Y - enemy.Position.Y
		dist := math.Sqrt(dx*dx + dy*dy)
		if dist < 25.0 {
			r.damagePlayer(enemy, proj.Damage, proj.OwnerID)
			r.applyProjectileEffects(proj.Effects, enemy)
			targetHit = true
			break
		}
	}

	if targetHit {
		if proj.Pierces > 0 {
			proj.Pierces--
		} else {
			delete(r.Projectiles, proj.ID)
		}
	}
}

func (r *Room) damagePlayer(p *Player, dmg float64, attackerID string) {
	if p.Dead || p.InvincibleTimer > 0 {
		return
	}
	p.HP -= dmg
	if p.HP <= 0 {
		p.HP = 0
		p.Dead = true
		p.RespawnTimer = 5.0 // 5 seconds respawn time
		
		// Find attacker name
		attackerName := "AI / Tower"
		if att, ok := r.Players[attackerID]; ok {
			attackerName = att.Name
			att.Score += 100
			
			// Level up boost for killing a player
			att.XP += 100
			if att.XP >= att.XPToNext {
				att.XP -= att.XPToNext
				att.Level++
				att.XPToNext = att.Level*50 + 50
				att.MaxHP += 10.0
				att.HP = att.MaxHP
				r.triggerLevelUp(att)
			}
		}
		
		r.broadcastKillFeed(attackerName, p.Name)
	}
}

func (r *Room) damageEntityAt(x, y float64, dmg float64, team string, attackerType string) {
	// Melee / Splash damage
	for _, p := range r.Players {
		if p.Dead || p.Team == team {
			continue
		}
		dx := p.Position.X - x
		dy := p.Position.Y - y
		if math.Sqrt(dx*dx + dy*dy) < 30.0 {
			r.damagePlayer(p, dmg, "")
			return
		}
	}
}

func (r *Room) findNearestEnemy(pos Vector2, team string, rangeLimit float64) (*Vector2, float64) {
	var nearest *Vector2
	minDistSq := rangeLimit * rangeLimit
	
	// Check Players
	for _, p := range r.Players {
		if p.Dead || p.Team == team {
			continue
		}
		if p.InvincibleTimer > 0 {
			continue // Don't target invincible players automatically
		}
		dx := p.Position.X - pos.X
		dy := p.Position.Y - pos.Y
		distSq := dx*dx + dy*dy
		if distSq < minDistSq {
			minDistSq = distSq
			nearest = &Vector2{X: p.Position.X, Y: p.Position.Y}
		}
	}
	
	if nearest != nil {
		return nearest, math.Sqrt(minDistSq)
	}
	return nil, rangeLimit
}



func (r *Room) resolveWallCollisions(pos *Vector2, radius float64) {
	for _, w := range r.Walls {
		closestX := math.Max(w.X, math.Min(pos.X, w.X+w.Width))
		closestY := math.Max(w.Y, math.Min(pos.Y, w.Y+w.Height))
		
		distX := pos.X - closestX
		distY := pos.Y - closestY
		distSq := distX*distX + distY*distY
		
		if distSq < radius*radius {
			dist := math.Sqrt(distSq)
			if dist == 0 {
				pos.X -= radius
				continue
			}
			overlap := radius - dist
			pos.X += (distX / dist) * overlap
			pos.Y += (distY / dist) * overlap
		}
	}
}

func (r *Room) endGame(winner string) {
	msg := ServerMessage{
		Type:       "game_over",
		WinnerTeam: winner,
	}
	if data, err := json.Marshal(msg); err == nil {
		r.broadcast(data)
	}
	
	// Reset Map after 10 seconds delay
	go func() {
		time.Sleep(10 * time.Second)
		r.mu.Lock()
		defer r.mu.Unlock()
		
		r.Projectiles = make(map[string]*Projectile)
		r.Gems = make(map[string]*Gem)
		
		r.initMap()
		
		for _, p := range r.Players {
			p.Skills = make(map[string]int)
			p.Level = 1
			p.XP = 0
			p.XPToNext = 50
			p.MaxHP = 100
			p.HP = 100
			p.Speed = 280.0
			p.Score = 0
			r.respawnPlayer(p)
		}
		r.broadcastChat("system", "A new match has started! Go fight!")
	}()
}

func (r *Room) broadcastChat(sender, chatMsg string) {
	msg := ServerMessage{
		Type:       "chat",
		SenderName: sender,
		ChatMsg:    chatMsg,
	}
	if data, err := json.Marshal(msg); err == nil {
		r.broadcast(data)
	}
}

func (r *Room) broadcastKillFeed(killer, victim string) {
	msg := ServerMessage{
		Type:       "kill_feed",
		KillerName: killer,
		VictimName: victim,
	}
	if data, err := json.Marshal(msg); err == nil {
		r.broadcast(data)
	}
}

func (r *Room) sendStateToAll() {
	state := &GameStateMessage{
		Players:     make([]*Player, 0, len(r.Players)),
		Projectiles: make([]*Projectile, 0, len(r.Projectiles)),
		Gems:        make([]*Gem, 0, len(r.Gems)),
	}

	for _, p := range r.Players {
		state.Players = append(state.Players, p)
	}
	for _, pr := range r.Projectiles {
		state.Projectiles = append(state.Projectiles, pr)
	}
	for _, g := range r.Gems {
		state.Gems = append(state.Gems, g)
	}

	msg := ServerMessage{
		Type:  "state",
		State: state,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	r.broadcast(data)
}

func (r *Room) broadcast(data []byte) {
	for _, p := range r.Players {
		select {
		case p.send <- data:
		default:
			// Buffer full, drop client or skip
		}
	}
}

func (r *Room) applyProjectileEffects(effects []string, playerTarget *Player) {
	for _, eff := range effects {
		if playerTarget != nil {
			switch eff {
			case "fire":
				playerTarget.FireTimer = 3.0
			case "ice":
				playerTarget.IceTimer = 2.5
			case "poison":
				playerTarget.PoisonTimer = 5.0
			}
		}
	}
}

func (r *Room) fillRoomWithBots() {
	blueCount, redCount := 0, 0
	for _, pl := range r.Players {
		if pl.Team == "blue" {
			blueCount++
		} else {
			redCount++
		}
	}
	
	// Ensure at least 3 players (humans + bots) per team
	for blueCount < 3 {
		r.spawnBot("blue")
		blueCount++
	}
	for redCount < 3 {
		r.spawnBot("red")
		redCount++
	}
}

func (r *Room) spawnBot(team string) {
	botNames := []string{"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa"}
	name := fmt.Sprintf("Bot_%s", botNames[rand.Intn(len(botNames))])
	botID := r.nextID("bot")
	
	p := &Player{
		ID:    botID,
		Name:  name,
		Team:  team,
		IsBot: true,
	}
	
	heroes := []string{"ranger", "knight", "mage"}
	randomHero := heroes[rand.Intn(len(heroes))]
	initPlayerStats(p, randomHero)
	
	r.respawnPlayer(p)
	r.Players[botID] = p
	
	log.Printf("Spawned Bot ID: %s, Name: %s, Team: %s, Hero: %s", botID, name, team, randomHero)
}

func (r *Room) updateBotAI(p *Player, dt float64) {
	// 1. Aggression: find nearest enemy in 650 range
	target, dist := r.findNearestEnemy(p.Position, p.Team, 650.0)
	
	var moveDir Vector2
	
	if target != nil {
		dx := target.X - p.Position.X
		dy := target.Y - p.Position.Y
		angle := math.Atan2(dy, dx)
		p.Angle = angle
		
		// Shoot if ready
		if p.ShootCooldown <= 0 {
			r.playerShoot(p, angle)
		}
		
		// Movement: kite archer style
		if dist > 380.0 {
			// Move closer
			moveDir = Vector2{X: dx / dist, Y: dy / dist}
		} else if dist < 220.0 {
			// Retreat
			moveDir = Vector2{X: -dx / dist, Y: -dy / dist}
		} else {
			// Strafe perpendicularly with sideways drift
			moveDir = Vector2{X: -dy / dist, Y: dx / dist}
			
			// Perpendicular drift noise
			moveDir.X += (rand.Float64() - 0.5) * 0.35
			moveDir.Y += (rand.Float64() - 0.5) * 0.35
			
			d := math.Sqrt(moveDir.X*moveDir.X + moveDir.Y*moveDir.Y)
			if d > 0 {
				moveDir.X /= d
				moveDir.Y /= d
			}
		}
	} else {
		// 2. Searching for gems
		var nearestGem *Gem
		minDist := 100000.0
		for _, g := range r.Gems {
			dx := g.Position.X - p.Position.X
			dy := g.Position.Y - p.Position.Y
			dSq := dx*dx + dy*dy
			if dSq < minDist {
				minDist = dSq
				nearestGem = g
			}
		}

		if nearestGem != nil {
			dx := nearestGem.Position.X - p.Position.X
			dy := nearestGem.Position.Y - p.Position.Y
			d := math.Sqrt(dx*dx + dy*dy)
			if d > 10 {
				moveDir = Vector2{X: dx / d, Y: dy / d}
				p.Angle = math.Atan2(dy, dx)
			}
		} else {
			// Wander randomly
			moveDir = Vector2{
				X: (rand.Float64() - 0.5),
				Y: (rand.Float64() - 0.5),
			}
		}
	}
	
	p.Moving = moveDir.X != 0 || moveDir.Y != 0
	p.MoveDir = moveDir
}
