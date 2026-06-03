extends Node2D

# --- Networking ---
var socket: WebSocketPeer = WebSocketPeer.new()
var is_connected: bool = false
var is_connecting: bool = false
var connection_timeout_timer: float = 0.0
var client_id: String = ""
var my_team: String = ""

# --- Game State ---
var game_state: Dictionary = {
	"players": [],
	"minions": [],
	"towers": [],
	"projectiles": [],
	"gems": []
}
var walls: Array = []
var my_player_data = null

# --- Visual Effects & Juice ---
var screen_shake: float = 0.0
var damage_texts: Array = []
var hit_sparks: Array = []
var grass_bushes: Array = []

# --- Input & Movement ---
var last_move_dir: Vector2 = Vector2.ZERO
var last_angle: float = 0.0
var is_chatting: bool = false

# --- Skill Mapping ---
const SKILL_NAMES = {
	"multi_shot": "Multi Shot 🏹",
	"diagonal": "Diagonal 🏹",
	"rear_shot": "Rear Shot 🏹",
	"piercing": "Piercing 🎯",
	"bouncing": "Bouncing 💎",
	"fire_arrow": "Fire Arrow 🔥",
	"ice_arrow": "Ice Arrow ❄️",
	"poison_arrow": "Poison Arrow ☠️",
	"hp_boost": "HP Boost ❤️",
	"speed_boost": "Speed Boost ⚡",
	"atk_speed": "Attack Speed ⚔️",
	"damage_boost": "Damage Boost 💪"
}

# --- Font Reference ---
var system_font: Font = null

# --- Interpolation / Smooth Positions ---
var smooth_positions: Dictionary = {}

func _ready():
	system_font = ThemeDB.fallback_font
	
	# Automatically hide the ServerInput LineEdit to avoid UI confusion
	$UI/Lobby/Panel/VBox/ServerInput.visible = false
	
	# 1. Connect UI Signals
	$UI/Lobby/Panel/VBox/JoinButton.pressed.connect(_on_join_pressed)
	$UI/HUD/ChatBox/ChatInput.text_submitted.connect(_on_chat_submitted)
	
	# Connect name input focus_entered for mobile virtual keyboard trigger
	$UI/Lobby/Panel/VBox/NameInput.focus_entered.connect(_on_name_input_focus_entered)
	
	# Connect skill choices buttons
	$UI/SkillPanel/VBox/Choices/Choice1.pressed.connect(func(): _on_skill_chosen(0))
	$UI/SkillPanel/VBox/Choices/Choice2.pressed.connect(func(): _on_skill_chosen(1))
	$UI/SkillPanel/VBox/Choices/Choice3.pressed.connect(func(): _on_skill_chosen(2))
	
	# Connect custom drawing of the world node
	$World.draw.connect(_on_world_draw)
	
	# Generate some decorative grass/stealth bushes
	randomize()
	for i in range(20):
		grass_bushes.append({
			"pos": Vector2(randf_range(200, 2800), randf_range(100, 1100)),
			"radius": randf_range(60, 95)
		})
	
	# Initial window setup
	get_viewport().files_dropped.connect(func(files): pass)

func _on_name_input_focus_entered():
	if OS.has_feature("web"):
		# Release focus immediately to avoid repeating prompt triggers
		$UI/Lobby/Panel/VBox/NameInput.release_focus()
		var current_text = $UI/Lobby/Panel/VBox/NameInput.text
		var input = JavaScriptBridge.eval("prompt('请输入你的游戏昵称 (Enter your nickname):', '" + current_text.replace("'", "\\'") + "')")
		if input != null:
			var name_str = str(input).strip_edges()
			if name_str != "":
				$UI/Lobby/Panel/VBox/NameInput.text = name_str

func _on_join_pressed():
	if is_connecting or is_connected:
		return
		
	var nickname = $UI/Lobby/Panel/VBox/NameInput.text.strip_edges()
	if nickname == "":
		if OS.has_feature("web"):
			var input = JavaScriptBridge.eval("prompt('请输入你的游戏昵称 (Enter your nickname):', '')")
			if input != null and str(input).strip_edges() != "":
				nickname = str(input).strip_edges()
				$UI/Lobby/Panel/VBox/NameInput.text = nickname
			else:
				nickname = "Archer" + str(randi() % 1000)
		else:
			nickname = "Archer" + str(randi() % 1000)
			
	var server_url = "ws://prts.kyoiryi.top/archer/ws" # Default production target
	if OS.has_feature("web"):
		var host = JavaScriptBridge.eval("window.location.host")
		var protocol = JavaScriptBridge.eval("window.location.protocol")
		var pathname = JavaScriptBridge.eval("window.location.pathname")
		
		var ws_protocol = "ws://"
		if protocol == "https:":
			ws_protocol = "wss://"
			
		var ws_path = "/ws"
		if pathname != null and str(pathname).begins_with("/archer"):
			ws_path = "/archer/ws"
			
		server_url = ws_protocol + host + ws_path
	else:
		# Fallback for local editor development
		var server_input_text = $UI/Lobby/Panel/VBox/ServerInput.text.strip_edges()
		if server_input_text != "":
			server_url = server_input_text
		else:
			server_url = "ws://localhost:8090/ws"
		
	# Append query param for nickname
	var ws_url = server_url + "?name=" + nickname.uri_encode()
	
	add_chat_message("System", "Connecting to " + ws_url + "...")
	
	# Start connection state tracking
	is_connecting = true
	connection_timeout_timer = 5.0
	$UI/Lobby/Panel/VBox/JoinButton.disabled = true
	$UI/Lobby/Panel/VBox/JoinButton.text = "CONNECTING..."
	
	socket.connect_to_url(ws_url)

func _process(delta):
	# 1. Poll WebSocket
	socket.poll()
	var state = socket.get_ready_state()
	
	if state == WebSocketPeer.STATE_OPEN:
		if not is_connected:
			is_connected = true
			is_connecting = false
			$UI/Lobby/Panel/VBox/JoinButton.disabled = false
			$UI/Lobby/Panel/VBox/JoinButton.text = "CONNECT & PLAY"
			$UI/Lobby.visible = false
			$UI/HUD.visible = true
			add_chat_message("System", "Successfully connected!")
		
		# Read server packets
		while socket.get_available_packet_count() > 0:
			var packet = socket.get_packet()
			var data_str = packet.get_string_from_utf8()
			
			# Server may batch packets separated by newlines
			var packets = data_str.split("\n")
			for p_str in packets:
				if p_str.strip_edges() == "":
					continue
				
				var json = JSON.new()
				if json.parse(p_str) == OK:
					var parsed_data = json.get_data()
					if parsed_data is Dictionary:
						_handle_server_message(parsed_data)
					
	elif state == WebSocketPeer.STATE_CLOSED:
		if is_connected:
			is_connected = false
			$UI/Lobby.visible = true
			$UI/HUD.visible = false
			$UI/SkillPanel.visible = false
			add_chat_message("System", "Disconnected from server.")
		elif is_connecting:
			is_connecting = false
			$UI/Lobby/Panel/VBox/JoinButton.disabled = false
			$UI/Lobby/Panel/VBox/JoinButton.text = "CONNECT & PLAY"
			add_chat_message("System", "Connection failed! Server might be offline.")
			if OS.has_feature("web"):
				JavaScriptBridge.eval("alert('无法连接到服务器，请检查网络或确认服务器已运行。 (Failed to connect to server. Ensure it is running.)')")
				
	# Handle connection timeout
	if is_connecting:
		connection_timeout_timer -= delta
		if connection_timeout_timer <= 0:
			socket.close()
			is_connecting = false
			$UI/Lobby/Panel/VBox/JoinButton.disabled = false
			$UI/Lobby/Panel/VBox/JoinButton.text = "CONNECT & PLAY"
			add_chat_message("System", "Connection timed out.")
			if OS.has_feature("web"):
				JavaScriptBridge.eval("alert('连接超时，请确认服务器正常工作。 (Connection timed out.)')")
	
	# Interpolate active entities for buttery-smooth movements
	_update_smooth_positions(delta)
	
	# 2. Smooth Camera Follow
	if my_player_data is Dictionary:
		var my_pos = _get_safe_vector2(my_player_data, "pos")
		var my_smooth_pos = smooth_positions.get(client_id, my_pos)
		var target_cam_pos = my_smooth_pos
		# Clamp camera inside map bounds with some margin
		target_cam_pos.x = clamp(target_cam_pos.x, 640, 3000 - 640)
		target_cam_pos.y = clamp(target_cam_pos.y, 360, 1200 - 360)
		
		var shake_offset = Vector2.ZERO
		if screen_shake > 0:
			shake_offset = Vector2(randf_range(-screen_shake, screen_shake), randf_range(-screen_shake, screen_shake))
			screen_shake = lerp(screen_shake, 0.0, 10.0 * delta)
			
		$Camera2D.position = $Camera2D.position.lerp(target_cam_pos, 8.0 * delta) + shake_offset
	
	# 3. Process Input (If connected and not chatting)
	if is_connected and not is_chatting and (my_player_data is Dictionary) and not _get_safe_bool(my_player_data, "dead", false):
		_process_movement_input(delta)
		_process_aiming_input(delta)
		
	# 4. Handle Chat Open key (Enter)
	if Input.is_key_pressed(KEY_ENTER) or Input.is_physical_key_pressed(KEY_ENTER):
		if not is_chatting:
			$UI/HUD/ChatBox/ChatInput.grab_focus()
			is_chatting = true
			
	# 5. Process Visual FX (texts, particles)
	_update_visual_effects(delta)
	
	# Redraw the world
	$World.queue_redraw()

func _process_movement_input(delta):
	var move_dir = Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): move_dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): move_dir.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): move_dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): move_dir.x += 1
	
	move_dir = move_dir.normalized()
	
	# Find facing angle
	var angle = last_angle
	if move_dir != Vector2.ZERO:
		angle = move_dir.angle()
		last_angle = angle
		
	# Send input update if changed
	if move_dir != last_move_dir or angle != last_angle:
		last_move_dir = move_dir
		
		var msg = {
			"type": "move",
			"is_moving": move_dir != Vector2.ZERO,
			"x": move_dir.x,
			"y": move_dir.y,
			"angle": angle
		}
		socket.send_text(JSON.stringify(msg))

func _process_aiming_input(delta):
	# Manual Shoot: hold left mouse click to aim and shoot
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var mouse_pos = get_global_mouse_position()
		if my_player_data is Dictionary:
			var p_pos = _get_safe_vector2(my_player_data, "pos")
			var angle = (mouse_pos - p_pos).angle()
			
			var msg = {
				"type": "shoot",
				"angle": angle
			}
			socket.send_text(JSON.stringify(msg))

func _update_visual_effects(delta):
	# Update damage texts
	var active_texts = []
	for t in damage_texts:
		t.life -= delta
		t.pos.y -= 45.0 * delta # float up
		if t.life > 0:
			active_texts.append(t)
	damage_texts = active_texts
	
	# Update sparks
	var active_sparks = []
	for s in hit_sparks:
		s.life -= delta
		s.pos += s.vel * delta
		s.vel = s.vel * 0.9 # slow down
		if s.life > 0:
			active_sparks.append(s)
	hit_sparks = active_sparks

func _handle_server_message(data: Dictionary):
	var type = _get_safe_string(data, "type", "")
	
	match type:
		"init":
			client_id = _get_safe_string(data, "client_id", "")
			my_team = _get_safe_string(data, "team", "")
			walls = _get_safe_array(data, "walls")
			add_chat_message("System", "Joined match! You are Team: " + my_team.to_upper())
			
		"state":
			var old_minion_hps = _get_entities_hps(_get_safe_array(game_state, "minions"))
			var old_player_hps = _get_entities_hps(_get_safe_array(game_state, "players"))
			var old_tower_hps = _get_entities_hps(_get_safe_array(game_state, "towers"))
			
			var raw_state = data.get("state")
			if raw_state is Dictionary:
				game_state = raw_state
			else:
				game_state = {
					"players": [],
					"minions": [],
					"towers": [],
					"projectiles": [],
					"gems": []
				}
			
			# Find my player data
			my_player_data = null
			var players_list = _get_safe_array(game_state, "players")
			for p in players_list:
				if p is Dictionary and _get_safe_string(p, "id", "") == client_id:
					my_player_data = p
					break
			
			# Update HUD
			if my_player_data is Dictionary:
				$UI/HUD/XPBar.max_value = _get_safe_int(my_player_data, "xp_to_next", 100)
				$UI/HUD/XPBar.value = _get_safe_int(my_player_data, "xp", 0)
				$UI/HUD/HPBar.max_value = _get_safe_int(my_player_data, "max_hp", 100)
				$UI/HUD/HPBar.value = _get_safe_int(my_player_data, "hp", 0)
				$UI/HUD/TopPanel/Stats.text = "Lvl: " + str(_get_safe_int(my_player_data, "level", 1)) + " | Score: " + str(_get_safe_int(my_player_data, "score", 0))
				
				if _get_safe_bool(my_player_data, "dead", false):
					$UI/HUD/TopPanel/Stats.text = "☠️ DEAD (Respawning...) | Lvl: " + str(_get_safe_int(my_player_data, "level", 1)) + " | Score: " + str(_get_safe_int(my_player_data, "score", 0))
			
			# Core base health updates
			var blue_core_hp = "0"
			var red_core_hp = "0"
			var towers_list = _get_safe_array(game_state, "towers")
			for t in towers_list:
				if t is Dictionary:
					var t_id = _get_safe_string(t, "id", "")
					if t_id == "blue_base": blue_core_hp = str(int(_get_safe_float(t, "hp", 0.0)))
					if t_id == "red_base": red_core_hp = str(int(_get_safe_float(t, "hp", 0.0)))
			$UI/HUD/TopPanel/BaseHPs.text = "Blue Core: " + blue_core_hp + " | Red Core: " + red_core_hp
			
			# Check damage events for Juice (Screen shakes & Damage Texts)
			_spawn_damage_juices(_get_safe_array(game_state, "minions"), old_minion_hps)
			_spawn_damage_juices(_get_safe_array(game_state, "players"), old_player_hps)
			_spawn_damage_juices(_get_safe_array(game_state, "towers"), old_tower_hps)
			
			_update_scoreboard()
			
		"levelup":
			# Show skill choice menu
			var choices = _get_safe_array(data, "skill_choices")
			if choices.size() >= 3:
				$UI/SkillPanel/VBox/Choices/Choice1.text = SKILL_NAMES.get(choices[0], choices[0])
				$UI/SkillPanel/VBox/Choices/Choice1.set_meta("skill", choices[0])
				
				$UI/SkillPanel/VBox/Choices/Choice2.text = SKILL_NAMES.get(choices[1], choices[1])
				$UI/SkillPanel/VBox/Choices/Choice2.set_meta("skill", choices[1])
				
				$UI/SkillPanel/VBox/Choices/Choice3.text = SKILL_NAMES.get(choices[2], choices[2])
				$UI/SkillPanel/VBox/Choices/Choice3.set_meta("skill", choices[2])
				
				$UI/SkillPanel.visible = true
				
		"chat":
			var sender = _get_safe_string(data, "sender_name", "")
			var msg = _get_safe_string(data, "chat_msg", "")
			add_chat_message(sender, msg)
			
		"kill_feed":
			var killer = _get_safe_string(data, "killer_name", "")
			var victim = _get_safe_string(data, "victim_name", "")
			add_chat_message("KILL", killer + " 🏹 killed 💀 " + victim)
			
		"game_over":
			var winner = _get_safe_string(data, "winner_team", "")
			$UI/GameOver/Panel/VBox/Title.text = "VICTORY!" if winner == my_team else "DEFEAT!"
			$UI/GameOver/Panel/VBox/Subtitle.text = winner.to_upper() + " Team destroyed the opponent's core base!"
			$UI/GameOver.visible = true
			
			# Auto hide victory panel after 8 seconds
			get_tree().create_timer(8.0).timeout.connect(func():
				$UI/GameOver.visible = false
			)

func _get_entities_hps(list: Array) -> Dictionary:
	var hps = {}
	if list == null:
		return hps
	for e in list:
		if e is Dictionary:
			var e_id = _get_safe_string(e, "id", "")
			if e_id != "":
				hps[e_id] = _get_safe_float(e, "hp", 0.0)
	return hps

func _spawn_damage_juices(new_list: Array, old_hps: Dictionary):
	if new_list == null:
		return
	for e in new_list:
		if not (e is Dictionary):
			continue
		var e_id = _get_safe_string(e, "id", "")
		if e_id == "":
			continue
		if old_hps.has(e_id):
			var old_hp = old_hps[e_id]
			var current_hp = _get_safe_float(e, "hp", 0.0)
			if current_hp < old_hp:
				var diff = old_hp - current_hp
				var e_pos = _get_safe_vector2(e, "pos")
				
				# Spawn Damage Floating Text
				damage_texts.append({
					"pos": e_pos + Vector2(randf_range(-15, 15), -20),
					"text": str(int(diff)),
					"color": Color(1.0, 0.3, 0.3) if _get_safe_string(e, "team", "") != my_team else Color(1.0, 0.9, 0.2),
					"life": 0.8
				})
				
				# Hit Sparks
				for i in range(6):
					var speed = randf_range(80, 200)
					var angle = randf_range(0, TAU)
					hit_sparks.append({
						"pos": e_pos,
						"vel": Vector2(cos(angle), sin(angle)) * speed,
						"color": Color(1.0, 0.6, 0.1) if _get_safe_string(e, "team", "") != my_team else Color(0.9, 0.2, 0.2),
						"life": randf_range(0.2, 0.45),
						"size": randf_range(2.0, 5.0)
					})
				
				# Trigger screen shake if I took damage
				if e_id == client_id:
					screen_shake = 12.0

func _on_skill_chosen(index: int):
	var btn = null
	if index == 0: btn = $UI/SkillPanel/VBox/Choices/Choice1
	elif index == 1: btn = $UI/SkillPanel/VBox/Choices/Choice2
	elif index == 2: btn = $UI/SkillPanel/VBox/Choices/Choice3
	
	if btn:
		var skill = btn.get_meta("skill")
		var msg = {
			"type": "select_skill",
			"skill": skill
		}
		socket.send_text(JSON.stringify(msg))
		
	$UI/SkillPanel.visible = false

func _on_chat_submitted(text: String):
	text = text.strip_edges()
	if text != "":
		var msg = {
			"type": "chat",
			"chat_msg": text
		}
		socket.send_text(JSON.stringify(msg))
		
	$UI/HUD/ChatBox/ChatInput.text = ""
	$UI/HUD/ChatBox/ChatInput.release_focus()
	is_chatting = false

func add_chat_message(sender: String, message: String):
	var label = Label.new()
	if sender == "System":
		label.text = "[System] " + message
		label.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	elif sender == "KILL":
		label.text = "⚔️ " + message
		label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	else:
		label.text = sender + ": " + message
		
	$UI/HUD/ChatBox/Scroll/ChatLog.add_child(label)
	
	# Limit log size
	if $UI/HUD/ChatBox/Scroll/ChatLog.get_child_count() > 30:
		$UI/HUD/ChatBox/Scroll/ChatLog.get_child(0).queue_free()
		
	# Auto-scroll
	await get_tree().process_frame
	$UI/HUD/ChatBox/Scroll.scroll_vertical = 99999

func _update_scoreboard():
	# Clear scoreboard list
	for c in $UI/HUD/Scoreboard/List.get_children():
		c.queue_free()
		
	var players_list = _get_safe_array(game_state, "players")
	if players_list == null:
		return
		
	# Sort players by score safely
	var list = players_list.duplicate()
	list.sort_custom(func(a, b):
		var a_score = 0
		var b_score = 0
		if a is Dictionary:
			a_score = _get_safe_int(a, "score", 0)
		if b is Dictionary:
			b_score = _get_safe_int(b, "score", 0)
		return a_score > b_score
	)
	
	# Draw top 6
	var count = 0
	for p in list:
		if not (p is Dictionary):
			continue
		if count >= 6: break
		var l = Label.new()
		var p_name = _get_safe_string(p, "name", "Archer")
		var p_team = _get_safe_string(p, "team", "blue")
		var p_score = _get_safe_int(p, "score", 0)
		var p_level = _get_safe_int(p, "level", 1)
		l.text = p_name + " (" + p_team.to_upper() + "): " + str(p_score) + " (Lvl " + str(p_level) + ")"
		if p_team == "blue":
			l.add_theme_color_override("font_color", Color(0.4, 0.6, 1.0))
		else:
			l.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		$UI/HUD/Scoreboard/List.add_child(l)
		count += 1

# --- CUSTOM RENDERER ---
func _on_world_draw():
	var world_node = $World
	
	# Draw Background Grid (3000 x 1200)
	var grid_color = Color(0.12, 0.15, 0.18)
	var background_color = Color(0.08, 0.10, 0.12)
	
	# Fill map background
	world_node.draw_rect(Rect2(0, 0, 3000, 1200), background_color, true)
	
	# Grid Lines
	var grid_size = 100
	for x in range(0, 3000, grid_size):
		world_node.draw_line(Vector2(x, 0), Vector2(x, 1200), grid_color, 1.0)
	for y in range(0, 1200, grid_size):
		world_node.draw_line(Vector2(0, y), Vector2(3000, y), grid_color, 1.0)
		
	# Outer Border
	world_node.draw_rect(Rect2(0, 0, 3000, 1200), Color(0.4, 0.4, 0.5), false, 4.0)

	# Draw Stealth Grass/Bushes (Players inside bushes are hidden/stealthy!)
	for b in grass_bushes:
		world_node.draw_circle(b.pos, b.radius, Color(0.14, 0.26, 0.16, 0.65))
		# Draw outline
		world_node.draw_circle(b.pos, b.radius, Color(0.2, 0.4, 0.2, 0.4), false, 2.0)

	# Draw Obstacle Walls
	for w in walls:
		var r = Rect2(w.x, w.y, w.w, w.h)
		# Draw outer dark glow
		world_node.draw_rect(r, Color(0.22, 0.26, 0.3), true)
		world_node.draw_rect(r, Color(0.42, 0.48, 0.55), false, 3.0)

	# Draw Gems
	var gems_list = _get_safe_array(game_state, "gems")
	for g in gems_list:
		if not (g is Dictionary): continue
		var g_id = _get_safe_string(g, "id", "")
		var g_pos = smooth_positions.get(g_id)
		if g_pos == null:
			g_pos = _get_safe_vector2(g, "pos")
			
		if _get_safe_string(g, "type", "xp") == "hp":
			# HP: red cross
			world_node.draw_rect(Rect2(g_pos.x - 7, g_pos.y - 3, 14, 6), Color(1.0, 0.2, 0.2), true)
			world_node.draw_rect(Rect2(g_pos.x - 3, g_pos.y - 7, 6, 14), Color(1.0, 0.2, 0.2), true)
		else:
			# XP: green diamond shape
			var pts = PackedVector2Array([
				g_pos + Vector2(0, -9),
				g_pos + Vector2(7, 0),
				g_pos + Vector2(0, 9),
				g_pos + Vector2(-7, 0)
			])
			world_node.draw_colored_polygon(pts, Color(0.2, 0.9, 0.4))
			world_node.draw_polyline(pts, Color(0.6, 1.0, 0.7), 1.5)

	# Draw Projectiles/Arrows
	var projectiles_list = _get_safe_array(game_state, "projectiles")
	for proj in projectiles_list:
		if not (proj is Dictionary): continue
		var proj_id = _get_safe_string(proj, "id", "")
		var p_pos = smooth_positions.get(proj_id)
		if p_pos == null:
			p_pos = _get_safe_vector2(proj, "pos")
			
		var vel = _get_safe_vector2(proj, "vel", Vector2(1.0, 0.0)).normalized()
		
		# Draw arrow stick
		var length = 22.0
		var start_p = p_pos - vel * length
		var arrow_color = Color(1.0, 0.85, 0.3)
		var proj_team = _get_safe_string(proj, "team", "blue")
		if proj_team == "blue":
			arrow_color = Color(0.4, 0.7, 1.0)
		elif proj_team == "red":
			arrow_color = Color(1.0, 0.4, 0.4)
			
		world_node.draw_line(start_p, p_pos, arrow_color, 3.0)
		
		# Arrow head
		var head_angle = vel.angle()
		var pts = PackedVector2Array([
			p_pos,
			p_pos + Vector2(cos(head_angle + 2.5), sin(head_angle + 2.5)) * 8,
			p_pos + Vector2(cos(head_angle - 2.5), sin(head_angle - 2.5)) * 8
		])
		world_node.draw_colored_polygon(pts, arrow_color)

	# Draw Towers & Core Bases
	var towers_list = _get_safe_array(game_state, "towers")
	for t in towers_list:
		if not (t is Dictionary): continue
		var t_pos = _get_safe_vector2(t, "pos")
		var t_team = _get_safe_string(t, "team", "blue")
		var t_color = Color(0.3, 0.5, 1.0) if t_team == "blue" else Color(1.0, 0.3, 0.3)
		var range_color = Color(0.3, 0.5, 1.0, 0.08) if t_team == "blue" else Color(1.0, 0.3, 0.3, 0.08)
		
		if _get_safe_bool(t, "is_base", false):
			# Draw Giant Base Octagon
			var base_radius = 80.0
			var pts = PackedVector2Array()
			for i in range(8):
				var a = i * (PI / 4)
				pts.append(t_pos + Vector2(cos(a), sin(a)) * base_radius)
			
			world_node.draw_colored_polygon(pts, Color(0.15, 0.18, 0.22))
			world_node.draw_polyline(pts, t_color, 4.0)
			
			# Inside core orb
			world_node.draw_circle(t_pos, 35.0, t_color)
			world_node.draw_circle(t_pos, 20.0, Color.WHITE)
			
			# Range circle
			world_node.draw_circle(t_pos, 550.0, range_color)
			world_node.draw_circle(t_pos, 550.0, t_color * Color(1.0, 1.0, 1.0, 0.3), false, 2.0)
			
			# Base HP bar
			_draw_entity_health_bar(world_node, t_pos + Vector2(0, -95), _get_safe_float(t, "hp", 0.0), _get_safe_float(t, "max_hp", 1.0), 150, 12)
		else:
			# Standard Defense Tower
			world_node.draw_circle(t_pos, 45.0, Color(0.18, 0.22, 0.26))
			world_node.draw_circle(t_pos, 45.0, t_color, false, 3.0)
			world_node.draw_circle(t_pos, 25.0, t_color)
			
			# Range circle
			world_node.draw_circle(t_pos, 400.0, range_color)
			world_node.draw_circle(t_pos, 400.0, t_color * Color(1.0, 1.0, 1.0, 0.3), false, 1.5)
			
			# HP bar
			_draw_entity_health_bar(world_node, t_pos + Vector2(0, -60), _get_safe_float(t, "hp", 0.0), _get_safe_float(t, "max_hp", 1.0), 80, 8)

	# Draw Minions
	var minions_list = _get_safe_array(game_state, "minions")
	for m in minions_list:
		if not (m is Dictionary): continue
		var m_id = _get_safe_string(m, "id", "")
		var m_pos = smooth_positions.get(m_id)
		if m_pos == null:
			m_pos = _get_safe_vector2(m, "pos")
			
		var m_team = _get_safe_string(m, "team", "blue")
		var m_color = Color(0.4, 0.6, 1.0) if m_team == "blue" else Color(1.0, 0.5, 0.5)
		
		# Draw minion circle body
		world_node.draw_circle(m_pos, 18.0, m_color)
		world_node.draw_circle(m_pos, 18.0, Color.BLACK, false, 1.5)
		
		# Eyes/indicator
		var target_vel = Vector2(_get_safe_float(m, "target_x", 0.0) - m_pos.x, _get_safe_float(m, "target_y", 0.0) - m_pos.y).normalized()
		world_node.draw_line(m_pos, m_pos + target_vel * 15.0, Color.BLACK, 3.0)
		
		# HP bar
		_draw_entity_health_bar(world_node, m_pos + Vector2(0, -25), _get_safe_float(m, "hp", 0.0), _get_safe_float(m, "max_hp", 1.0), 30, 4)

	# Draw Players
	var players_list = _get_safe_array(game_state, "players")
	for p in players_list:
		if not (p is Dictionary): continue
		var p_id = _get_safe_string(p, "id", "")
		if p_id == "": continue
		
		var p_pos = smooth_positions.get(p_id)
		if p_pos == null:
			p_pos = _get_safe_vector2(p, "pos")
			
		if _get_safe_bool(p, "dead", false):
			# Draw small dead marker if not me, or standard if me
			if p_id == client_id:
				world_node.draw_string(system_font, p_pos, "☠️ RESPAWNING...", HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color.RED)
			continue
			
		var p_team = _get_safe_string(p, "team", "blue")
		var p_color = Color(0.3, 0.5, 1.0) if p_team == "blue" else Color(1.0, 0.3, 0.3)
		var accent_color = Color.WHITE
		if p_id == client_id:
			accent_color = Color(1.0, 0.9, 0.3) # Gold outline for current client player!
		
		# Check if player is hiding in bushes
		var is_stealthy = false
		for b in grass_bushes:
			if p_pos.distance_to(b.pos) < b.radius:
				is_stealthy = true
				break
				
		var p_alpha = 1.0
		if is_stealthy:
			# Hide from enemies if they are outside, but show transparent to allies
			if p_team != my_team:
				# Check if my player is also in the SAME bush, otherwise he is fully hidden!
				var am_i_near_bush = false
				if my_player_data is Dictionary:
					var my_curr_pos = _get_safe_vector2(my_player_data, "pos")
					for b in grass_bushes:
						if my_curr_pos.distance_to(b.pos) < b.radius and p_pos.distance_to(b.pos) < b.radius:
							am_i_near_bush = true
							break
				if not am_i_near_bush:
					continue # HIDE PLAYER FROM RENDER!
			p_alpha = 0.4
			
		var col = Color(p_color.r, p_color.g, p_color.b, p_alpha)
		var acc = Color(accent_color.r, accent_color.g, accent_color.b, p_alpha)
		
		# Draw outer outline
		world_node.draw_circle(p_pos, 25.0, acc)
		# Draw main body
		world_node.draw_circle(p_pos, 22.0, col)
		# Draw center core
		world_node.draw_circle(p_pos, 8.0, Color(0, 0, 0, p_alpha * 0.4))
		
		# Facing Nose (Gun pointer)
		var angle = _get_safe_float(p, "angle", 0.0)
		var f_dir = Vector2(cos(angle), sin(angle))
		world_node.draw_line(p_pos, p_pos + f_dir * 33.0, acc, 4.0)
		world_node.draw_line(p_pos, p_pos + f_dir * 33.0, col, 2.0)
		
		# Name plate and Level badge
		var p_name = _get_safe_string(p, "name", "Archer")
		if _get_safe_bool(p, "is_bot", false):
			p_name = "🤖 " + p_name
		var badge_str = "Lvl " + str(_get_safe_int(p, "level", 1)) + " " + p_name
		world_node.draw_string(system_font, p_pos + Vector2(-60, -42), badge_str, HORIZONTAL_ALIGNMENT_CENTER, 120, 12, acc)
		
		# Health Bar
		_draw_entity_health_bar(world_node, p_pos + Vector2(0, -32), _get_safe_float(p, "hp", 0.0), _get_safe_float(p, "max_hp", 1.0), 45, 5, p_alpha)

	# Draw Hit Sparks particles
	for s in hit_sparks:
		world_node.draw_circle(s.pos, s.size, s.color)

	# Draw Floating Damage/XP Texts
	for t in damage_texts:
		world_node.draw_string(system_font, t.pos, t.text, HORIZONTAL_ALIGNMENT_CENTER, 80, 16, t.color)

func _draw_entity_health_bar(canvas: Node2D, pos: Vector2, hp: float, max_hp: float, width: int, height: int, alpha: float = 1.0):
	var half_w = width / 2.0
	var bar_rect = Rect2(pos.x - half_w, pos.y, width, height)
	var hp_ratio = clamp(hp / max_hp, 0.0, 1.0)
	var hp_w = width * hp_ratio
	var hp_rect = Rect2(pos.x - half_w, pos.y, hp_w, height)
	
	# Background
	canvas.draw_rect(bar_rect, Color(0.1, 0.1, 0.1, alpha * 0.7), true)
	# Health green overlay
	var green_color = Color(0.2, 0.9, 0.3, alpha)
	if hp_ratio < 0.3:
		green_color = Color(1.0, 0.2, 0.2, alpha) # red when low hp
	canvas.draw_rect(hp_rect, green_color, true)
	# Frame
	canvas.draw_rect(bar_rect, Color(0.0, 0.0, 0.0, alpha * 0.8), false, 1.0)

func _update_smooth_positions(delta):
	var active_ids = {}
	
	# Interpolate Player positions safely
	var players_list = _get_safe_array(game_state, "players")
	for p in players_list:
		if not (p is Dictionary): continue
		var id = _get_safe_string(p, "id", "")
		if id == "": continue
		active_ids[id] = true
		
		var server_pos = _get_safe_vector2(p, "pos")
			
		if not smooth_positions.has(id):
			smooth_positions[id] = server_pos
		else:
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, 18.0 * delta)
			
	# Interpolate Minion positions safely
	var minions_list = _get_safe_array(game_state, "minions")
	for m in minions_list:
		if not (m is Dictionary): continue
		var id = _get_safe_string(m, "id", "")
		if id == "": continue
		active_ids[id] = true
		
		var server_pos = _get_safe_vector2(m, "pos")
			
		if not smooth_positions.has(id):
			smooth_positions[id] = server_pos
		else:
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, 18.0 * delta)
			
	# Interpolate Projectile positions safely
	var projectiles_list = _get_safe_array(game_state, "projectiles")
	for proj in projectiles_list:
		if not (proj is Dictionary): continue
		var id = _get_safe_string(proj, "id", "")
		if id == "": continue
		active_ids[id] = true
		
		var server_pos = _get_safe_vector2(proj, "pos")
			
		if not smooth_positions.has(id):
			smooth_positions[id] = server_pos
		else:
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, 26.0 * delta)

	# Interpolate Gem positions safely
	var gems_list = _get_safe_array(game_state, "gems")
	for g in gems_list:
		if not (g is Dictionary): continue
		var id = _get_safe_string(g, "id", "")
		if id == "": continue
		active_ids[id] = true
		
		var server_pos = _get_safe_vector2(g, "pos")
			
		if not smooth_positions.has(id):
			smooth_positions[id] = server_pos
		else:
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, 12.0 * delta)
			
	# Clean up positions for removed entities
	var old_ids = smooth_positions.keys()
	for id in old_ids:
		if not active_ids.has(id):
			smooth_positions.erase(id)

# --- Safe JSON Parsing Helpers ---

func _get_safe_dict(dict: Variant, key: String) -> Dictionary:
	if not (dict is Dictionary):
		return {}
	var val = dict.get(key)
	if val is Dictionary:
		return val
	return {}

func _get_safe_array(dict: Variant, key: String) -> Array:
	if not (dict is Dictionary):
		return []
	var val = dict.get(key)
	if val is Array:
		return val
	return []

func _get_safe_string(dict: Variant, key: String, default_val: String = "") -> String:
	if not (dict is Dictionary):
		return default_val
	var val = dict.get(key)
	if val == null:
		return default_val
	return str(val)

func _get_safe_float(dict: Variant, key: String, default_val: float = 0.0) -> float:
	if not (dict is Dictionary):
		return default_val
	var val = dict.get(key)
	if val == null:
		return default_val
	return float(val)

func _get_safe_int(dict: Variant, key: String, default_val: int = 0) -> int:
	if not (dict is Dictionary):
		return default_val
	var val = dict.get(key)
	if val == null:
		return default_val
	return int(val)

func _get_safe_bool(dict: Variant, key: String, default_val: bool = false) -> bool:
	if not (dict is Dictionary):
		return default_val
	var val = dict.get(key)
	if val == null:
		return default_val
	return bool(val)

func _get_safe_vector2(dict: Variant, key: String, default_val: Vector2 = Vector2.ZERO) -> Vector2:
	var d = _get_safe_dict(dict, key)
	if d.is_empty():
		return default_val
	return Vector2(
		_get_safe_float(d, "x", default_val.x),
		_get_safe_float(d, "y", default_val.y)
	)
