package main

import (
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
	"sync"
	"time"
)

type Room struct {
	ID          string
	Players     map[string]*Player
	Minions     map[string]*Minion
	Towers      map[string]*Tower
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
	blueTowerHP float64
	redTowerHP  float64

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
		Minions:     make(map[string]*Minion),
		Towers:      make(map[string]*Tower),
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

	// 2. Setup Towers
	// Blue Team
	r.Towers["blue_base"] = &Tower{
		ID:       "blue_base",
		Team:     "blue",
		Position: Vector2{X: 150, Y: 600},
		HP:       5000,
		MaxHP:    5000,
		IsBase:   true,
	}
	r.Towers["blue_tower1"] = &Tower{
		ID:       "blue_tower1",
		Team:     "blue",
		Position: Vector2{X: 850, Y: 600},
		HP:       2500,
		MaxHP:    2500,
		IsBase:   false,
	}

	// Red Team
	r.Towers["red_base"] = &Tower{
		ID:       "red_base",
		Team:     "red",
		Position: Vector2{X: 2850, Y: 600},
		HP:       5000,
		MaxHP:    5000,
		IsBase:   true,
	}
	r.Towers["red_tower1"] = &Tower{
		ID:       "red_tower1",
		Team:     "red",
		Position: Vector2{X: 2150, Y: 600},
		HP:       2500,
		MaxHP:    2500,
		IsBase:   false,
	}
	
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
		for {
			select {
			case <-r.stopChan:
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

func (r *Room) handleRegister(p *Player) {
	r.mu.Lock()
	defer r.mu.Unlock()

	// Assign balanced team
	blueCount, redCount := 0, 0
	for _, pl := range r.Players {
		if pl.Team == "blue" {
			blueCount++
		} else {
			redCount++
		}
	}
	
	if blueCount <= redCount {
		p.Team = "blue"
	} else {
		p.Team = "red"
	}

	// Kick an AI bot on the same team to free up a slot for the human player
	var botToKick *Player
	for _, pl := range r.Players {
		if pl.IsBot && pl.Team == p.Team {
			botToKick = pl
			break
		}
	}
	
	p.Skills = make(map[string]int)
	p.Level = 1
	p.XP = 0
	p.XPToNext = 50
	p.MaxHP = 100
	p.HP = 100
	p.Speed = 280.0
	p.Score = 0
	p.Dead = false
	
	r.respawnPlayer(p)
	
	if botToKick != nil {
		delete(r.Players, botToKick.ID)
	}
	r.Players[p.ID] = p

	// Send init message
	initMsg := ServerMessage{
		Type:     "init",
		ClientID: p.ID,
		Team:     p.Team,
		Walls:    r.Walls,
	}
	if data, err := json.Marshal(initMsg); err == nil {
		p.send <- data
	}

	// Chat broadcast join
	if botToKick != nil {
		r.broadcastChat("system", fmt.Sprintf("%s joined the %s team (replaced AI %s)!", p.Name, p.Team, botToKick.Name))
	} else {
		r.broadcastChat("system", fmt.Sprintf("%s joined the %s team!", p.Name, p.Team))
	}
}

func (r *Room) handleUnregister(p *Player) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.Players[p.ID]; ok {
		delete(r.Players, p.ID)
		r.broadcastChat("system", fmt.Sprintf("%s has left the game.", p.Name))
		
		// Fill room with bots to keep the match 3v3
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
	if p.Team == "blue" {
		p.Position = Vector2{
			X: 100 + rand.Float64()*150,
			Y: 450 + rand.Float64()*300,
		}
	} else {
		p.Position = Vector2{
			X: 2750 + rand.Float64()*150,
			Y: 450 + rand.Float64()*300,
		}
	}
}

func (r *Room) nextID(prefix string) string {
	r.entityIDSeq++
	return fmt.Sprintf("%s_%d", prefix, r.entityIDSeq)
}

func (r *Room) spawnGem(gemType string) {
	id := r.nextID("gem")
	
	// Spawn more gems towards the center of the lane
	var x, y float64
	if gemType == "hp" {
		// HP gems are rarer and spread out
		x = 300 + rand.Float64()*(MapWidth-600)
		y = 100 + rand.Float64()*(MapHeight-200)
	} else {
		// XP gems center in the active push zones
		x = 500 + rand.Float64()*(MapWidth-1000)
		y = 100 + rand.Float64()*(MapHeight-200)
	}

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

func (r *Room) spawnMinionWave() {
	// Spawns 3 minions at Blue Base, 3 at Red Base
	for i := 0; i < 3; i++ {
		blueID := r.nextID("minion_b")
		r.Minions[blueID] = &Minion{
			ID:       blueID,
			Team:     "blue",
			Position: Vector2{X: 150 + rand.Float64()*40, Y: 500 + float64(i)*80},
			HP:       300,
			MaxHP:    300,
			Speed:    100,
			TargetX:  2850,
			TargetY:  600,
			State:    "march",
		}
		
		redID := r.nextID("minion_r")
		r.Minions[redID] = &Minion{
			ID:       redID,
			Team:     "red",
			Position: Vector2{X: 2850 - rand.Float64()*40, Y: 500 + float64(i)*80},
			HP:       300,
			MaxHP:    300,
			Speed:    100,
			TargetX:  150,
			TargetY:  600,
			State:    "march",
		}
	}
}

func (r *Room) playerShoot(p *Player, baseAngle float64) {
	if p.ShootCooldown > 0 {
		return
	}
	
	// Base Stats
	baseDamage := 15.0 + float64(p.Skills[SkillDamageBoost])*5
	atkSpeedLvl := float64(p.Skills[SkillAtkSpeed])
	p.ShootCooldown = 0.5 * math.Pow(0.85, atkSpeedLvl) // 15% CDR per level

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
	
	// Spawn Minions every 20 seconds
	if r.spawnTimer >= 20.0 {
		r.spawnMinionWave()
		r.spawnTimer = 0.0
	}
	
	// Spawn XP/HP Gems if below cap
	if r.gemTimer >= 4.0 {
		if len(r.Gems) < 50 {
			r.spawnGem("xp")
			if rand.Float64() < 0.25 {
				r.spawnGem("hp")
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
		
		speedMultiplier := 1.0
		if p.IceTimer > 0 {
			p.IceTimer -= dt
			speedMultiplier = 0.55
		}
		
		if p.ShootCooldown > 0 {
			p.ShootCooldown -= dt
		}

		if p.IsBot {
			r.updateBotAI(p, dt)
		}
		
		// Update position
		if p.Moving {
			p.Position.X += p.MoveDir.X * p.Speed * speedMultiplier * dt
			p.Position.Y += p.MoveDir.Y * p.Speed * speedMultiplier * dt
			
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

	// Update Minions
	for mID, m := range r.Minions {
		if m.HP <= 0 {
			delete(r.Minions, mID)
			continue
		}
		
		// Tick elemental debuffs
		if m.FireTimer > 0 {
			m.FireTimer -= dt
			m.HP -= 15.0 * dt
		}
		if m.PoisonTimer > 0 {
			m.PoisonTimer -= dt
			m.HP -= 8.0 * dt
		}
		
		minionSpeedMultiplier := 1.0
		if m.IceTimer > 0 {
			m.IceTimer -= dt
			minionSpeedMultiplier = 0.55
		}
		
		if m.Cooldown > 0 {
			m.Cooldown -= dt
		}

		// Minion AI: search for nearby enemies to attack, else march
		enemy, dist := r.findNearestEnemy(m.Position, m.Team, 350.0)
		if enemy != nil {
			m.State = "attack"
			m.TargetX = enemy.X
			m.TargetY = enemy.Y
			
			// Attack if in range (melee/close range)
			if dist <= 60.0 {
				if m.Cooldown <= 0 {
					r.damageEntityAt(m.TargetX, m.TargetY, 20.0, m.Team, "minion")
					m.Cooldown = 1.0 // 1s attack CD
				}
				// Don't move if already attacking
				continue
			}
		} else {
			m.State = "march"
			// Pathing towards opposing base or first tower
			targTower := r.findNextTowerTarget(m.Team)
			if targTower != nil {
				m.TargetX = targTower.Position.X
				m.TargetY = targTower.Position.Y
			} else {
				if m.Team == "blue" {
					m.TargetX = 2850
					m.TargetY = 600
				} else {
					m.TargetX = 150
					m.TargetY = 600
				}
			}
		}

		// Move minion
		dx := m.TargetX - m.Position.X
		dy := m.TargetY - m.Position.Y
		d := math.Sqrt(dx*dx + dy*dy)
		if d > 5 {
			m.Position.X += (dx / d) * m.Speed * minionSpeedMultiplier * dt
			m.Position.Y += (dy / d) * m.Speed * minionSpeedMultiplier * dt
			
			r.resolveWallCollisions(&m.Position, 20.0)
		}
	}

	// Update Towers
	for tID, t := range r.Towers {
		if t.HP <= 0 {
			r.broadcastChat("system", fmt.Sprintf("The %s %s was destroyed!", t.Team, t.ID))
			delete(r.Towers, tID)
			
			// Victory Check
			if t.IsBase {
				winner := "red"
				if t.Team == "red" {
					winner = "blue"
				}
				r.endGame(winner)
			}
			continue
		}
		
		if t.Cooldown > 0 {
			t.Cooldown -= dt
		}
		
		// Towers shoot at nearest enemy in range
		if t.Cooldown <= 0 {
			rangeLimit := 400.0
			if t.IsBase { rangeLimit = 550.0 }
			
			target, _ := r.findNearestEnemy(t.Position, t.Team, rangeLimit)
			if target != nil {
				// Fire tower projectile
				projID := r.nextID("proj")
				angle := math.Atan2(target.Y - t.Position.Y, target.X - t.Position.X)
				dx := math.Cos(angle)
				dy := math.Sin(angle)
				
				r.Projectiles[projID] = &Projectile{
					ID:        projID,
					OwnerID:   t.ID,
					OwnerType: "tower",
					Team:      t.Team,
					Position:  t.Position,
					Velocity:  Vector2{X: dx * 500, Y: dy * 500},
					Damage:    40.0,
					Life:      1.5,
					Bounces:   0,
					Pierces:   0,
				}
				t.Cooldown = 1.5 // Tower shoots once per 1.5s
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
	if g.Type == "hp" {
		p.HP += 30.0
		if p.HP > p.MaxHP {
			p.HP = p.MaxHP
		}
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

func (r *Room) triggerLevelUp(p *Player) {
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
		p.send <- data
	}
}

func (r *Room) checkProjectileHit(proj *Projectile) {
	targetHit := false
	
	// Hit Players
	if proj.OwnerType != "player" { // Hit enemy player
		for _, enemy := range r.Players {
			if enemy.Dead || enemy.Team == proj.Team {
				continue
			}
			dx := proj.Position.X - enemy.Position.X
			dy := proj.Position.Y - enemy.Position.Y
			dist := math.Sqrt(dx*dx + dy*dy)
			if dist < 25.0 {
				r.damagePlayer(enemy, proj.Damage, proj.OwnerID)
				r.applyProjectileEffects(proj.Effects, enemy, nil)
				targetHit = true
				break
			}
		}
	} else { // Projectile owner is player, can hit enemy players, minions, and towers
		// Hit players
		for _, enemy := range r.Players {
			if enemy.Dead || enemy.Team == proj.Team {
				continue
			}
			dx := proj.Position.X - enemy.Position.X
			dy := proj.Position.Y - enemy.Position.Y
			dist := math.Sqrt(dx*dx + dy*dy)
			if dist < 25.0 {
				r.damagePlayer(enemy, proj.Damage, proj.OwnerID)
				r.applyProjectileEffects(proj.Effects, enemy, nil)
				targetHit = true
				break
			}
		}
	}

	// Hit Minions
	if !targetHit {
		for _, m := range r.Minions {
			if m.Team == proj.Team {
				continue
			}
			dx := proj.Position.X - m.Position.X
			dy := proj.Position.Y - m.Position.Y
			dist := math.Sqrt(dx*dx + dy*dy)
			if dist < 20.0 {
				m.HP -= proj.Damage
				r.applyProjectileEffects(proj.Effects, nil, m)
				if m.HP <= 0 {
					// Award XP to player who hit
					if proj.OwnerType == "player" {
						if p, ok := r.Players[proj.OwnerID]; ok {
							p.Score += 10
							// Spawn XP gem at minion location
							gID := r.nextID("gem")
							r.Gems[gID] = &Gem{
								ID:       gID,
								Position: m.Position,
								XPValue:  25,
								Type:     "xp",
							}
						}
					}
				}
				targetHit = true
				break
			}
		}
	}

	// Hit Towers/Bases
	if !targetHit {
		for _, t := range r.Towers {
			if t.Team == proj.Team {
				continue
			}
			dx := proj.Position.X - t.Position.X
			dy := proj.Position.Y - t.Position.Y
			dist := math.Sqrt(dx*dx + dy*dy)
			
			hitRadius := 45.0
			if t.IsBase { hitRadius = 80.0 }
			
			if dist < hitRadius {
				t.HP -= proj.Damage
				targetHit = true
				break
			}
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
	if p.Dead {
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

	for _, m := range r.Minions {
		if m.Team == team {
			continue
		}
		dx := m.Position.X - x
		dy := m.Position.Y - y
		if math.Sqrt(dx*dx + dy*dy) < 25.0 {
			m.HP -= dmg
			return
		}
	}

	for _, t := range r.Towers {
		if t.Team == team {
			continue
		}
		dx := t.Position.X - x
		dy := t.Position.Y - y
		
		hitRadius := 50.0
		if t.IsBase { hitRadius = 90.0 }
		
		if math.Sqrt(dx*dx + dy*dy) < hitRadius {
			t.HP -= dmg
			return
		}
	}
}

func (r *Room) findNearestEnemy(pos Vector2, team string, rangeLimit float64) (*Vector2, float64) {
	var nearest *Vector2
	minDist := rangeLimit
	
	// Check Players
	for _, p := range r.Players {
		if p.Dead || p.Team == team {
			continue
		}
		dx := p.Position.X - pos.X
		dy := p.Position.Y - pos.Y
		dist := math.Sqrt(dx*dx + dy*dy)
		if dist < minDist {
			minDist = dist
			nearest = &Vector2{X: p.Position.X, Y: p.Position.Y}
		}
	}
	
	// Check Minions
	for _, m := range r.Minions {
		if m.Team == team {
			continue
		}
		dx := m.Position.X - pos.X
		dy := m.Position.Y - pos.Y
		dist := math.Sqrt(dx*dx + dy*dy)
		if dist < minDist {
			minDist = dist
			nearest = &Vector2{X: m.Position.X, Y: m.Position.Y}
		}
	}
	
	// Check Towers
	for _, t := range r.Towers {
		if t.Team == team {
			continue
		}
		dx := t.Position.X - pos.X
		dy := t.Position.Y - pos.Y
		dist := math.Sqrt(dx*dx + dy*dy)
		if dist < minDist {
			minDist = dist
			nearest = &Vector2{X: t.Position.X, Y: t.Position.Y}
		}
	}
	
	return nearest, minDist
}

func (r *Room) findNextTowerTarget(team string) *Tower {
	enemyTeam := "red"
	if team == "red" {
		enemyTeam = "blue"
	}
	
	// Search outer towers first, then base
	t1, ok1 := r.Towers[enemyTeam+"_tower1"]
	if ok1 && t1.HP > 0 {
		return t1
	}
	
	base, ok2 := r.Towers[enemyTeam+"_base"]
	if ok2 && base.HP > 0 {
		return base
	}
	
	return nil
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
		r.Minions = make(map[string]*Minion)
		r.Gems = make(map[string]*Gem)
		r.Towers = make(map[string]*Tower)
		
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
		Minions:     make([]*Minion, 0, len(r.Minions)),
		Towers:      make([]*Tower, 0, len(r.Towers)),
		Projectiles: make([]*Projectile, 0, len(r.Projectiles)),
		Gems:        make([]*Gem, 0, len(r.Gems)),
	}

	for _, p := range r.Players {
		state.Players = append(state.Players, p)
	}
	for _, m := range r.Minions {
		state.Minions = append(state.Minions, m)
	}
	for _, t := range r.Towers {
		state.Towers = append(state.Towers, t)
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

func (r *Room) applyProjectileEffects(effects []string, playerTarget *Player, minionTarget *Minion) {
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
		} else if minionTarget != nil {
			switch eff {
			case "fire":
				minionTarget.FireTimer = 3.0
			case "ice":
				minionTarget.IceTimer = 2.5
			case "poison":
				minionTarget.PoisonTimer = 5.0
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
		ID:            botID,
		Name:          name,
		Team:          team,
		Skills:        make(map[string]int),
		Level:         1,
		XP:            0,
		XPToNext:      50,
		MaxHP:         100,
		HP:            100,
		Speed:         240.0,
		Score:         0,
		Dead:          false,
		IsBot:         true,
	}
	
	r.respawnPlayer(p)
	r.Players[botID] = p
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
		// 2. Marching: push the lane
		targTower := r.findNextTowerTarget(p.Team)
		var targX, targY float64
		if targTower != nil {
			targX = targTower.Position.X
			targY = targTower.Position.Y
		} else {
			if p.Team == "blue" {
				targX = 2850
				targY = 600
			} else {
				targX = 150
				targY = 600
			}
		}
		
		dx := targX - p.Position.X
		dy := targY - p.Position.Y
		d := math.Sqrt(dx*dx + dy*dy)
		if d > 10 {
			moveDir = Vector2{X: dx / d, Y: dy / d}
			p.Angle = math.Atan2(dy, dx)
		}
	}
	
	p.Moving = moveDir.X != 0 || moveDir.Y != 0
	p.MoveDir = moveDir
}
