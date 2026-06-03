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

# --- Virtual Touchscreen Controls ---
var joystick_active: bool = false
var joystick_center: Vector2 = Vector2.ZERO
var joystick_pos: Vector2 = Vector2.ZERO
var joystick_touch_index: int = -1
const JOYSTICK_MAX_DRAG = 70.0
var joystick_draw_node: Control = null

var aim_active: bool = false
var aim_center: Vector2 = Vector2.ZERO
var aim_pos: Vector2 = Vector2.ZERO
var aim_touch_index: int = -1
var hero_select_btn: OptionButton
var client_shoot_cooldown: float = 0.0

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
	
	# Dynamic OptionButton for Hero Selection
	hero_select_btn = OptionButton.new()
	hero_select_btn.add_item("🏹 Ranger (Multi Shot Lvl 1, Speed 300)", 0)
	hero_select_btn.add_item("🛡️ Knight (HP Boost Lvl 1, HP 150)", 1)
	hero_select_btn.add_item("🔥 Mage (Fire Arrow Lvl 1, Speed 260)", 2)
	hero_select_btn.selected = 0
	$UI/Lobby/Panel/VBox.add_child(hero_select_btn)
	$UI/Lobby/Panel/VBox.move_child(hero_select_btn, $UI/Lobby/Panel/VBox.get_child_count() - 2)
	
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
	
	# Create programmatic HUD overlay for Touch Joystick drawing
	joystick_draw_node = Control.new()
	joystick_draw_node.name = "JoystickHUD"
	joystick_draw_node.set_anchors_preset(Control.PRESET_FULL_RECT)
	joystick_draw_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$UI/HUD.add_child(joystick_draw_node)
	joystick_draw_node.draw.connect(_on_joystick_draw)
	
	# Generate some decorative grass/stealth bushes
	randomize()
	for i in range(20):
		grass_bushes.append({
			"pos": Vector2(randf_range(200, 2800), randf_range(100, 1100)),
			"radius": randf_range(60, 95)
		})
	
	# Initial window setup
	get_viewport().files_dropped.connect(func(files): pass)

func _input(event: InputEvent):
	if not is_connected or not (my_player_data is Dictionary) or _get_safe_bool(my_player_data, "dead", false):
		# Cleanup if we disconnected or died
		if joystick_active or aim_active:
			joystick_active = false
			joystick_touch_index = -1
			aim_active = false
			aim_touch_index = -1
			if joystick_draw_node:
				joystick_draw_node.queue_redraw()
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			# Touch pressed
			if event.position.x < get_viewport_rect().size.x / 2.0:
				# Left half: Floating Joystick
				if not joystick_active:
					joystick_active = true
					joystick_center = event.position
					joystick_pos = event.position
					joystick_touch_index = event.index
					if joystick_draw_node:
						joystick_draw_node.queue_redraw()
			else:
				# Right half: Floating Aim & Manual Shoot
				if not aim_active:
					aim_active = true
					aim_center = event.position
					aim_pos = event.position
					aim_touch_index = event.index
					if joystick_draw_node:
						joystick_draw_node.queue_redraw()
		else:
			# Touch released
			if event.index == joystick_touch_index:
				joystick_active = false
				joystick_touch_index = -1
				last_move_dir = Vector2.ZERO
				var msg = {
					"type": "move",
					"is_moving": false,
					"x": 0.0,
					"y": 0.0,
					"angle": last_angle
				}
				socket.send_text(JSON.stringify(msg))
				if joystick_draw_node:
					joystick_draw_node.queue_redraw()
			elif event.index == aim_touch_index:
				var drag_offset = aim_pos - aim_center
				if drag_offset.length() < 18.0:
					_trigger_quick_tap_shoot()
				aim_active = false
				aim_touch_index = -1
				if joystick_draw_node:
					joystick_draw_node.queue_redraw()
					
	elif event is InputEventScreenDrag:
		if event.index == joystick_touch_index and joystick_active:
			var offset = event.position - joystick_center
			if offset.length() > JOYSTICK_MAX_DRAG:
				offset = offset.normalized() * JOYSTICK_MAX_DRAG
			joystick_pos = joystick_center + offset
			
			var move_dir = offset / JOYSTICK_MAX_DRAG
			if move_dir.length() > 0.15:
				var angle = move_dir.angle()
				last_angle = angle
				last_move_dir = move_dir
				var msg = {
					"type": "move",
					"is_moving": true,
					"x": move_dir.x,
					"y": move_dir.y,
					"angle": angle
				}
				socket.send_text(JSON.stringify(msg))
			else:
				last_move_dir = Vector2.ZERO
				var msg = {
					"type": "move",
					"is_moving": false,
					"x": 0.0,
					"y": 0.0,
					"angle": last_angle
				}
				socket.send_text(JSON.stringify(msg))
				
			if joystick_draw_node:
				joystick_draw_node.queue_redraw()
				
		elif event.index == aim_touch_index and aim_active:
			var offset = event.position - aim_center
			if offset.length() > JOYSTICK_MAX_DRAG:
				offset = offset.normalized() * JOYSTICK_MAX_DRAG
			aim_pos = aim_center + offset
				
			if joystick_draw_node:
				joystick_draw_node.queue_redraw()

func _on_joystick_draw():
	if joystick_active:
		# Draw outer ring with glassmorphic transparent look
		joystick_draw_node.draw_circle(joystick_center, JOYSTICK_MAX_DRAG, Color(1, 1, 1, 0.08))
		joystick_draw_node.draw_arc(joystick_center, JOYSTICK_MAX_DRAG, 0.0, TAU, 36, Color(0.3, 0.7, 1.0, 0.35), 3.0)
		joystick_draw_node.draw_arc(joystick_center, JOYSTICK_MAX_DRAG - 2, 0.0, TAU, 36, Color(0.3, 0.7, 1.0, 0.1), 1.0)
		# Draw center anchor point
		joystick_draw_node.draw_circle(joystick_center, 6.0, Color(0.3, 0.7, 1.0, 0.5))
		
		# Draw floating drag handle (cyan glow)
		joystick_draw_node.draw_circle(joystick_pos, 28.0, Color(0.3, 0.7, 1.0, 0.25))
		joystick_draw_node.draw_circle(joystick_pos, 24.0, Color(0.3, 0.7, 1.0, 0.75))
		joystick_draw_node.draw_arc(joystick_pos, 24.0, 0.0, TAU, 24, Color.WHITE, 2.0)
		
	if aim_active:
		# Draw outer ring for aiming (red glow, matches JOYSTICK_MAX_DRAG)
		joystick_draw_node.draw_circle(aim_center, JOYSTICK_MAX_DRAG, Color(1, 1, 1, 0.08))
		joystick_draw_node.draw_arc(aim_center, JOYSTICK_MAX_DRAG, 0.0, TAU, 36, Color(1.0, 0.3, 0.3, 0.35), 3.0)
		joystick_draw_node.draw_arc(aim_center, JOYSTICK_MAX_DRAG - 2, 0.0, TAU, 36, Color(1.0, 0.3, 0.3, 0.1), 1.0)
		joystick_draw_node.draw_circle(aim_center, 6.0, Color(1.0, 0.3, 0.3, 0.5))
		
		# Draw floating aim handle (red glow)
		joystick_draw_node.draw_circle(aim_pos, 28.0, Color(1.0, 0.3, 0.3, 0.25))
		joystick_draw_node.draw_circle(aim_pos, 24.0, Color(1.0, 0.3, 0.3, 0.75))
		joystick_draw_node.draw_arc(aim_pos, 24.0, 0.0, TAU, 24, Color.WHITE, 2.0)
		
		# Draw line representing the direction of shoot
		var offset = aim_pos - aim_center
		if offset.length() > 15.0:
			var dir = offset.normalized()
			var line_end = aim_center + dir * (JOYSTICK_MAX_DRAG - 5.0)
			# Draw indicator arrow line
			joystick_draw_node.draw_line(aim_center, line_end, Color(1.0, 0.3, 0.3, 0.8), 4.0)
			# Draw arrow head
			var arrow_angle = dir.angle()
			var arrow_pts = PackedVector2Array([
				line_end,
				line_end + Vector2(cos(arrow_angle + 2.4), sin(arrow_angle + 2.4)) * 12,
				line_end + Vector2(cos(arrow_angle - 2.4), sin(arrow_angle - 2.4)) * 12
			])
			joystick_draw_node.draw_colored_polygon(arrow_pts, Color(1.0, 0.3, 0.3, 0.9))

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
		
	# Append query param for nickname and hero class selection
	var selected_hero_idx = hero_select_btn.selected
	var ws_url = server_url + "?name=" + nickname.uri_encode() + "&hero=" + str(selected_hero_idx)
	
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
			screen_shake = lerp(screen_shake, 0.0, clamp(10.0 * delta, 0.0, 1.0))
			
		var cam_weight = clamp(8.0 * delta, 0.0, 1.0)
		$Camera2D.position = $Camera2D.position.lerp(target_cam_pos, cam_weight) + shake_offset
	
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
	if client_shoot_cooldown > 0:
		client_shoot_cooldown -= delta

	var want_shoot = false
	var shoot_angle = 0.0

	if aim_active:
		# Mobile touch aiming
		var offset = aim_pos - aim_center
		if offset.length() > 15.0:
			want_shoot = true
			shoot_angle = offset.angle()
	elif Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not is_chatting:
		# Desktop mouse aiming
		var mouse_pos = get_global_mouse_position()
		if my_player_data is Dictionary:
			var p_pos = _get_safe_vector2(my_player_data, "pos")
			want_shoot = true
			shoot_angle = (mouse_pos - p_pos).angle()

	if want_shoot:
		if client_shoot_cooldown <= 0:
			var msg = {
				"type": "shoot",
				"angle": shoot_angle
			}
			socket.send_text(JSON.stringify(msg))
			
			# Calculate cooldown locally to match server base classes
			var base_cd = 0.25
			var hero = _get_safe_string(my_player_data, "hero", "ranger")
			if hero == "knight":
				base_cd = 0.40
			elif hero == "mage":
				base_cd = 0.35
			
			var atk_speed_lvl = 0
			if my_player_data is Dictionary:
				var skills = my_player_data.get("skills", {})
				if skills is Dictionary:
					atk_speed_lvl = skills.get("atk_speed", 0)
			
			client_shoot_cooldown = base_cd * pow(0.85, atk_speed_lvl) - 0.02 # 20ms margin

func _trigger_quick_tap_shoot():
	# Find nearest enemy in range and fire
	if game_state is Dictionary and my_player_data is Dictionary:
		var my_pos = _get_safe_vector2(my_player_data, "pos")
		var nearest_enemy = null
		var min_dist = 600.0 # Auto shoot range
		
		# Find nearest player
		var players = _get_safe_array(game_state, "players")
		for p in players:
			if not (p is Dictionary): continue
			if _get_safe_string(p, "id") == client_id or _get_safe_bool(p, "dead"):
				continue
			if _get_safe_string(p, "team") != my_team:
				var p_pos = _get_safe_vector2(p, "pos")
				var dist = my_pos.distance_to(p_pos)
				if dist < min_dist:
					min_dist = dist
					nearest_enemy = p_pos
					
		# Find nearest minion
		var minions = _get_safe_array(game_state, "minions")
		for m in minions:
			if not (m is Dictionary): continue
			if _get_safe_string(m, "team") != my_team:
				var m_pos = _get_safe_vector2(m, "pos")
				var dist = my_pos.distance_to(m_pos)
				if dist < min_dist:
					min_dist = dist
					nearest_enemy = m_pos
					
		# Find nearest tower
		var towers = _get_safe_array(game_state, "towers")
		for t in towers:
			if not (t is Dictionary): continue
			if _get_safe_string(t, "team") != my_team:
				var t_pos = _get_safe_vector2(t, "pos")
				var dist = my_pos.distance_to(t_pos)
				if dist < min_dist:
					min_dist = dist
					nearest_enemy = t_pos
					
		if nearest_enemy != null:
			var shoot_angle = (nearest_enemy - my_pos).angle()
			var msg = {
				"type": "shoot",
				"angle": shoot_angle
			}
			socket.send_text(JSON.stringify(msg))
			
			# Trigger local cooldown
			var base_cd = 0.25
			var hero = _get_safe_string(my_player_data, "hero", "ranger")
			if hero == "knight":
				base_cd = 0.40
			elif hero == "mage":
				base_cd = 0.35
			var atk_speed_lvl = 0
			var skills = my_player_data.get("skills", {})
			if skills is Dictionary:
				atk_speed_lvl = skills.get("atk_speed", 0)
			client_shoot_cooldown = base_cd * pow(0.85, atk_speed_lvl) - 0.02

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
	var time_ms = Time.get_ticks_msec()
	
	# Determine current screen viewport to optimize draw calls and stay locked at 60 FPS
	var cam_pos = $Camera2D.position
	var view_min = cam_pos - Vector2(700, 420)
	var view_max = cam_pos + Vector2(700, 420)
	
	# 1. Fill Map Background (Ultra-sleek dark space tech color palette)
	var background_color = Color(0.04, 0.05, 0.07)
	var grid_color = Color(0.08, 0.12, 0.18)
	world_node.draw_rect(Rect2(0, 0, 3000, 1200), background_color, true)
	
	# 2. Draw Background Grid (Culled to screen view for high performance)
	var grid_size = 100
	var start_x = int(max(0, floor(view_min.x / grid_size) * grid_size))
	var end_x = int(min(3000, ceil(view_max.x / grid_size) * grid_size))
	var start_y = int(max(0, floor(view_min.y / grid_size) * grid_size))
	var end_y = int(min(1200, ceil(view_max.y / grid_size) * grid_size))
	
	for x in range(start_x, end_x + 1, grid_size):
		world_node.draw_line(Vector2(x, max(0, view_min.y)), Vector2(x, min(1200, view_max.y)), grid_color, 1.0)
	for y in range(start_y, end_y + 1, grid_size):
		world_node.draw_line(Vector2(max(0, view_min.x), y), Vector2(min(3000, view_max.x), y), grid_color, 1.0)
		
	# Tech dots at grid intersections for premium cyberpunk matrix styling
	var dot_color = Color(0.18, 0.36, 0.6, 0.35)
	for x in range(start_x, end_x + 1, grid_size):
		for y in range(start_y, end_y + 1, grid_size):
			if x >= 0 and x <= 3000 and y >= 0 and y <= 1200:
				world_node.draw_rect(Rect2(x - 2, y - 2, 4, 4), dot_color, true)
				
	# Outer Border (Glowing boundaries)
	world_node.draw_rect(Rect2(0, 0, 3000, 1200), Color(0.2, 0.5, 0.8, 0.25), false, 7.0)
	world_node.draw_rect(Rect2(0, 0, 3000, 1200), Color(0.3, 0.7, 1.0, 0.8), false, 2.0)

	# 3. Draw Stealth Grass/Bushes (Neon digital camouflage fields)
	for b in grass_bushes:
		if b.pos.distance_to(cam_pos) > b.radius + 800.0:
			continue
		# Pulsing outer ring
		var pulse_radius = b.radius + 3.0 * sin(time_ms * 0.003 + b.pos.x * 0.01)
		world_node.draw_circle(b.pos, pulse_radius + 5.0, Color(0.1, 0.4, 0.25, 0.08))
		# Translucent camo center
		world_node.draw_circle(b.pos, pulse_radius, Color(0.08, 0.25, 0.16, 0.6))
		# Glowing neon outline
		world_node.draw_arc(b.pos, pulse_radius, 0.0, TAU, 32, Color(0.2, 0.85, 0.4, 0.75), 2.0)
		# Floating internal energy particles
		for i in range(3):
			var angle_offset = time_ms * 0.0008 + i * (TAU / 3.0)
			var offset_r = (b.radius * 0.5) + 5.0 * sin(time_ms * 0.002 + i)
			var part_pos = b.pos + Vector2(cos(angle_offset), sin(angle_offset)) * offset_r
			world_node.draw_circle(part_pos, 2.5, Color(0.4, 1.0, 0.6, 0.6))

	# 4. Draw Obstacle Walls (Hazard cybernetic core walls)
	for w in walls:
		if w.x + w.w < view_min.x or w.x > view_max.x or w.y + w.h < view_min.y or w.y > view_max.y:
			continue
		var r = Rect2(w.x, w.y, w.w, w.h)
		# Charcoal core
		world_node.draw_rect(r, Color(0.06, 0.08, 0.12, 0.85), true)
		# Diagonal safety stripe design
		var stripe_color = Color(0.12, 0.22, 0.32, 0.4)
		var step = 40.0
		for i in range(0, int(w.w + w.h), int(step)):
			var start = Vector2(w.x + max(0, i - w.h), w.y + min(w.h, i))
			var end = Vector2(w.x + min(w.w, i), w.y + max(0, i - w.w))
			world_node.draw_line(start, end, stripe_color, 2.0)
		# Glowing cyan neon border
		world_node.draw_rect(r, Color(0.15, 0.7, 1.0, 0.22), false, 5.0)
		world_node.draw_rect(r, Color(0.2, 0.8, 1.0, 0.85), false, 2.0)

	# 5. Draw Gems (Rotating & Floating items with drop shadows)
	var gems_list = _get_safe_array(game_state, "gems")
	for g in gems_list:
		if not (g is Dictionary): continue
		var g_id = _get_safe_string(g, "id", "")
		var g_pos = smooth_positions.get(g_id)
		if g_pos == null:
			g_pos = _get_safe_vector2(g, "pos")
			
		if g_pos.distance_to(cam_pos) > 800.0:
			continue
			
		var phase = float(g_id.hash() % 100) * 0.1
		var float_offset = Vector2(0.0, 5.0 * sin(time_ms * 0.004 + phase))
		var angle_rot = time_ms * 0.003 + phase
		var final_pos = g_pos + float_offset
		
		if _get_safe_string(g, "type", "xp") == "hp":
			# Glowing red base shadow
			world_node.draw_circle(g_pos + Vector2(0, 8), 8.0, Color(1.0, 0.2, 0.2, 0.18))
			# HP: spinning cross
			var raw_pts = [
				Vector2(-7, -2.5), Vector2(-2.5, -2.5), Vector2(-2.5, -7), Vector2(2.5, -7),
				Vector2(2.5, -2.5), Vector2(7, -2.5), Vector2(7, 2.5), Vector2(2.5, 2.5),
				Vector2(2.5, 7), Vector2(-2.5, 7), Vector2(-2.5, 2.5), Vector2(-7, 2.5)
			]
			var rotated_pts = PackedVector2Array()
			for pt in raw_pts:
				rotated_pts.append(final_pos + pt.rotated(angle_rot))
			world_node.draw_colored_polygon(rotated_pts, Color(1.0, 0.3, 0.3))
			world_node.draw_polyline(rotated_pts, Color(1.0, 0.85, 0.85), 1.5)
		else:
			# Glowing green base shadow
			world_node.draw_circle(g_pos + Vector2(0, 8), 7.0, Color(0.2, 0.9, 0.4, 0.18))
			# XP: spinning diamond
			var raw_pts = [
				Vector2(0, -9),
				Vector2(6.5, 0),
				Vector2(0, 9),
				Vector2(-6.5, 0)
			]
			var rotated_pts = PackedVector2Array()
			for pt in raw_pts:
				rotated_pts.append(final_pos + pt.rotated(angle_rot))
			world_node.draw_colored_polygon(rotated_pts, Color(0.25, 0.95, 0.55))
			world_node.draw_polyline(rotated_pts, Color(0.7, 1.0, 0.8), 1.5)

	# 6. Draw Projectiles/Arrows (Plasma projectiles with trails & intensity cores)
	var projectiles_list = _get_safe_array(game_state, "projectiles")
	for proj in projectiles_list:
		if not (proj is Dictionary): continue
		var proj_id = _get_safe_string(proj, "id", "")
		var p_pos = smooth_positions.get(proj_id)
		if p_pos == null:
			p_pos = _get_safe_vector2(proj, "pos")
			
		if p_pos.distance_to(cam_pos) > 850.0:
			continue
			
		var vel = _get_safe_vector2(proj, "vel", Vector2(1.0, 0.0)).normalized()
		var proj_team = _get_safe_string(proj, "team", "blue")
		var arrow_color = Color(0.4, 0.7, 1.0) if proj_team == "blue" else Color(1.0, 0.4, 0.4)
		
		# Detect active elemental effects
		var effects = _get_safe_array(proj, "effects")
		var is_fire = false
		var is_ice = false
		var is_poison = false
		for eff in effects:
			if eff == "fire": is_fire = true
			elif eff == "ice": is_ice = true
			elif eff == "poison": is_poison = true
			
		if is_fire:
			arrow_color = Color(1.0, 0.45, 0.1) # Bright fire orange
		elif is_ice:
			arrow_color = Color(0.2, 0.85, 1.0) # Frozen cyan
		elif is_poison:
			arrow_color = Color(0.75, 0.15, 0.9) # Acid purple
		
		# Draw trailing plasma beam glow
		var trail_length = 26.0
		var back_p = p_pos - vel * trail_length
		
		# Wider soft glow
		world_node.draw_line(back_p - vel * 4.0, p_pos, Color(arrow_color.r, arrow_color.g, arrow_color.b, 0.2), 6.0)
		# Solid core line
		world_node.draw_line(back_p, p_pos, arrow_color, 2.5)
		
		var head_angle = vel.angle()
		if is_ice:
			# Shard shape for ice
			var ice_pts = PackedVector2Array([
				p_pos,
				p_pos - vel.rotated(0.35) * 12.0,
				p_pos - vel * 18.0,
				p_pos - vel.rotated(-0.35) * 12.0
			])
			world_node.draw_colored_polygon(ice_pts, Color(0.4, 0.9, 1.0, 0.95))
			world_node.draw_polyline(ice_pts, Color.WHITE, 1.5)
		elif is_fire:
			# Fireball flame polygon (wiggles slightly)
			var fire_pts = PackedVector2Array([
				p_pos + vel * 3.0,
				p_pos - vel.rotated(0.6) * 10.0 + vel.orthogonal() * 2.0 * sin(time_ms * 0.05),
				p_pos - vel * 15.0,
				p_pos - vel.rotated(-0.6) * 10.0 - vel.orthogonal() * 2.0 * sin(time_ms * 0.05)
			])
			world_node.draw_colored_polygon(fire_pts, Color(1.0, 0.35, 0.0))
			world_node.draw_polyline(fire_pts, Color(1.0, 0.9, 0.3), 1.0)
			world_node.draw_circle(p_pos - vel * 2.0, 3.5, Color.WHITE)
		elif is_poison:
			# Bubble blob for poison
			world_node.draw_circle(p_pos, 5.0, Color(0.8, 0.1, 1.0))
			world_node.draw_circle(p_pos - vel * 6.0, 3.5, Color(0.6, 0.05, 0.9))
			world_node.draw_circle(p_pos - vel * 12.0, 2.5, Color(0.5, 0.0, 0.8))
			world_node.draw_circle(p_pos, 2.0, Color.WHITE)
		else:
			# Normal arrow head
			var pts = PackedVector2Array([
				p_pos,
				p_pos + Vector2(cos(head_angle + 2.5), sin(head_angle + 2.5)) * 8.5,
				p_pos + Vector2(cos(head_angle - 2.5), sin(head_angle - 2.5)) * 8.5
			])
			world_node.draw_colored_polygon(pts, arrow_color)
			world_node.draw_circle(p_pos - vel * 2.0, 2.0, Color.WHITE)

	# 7. Draw Towers & Core Bases (Pulsing base orbs, rotating cyber shields, range rings)
	var towers_list = _get_safe_array(game_state, "towers")
	for t in towers_list:
		if not (t is Dictionary): continue
		var t_pos = _get_safe_vector2(t, "pos")
		var t_team = _get_safe_string(t, "team", "blue")
		var t_color = Color(0.3, 0.5, 1.0) if t_team == "blue" else Color(1.0, 0.3, 0.3)
		var range_color = Color(0.3, 0.5, 1.0, 0.08) if t_team == "blue" else Color(1.0, 0.3, 0.3, 0.08)
		
		if t_pos.distance_to(cam_pos) > 950.0:
			continue
			
		var shield_angle = time_ms * 0.0012 if t_team == "blue" else -time_ms * 0.0012
		var pulse_scale = 1.0 + 0.05 * sin(time_ms * 0.006 + (t_pos.x * 0.01))
		
		if _get_safe_bool(t, "is_base", false):
			# Base HP bar
			_draw_entity_health_bar(world_node, t_pos + Vector2(0, -95), _get_safe_float(t, "hp", 0.0), _get_safe_float(t, "max_hp", 1.0), 150, 12)
			
			# Range circle (Dashed cyber target ring)
			var range_rad = 550.0
			world_node.draw_circle(t_pos, range_rad, range_color)
			var segments = 24
			for i in range(segments):
				var a1 = i * (TAU / segments) + time_ms * 0.0001
				var a2 = a1 + (TAU / segments) * 0.5
				world_node.draw_arc(t_pos, range_rad, a1, a2, 16, t_color * Color(1.0, 1.0, 1.0, 0.25), 1.5)
			
			# Octagonal outer neon structure
			var base_radius = 80.0 * pulse_scale
			var pts = PackedVector2Array()
			for i in range(8):
				var a = i * (PI / 4) + shield_angle * 0.3
				pts.append(t_pos + Vector2(cos(a), sin(a)) * base_radius)
			world_node.draw_colored_polygon(pts, Color(0.06, 0.09, 0.12, 0.9))
			world_node.draw_polyline(pts, t_color, 4.0)
			
			# Rotating vector shield lines
			var tri_pts = PackedVector2Array([
				t_pos + Vector2(cos(shield_angle), sin(shield_angle)) * 60,
				t_pos + Vector2(cos(shield_angle + 2.0), sin(shield_angle + 2.0)) * 60,
				t_pos + Vector2(cos(shield_angle + 4.0), sin(shield_angle + 4.0)) * 60
			])
			world_node.draw_polyline(tri_pts, t_color * Color(1, 1, 1, 0.45), 2.5)
			
			# Core orb
			world_node.draw_circle(t_pos, 32.0 * pulse_scale, t_color)
			world_node.draw_circle(t_pos, 16.0 * pulse_scale, Color.WHITE)
		else:
			# HP bar
			_draw_entity_health_bar(world_node, t_pos + Vector2(0, -60), _get_safe_float(t, "hp", 0.0), _get_safe_float(t, "max_hp", 1.0), 80, 8)
			
			# Range circle
			var range_rad = 400.0
			world_node.draw_circle(t_pos, range_rad, range_color)
			var segments = 16
			for i in range(segments):
				var a1 = i * (TAU / segments) - time_ms * 0.0001
				var a2 = a1 + (TAU / segments) * 0.5
				world_node.draw_arc(t_pos, range_rad, a1, a2, 12, t_color * Color(1.0, 1.0, 1.0, 0.25), 1.2)
			
			# Tower metal shell (Square/diamond protective grid)
			var base_size = 40.0 * pulse_scale
			var tower_pts = PackedVector2Array([
				t_pos + Vector2(-base_size, -base_size).rotated(shield_angle * 0.25),
				t_pos + Vector2(base_size, -base_size).rotated(shield_angle * 0.25),
				t_pos + Vector2(base_size, base_size).rotated(shield_angle * 0.25),
				t_pos + Vector2(-base_size, base_size).rotated(shield_angle * 0.25)
			])
			world_node.draw_colored_polygon(tower_pts, Color(0.06, 0.08, 0.12, 0.95))
			world_node.draw_polyline(tower_pts, t_color * Color(1, 1, 1, 0.6), 3.0)
			
			# Inner tech core rings
			world_node.draw_arc(t_pos, 28.0, 0.0, TAU, 24, t_color * Color(1, 1, 1, 0.35), 1.5)
			
			# Rotating core shield rings
			world_node.draw_arc(t_pos, 35.0, shield_angle, shield_angle + PI * 0.5, 16, t_color, 2.5)
			world_node.draw_arc(t_pos, 35.0, shield_angle + PI, shield_angle + PI * 1.5, 16, t_color, 2.5)
			
			# Core glowing orb
			world_node.draw_circle(t_pos, 18.0 * pulse_scale, t_color)
			world_node.draw_circle(t_pos, 8.0 * pulse_scale, Color.WHITE)

	# 8. Draw Minions (Cybernetic march drones)
	var minions_list = _get_safe_array(game_state, "minions")
	for m in minions_list:
		if not (m is Dictionary): continue
		var m_id = _get_safe_string(m, "id", "")
		var m_pos = smooth_positions.get(m_id)
		if m_pos == null:
			m_pos = _get_safe_vector2(m, "pos")
			
		if m_pos.distance_to(cam_pos) > 800.0:
			continue
			
		var phase = float(m_id.hash() % 100) * 0.1
		var minion_scale = 1.0 + 0.08 * sin(time_ms * 0.008 + phase)
		var rad = 18.0 * minion_scale
		
		# Mini shadow
		world_node.draw_circle(m_pos + Vector2(0, 4), rad * 0.9, Color(0, 0, 0, 0.22))
		
		# Body styling with pulsing tech core
		var m_team = _get_safe_string(m, "team", "blue")
		var m_color = Color(0.4, 0.6, 1.0) if m_team == "blue" else Color(1.0, 0.5, 0.5)
		
		# Draw minion as a triangular cyber fighter drone pointing in its target direction
		var target_vel = Vector2(_get_safe_float(m, "target_x", 0.0) - m_pos.x, _get_safe_float(m, "target_y", 0.0) - m_pos.y).normalized()
		if target_vel == Vector2.ZERO:
			target_vel = Vector2.RIGHT
			
		var m_angle = target_vel.angle()
		var m_pts = PackedVector2Array([
			m_pos + target_vel * (rad + 3.0),
			m_pos + target_vel.rotated(2.3) * rad,
			m_pos + target_vel.rotated(-2.3) * rad
		])
		world_node.draw_circle(m_pos, rad + 4.0, m_color * Color(1, 1, 1, 0.15))
		world_node.draw_colored_polygon(m_pts, Color(0.06, 0.08, 0.12, 0.95))
		world_node.draw_polyline(m_pts, m_color, 2.5)
		
		# Inner core
		world_node.draw_circle(m_pos - target_vel * 3.0, 3.5 * minion_scale, m_color * Color(1, 1, 1, 0.4))
		world_node.draw_circle(m_pos - target_vel * 3.0, 1.5 * minion_scale, Color.WHITE)
		
		# HP bar
		_draw_entity_health_bar(world_node, m_pos + Vector2(0, -25), _get_safe_float(m, "hp", 0.0), _get_safe_float(m, "max_hp", 1.0), 30, 4)

	# 9. Draw Players (Futuristic heroes with outline glows & active elemental statuses)
	var players_list = _get_safe_array(game_state, "players")
	for p in players_list:
		if not (p is Dictionary): continue
		var p_id = _get_safe_string(p, "id", "")
		if p_id == "": continue
		
		var p_pos = smooth_positions.get(p_id)
		if p_pos == null:
			p_pos = _get_safe_vector2(p, "pos")
			
		if _get_safe_bool(p, "dead", false):
			if p_id == client_id:
				world_node.draw_string(system_font, p_pos, "☠️ RESPAWNING...", HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color.RED)
			continue
			
		var p_team = _get_safe_string(p, "team", "blue")
		var p_color = Color(0.3, 0.5, 1.0) if p_team == "blue" else Color(1.0, 0.3, 0.3)
		var accent_color = Color.WHITE
		if p_id == client_id:
			accent_color = Color(1.0, 0.9, 0.3)
		
		# Stealth Grass Check
		var is_stealthy = false
		for b in grass_bushes:
			if p_pos.distance_to(b.pos) < b.radius:
				is_stealthy = true
				break
				
		var p_alpha = 1.0
		if is_stealthy:
			if p_team != my_team:
				var am_i_near_bush = false
				if my_player_data is Dictionary:
					var my_curr_pos = _get_safe_vector2(my_player_data, "pos")
					for b in grass_bushes:
						if my_curr_pos.distance_to(b.pos) < b.radius and p_pos.distance_to(b.pos) < b.radius:
							am_i_near_bush = true
							break
				if not am_i_near_bush:
					continue
			p_alpha = 0.4
			
		var col = Color(p_color.r, p_color.g, p_color.b, p_alpha)
		var acc = Color(accent_color.r, accent_color.g, accent_color.b, p_alpha)
		
		# Breathing size oscillation
		var breath = 1.0 + 0.05 * sin(time_ms * 0.005 + float(p_id.hash() % 100)*0.1)
		var base_r = 22.0 * breath
		
		# Soft drop shadow
		world_node.draw_circle(p_pos + Vector2(0, 6), base_r * 0.9, Color(0, 0, 0, p_alpha * 0.28))
		
		# Team glowing aura ring
		world_node.draw_circle(p_pos, base_r + 5.0, col * Color(1, 1, 1, 0.15))
		
		# Outer chrome perimeter ring
		world_node.draw_circle(p_pos, base_r + 3.0, acc)
		
		# Cybernetic armor core
		world_node.draw_circle(p_pos, base_r, Color(0.08, 0.1, 0.13, p_alpha))
		
		# Draw styling according to Hero class
		var hero_class_str = _get_safe_string(p, "hero", "ranger")
		if hero_class_str == "knight":
			# Knight: heavy gold trim
			world_node.draw_circle(p_pos, base_r - 2.0, Color(0.8, 0.6, 0.1, p_alpha))
			world_node.draw_circle(p_pos, base_r - 5.0, col)
		elif hero_class_str == "mage":
			# Mage: glowing energy core with violet orbit
			world_node.draw_circle(p_pos, base_r - 4.0, col)
			var magic_a = time_ms * 0.004
			var glyph_pos = p_pos + Vector2(cos(magic_a), sin(magic_a)) * (base_r - 6.0)
			world_node.draw_circle(glyph_pos, 3.0, Color(0.7, 0.3, 1.0, p_alpha))
		else:
			# Ranger: standard core
			world_node.draw_circle(p_pos, base_r - 4.0, col)
		
		# Energy center
		world_node.draw_circle(p_pos, 8.0, Color.WHITE * Color(1, 1, 1, p_alpha * 0.9))
		
		# Aim pointer nose (Beaming pointer direction)
		var angle = _get_safe_float(p, "angle", 0.0)
		var f_dir = Vector2(cos(angle), sin(angle))
		world_node.draw_line(p_pos, p_pos + f_dir * (base_r + 11.0), acc, 4.0)
		world_node.draw_line(p_pos, p_pos + f_dir * (base_r + 11.0), col, 2.0)
		world_node.draw_circle(p_pos + f_dir * (base_r + 9.0), 3.5, Color.WHITE)
		
		# --- ELEMENTAL TIMERS OVERLAYS ---
		var fire_t = _get_safe_float(p, "fire_timer", 0.0)
		var ice_t = _get_safe_float(p, "ice_timer", 0.0)
		var poison_t = _get_safe_float(p, "poison_timer", 0.0)
		
		if fire_t > 0.0:
			var fire_r = base_r + 10.0 + 4.0 * sin(time_ms * 0.015)
			world_node.draw_arc(p_pos, fire_r, 0.0, TAU, 24, Color(1.0, 0.4, 0.0, p_alpha * 0.25), 2.0)
			var spark_a = time_ms * 0.012
			world_node.draw_circle(p_pos + Vector2(cos(spark_a), sin(spark_a)) * fire_r, 4.0, Color(1.0, 0.65, 0.2, p_alpha))
			
		if ice_t > 0.0:
			var ice_r = base_r + 8.0
			world_node.draw_arc(p_pos, ice_r, 0.0, TAU, 24, Color(0.3, 0.75, 1.0, p_alpha * 0.3), 3.0)
			for i in range(3):
				var a_offset = time_ms * 0.002 + i * (TAU / 3.0)
				world_node.draw_rect(Rect2(p_pos.x + cos(a_offset)*ice_r - 2, p_pos.y + sin(a_offset)*ice_r - 2, 4, 4), Color(0.8, 0.95, 1.0, p_alpha))
				
		if poison_t > 0.0:
			var poison_r = base_r + 9.0
			world_node.draw_arc(p_pos, poison_r, 0.0, TAU, 24, Color(0.65, 0.1, 0.8, p_alpha * 0.25), 1.5)
			for i in range(4):
				var a_offset = -time_ms * 0.003 + i * (TAU / 4.0)
				var bubble_r = 2.0 + sin(time_ms * 0.01 + i)
				world_node.draw_circle(p_pos + Vector2(cos(a_offset), sin(a_offset)) * (poison_r + 2.0), bubble_r, Color(0.8, 0.2, 1.0, p_alpha))
		
		# Name plate and Level badge
		var p_name = _get_safe_string(p, "name", "Archer")
		if _get_safe_bool(p, "is_bot", false):
			p_name = "🤖 " + p_name
			
		var hero_cls = _get_safe_string(p, "hero", "ranger")
		var hero_emoji = "🏹"
		if hero_cls == "knight":
			hero_emoji = "🛡️"
		elif hero_cls == "mage":
			hero_emoji = "🔥"
			
		var badge_str = "Lvl " + str(_get_safe_int(p, "level", 1)) + " " + hero_emoji + " " + p_name
		world_node.draw_string(system_font, p_pos + Vector2(-60, -42), badge_str, HORIZONTAL_ALIGNMENT_CENTER, 120, 12, acc)
		
		# Health Bar
		_draw_entity_health_bar(world_node, p_pos + Vector2(0, -32), _get_safe_float(p, "hp", 0.0), _get_safe_float(p, "max_hp", 1.0), 45, 5, p_alpha)

	# 10. Draw Hit Sparks particles
	for s in hit_sparks:
		world_node.draw_circle(s.pos, s.size, s.color)

	# 11. Draw Floating Damage/XP Texts
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
			var t = clamp(18.0 * delta, 0.0, 1.0)
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, t)
			
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
			var t = clamp(18.0 * delta, 0.0, 1.0)
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, t)
			
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
			var t = clamp(26.0 * delta, 0.0, 1.0)
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, t)

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
			var t = clamp(12.0 * delta, 0.0, 1.0)
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, t)
			
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
