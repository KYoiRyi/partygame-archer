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
var portals: Array = []
var heal_zones: Array = []
var trap_zones: Array = []
var my_player_data = null

# --- Visual Effects & Juice ---
var screen_shake: float = 0.0
var damage_texts: Array = []
var hit_sparks: Array = []
var grass_bushes: Array = []

# --- Input & Movement ---
var last_move_dir: Vector2 = Vector2.ZERO
var last_angle: float = 0.0
var last_move_send_time: int = 0
var current_input_dir: Vector2 = Vector2.ZERO
var current_input_angle: float = 0.0
var is_chatting: bool = false
var mouse_aim_active: bool = false

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
var proj_trails: Dictionary = {}
var status_label: Label = null
var client_dash_cooldown: float = 0.0
var last_touch_time: int = 0

func _ready():
	system_font = ThemeDB.fallback_font
	
	# Show ServerInput on non-web platforms (like APK/Desktop) so users can edit the server URL,
	# but hide it on Web since it resolves automatically.
	if OS.has_feature("web"):
		$UI/Lobby/Panel/VBox/ServerInput.visible = false
	else:
		$UI/Lobby/Panel/VBox/ServerInput.visible = true
		$UI/Lobby/Panel/VBox/ServerInput.text = ""
		$UI/Lobby/Panel/VBox/ServerInput.placeholder_text = "wss://prts.kyoiryi.top/archer/ws (Default)"
		
	# Programmatic Status Label for Connection Status & Warnings
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3)) # light red
	status_label.add_theme_font_size_override("font_size", 13)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	$UI/Lobby/Panel/VBox.add_child(status_label)
	
	# Dynamic OptionButton for Hero Selection
	hero_select_btn = OptionButton.new()
	hero_select_btn.add_item("🏹 Ranger (Multi Shot Lvl 1, Speed 300)", 0)
	hero_select_btn.add_item("🛡️ Knight (HP Boost Lvl 1, HP 150)", 1)
	hero_select_btn.add_item("🔥 Mage (Fire Arrow Lvl 1, Speed 260)", 2)
	hero_select_btn.add_item("🗡️ Assassin (Poison Arrow, Speed 330)", 3)
	hero_select_btn.add_item("👁️ Sniper (Piercing, Damage Boost, Slow Atk)", 4)
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
	for i in range(40):
		grass_bushes.append({
			"pos": Vector2(randf_range(100, 2900), randf_range(100, 1100)),
			"radius": randf_range(70, 110)
		})
		
	# Dash Button for Mobile & UI
	var dash_btn = Button.new()
	dash_btn.name = "DashButton"
	dash_btn.text = "⚡ DASH"
	dash_btn.add_theme_font_size_override("font_size", 22)
	dash_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	dash_btn.offset_left = -260
	dash_btn.offset_top = -200
	dash_btn.offset_right = -120
	dash_btn.offset_bottom = -120
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.5, 1.0, 0.5)
	sb.corner_radius_top_left = 40
	sb.corner_radius_top_right = 40
	sb.corner_radius_bottom_left = 40
	sb.corner_radius_bottom_right = 40
	dash_btn.add_theme_stylebox_override("normal", sb)
	dash_btn.pressed.connect(_on_dash_pressed)
	$UI/HUD.add_child(dash_btn)
	
	# Initial window setup
	get_viewport().files_dropped.connect(func(files): pass)
	
	# Add Glow Effects for Ion visuals (Optimized for Mobile/APK)
	var env = Environment.new()
	env.background_mode = Environment.BG_CANVAS
	if OS.has_feature("mobile") or OS.has_feature("web"):
		env.glow_enabled = false
	else:
		env.glow_enabled = true
		env.glow_intensity = 0.6
		env.glow_strength = 0.8
		env.set("glow_levels/1", 0.0)
		env.set("glow_levels/2", 0.0)
		env.set("glow_levels/3", 1.0)
		env.set("glow_levels/4", 0.0)
		env.set("glow_levels/5", 0.0)
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
		env.glow_hdr_threshold = 0.8
	var we = WorldEnvironment.new()
	we.environment = env
	add_child(we)
	
	# Force 60 FPS to fix stuttering
	Engine.max_fps = 60

func _on_dash_pressed():
	if client_dash_cooldown <= 0 and is_connected and (my_player_data is Dictionary) and not _get_safe_bool(my_player_data, "dead", false):
		client_dash_cooldown = 2.0
		socket.send_text(JSON.stringify({"type": "dash"}))

func _input(event: InputEvent):
	if not is_connected or not (my_player_data is Dictionary) or _get_safe_bool(my_player_data, "dead", false):
		# Cleanup if we disconnected or died
		if joystick_active or aim_active or mouse_aim_active:
			joystick_active = false
			joystick_touch_index = -1
			aim_active = false
			aim_touch_index = -1
			mouse_aim_active = false
			if joystick_draw_node:
				joystick_draw_node.queue_redraw()
		return
		
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		last_touch_time = Time.get_ticks_msec()
		
	if event is InputEventMouseButton:
		if $UI/SkillPanel.visible:
			return # Don't aim while picking skills
		if Time.get_ticks_msec() - last_touch_time < 100:
			return # Ignore emulated mouse click from touch
		if event.button_index == MOUSE_BUTTON_LEFT and not is_chatting:
			if event.pressed:
				mouse_aim_active = true
				if joystick_draw_node: joystick_draw_node.queue_redraw()
			else:
				if mouse_aim_active:
					var mouse_pos = get_global_mouse_position()
					if my_player_data is Dictionary:
						var p_pos = _get_safe_vector2(my_player_data, "pos")
						var aim_angle = (mouse_pos - p_pos).angle()
						_trigger_aim_shoot(aim_angle)
					mouse_aim_active = false
					if joystick_draw_node: joystick_draw_node.queue_redraw()
	elif event is InputEventMouseMotion:
		if Time.get_ticks_msec() - last_touch_time < 100:
			return # Ignore emulated mouse motion from touch
		if mouse_aim_active:
			if joystick_draw_node: joystick_draw_node.queue_redraw()

	if event is InputEventScreenTouch:
		if event.pressed:
			if $UI/SkillPanel.visible:
				return # Don't move or aim while picking skills
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
				var dash_btn = $UI/HUD.get_node_or_null("DashButton")
				if dash_btn and dash_btn.get_global_rect().has_point(event.position):
					_on_dash_pressed()
					return # Prevent aim logic when dashing
					
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
				current_input_dir = Vector2.ZERO
				if joystick_draw_node:
					joystick_draw_node.queue_redraw()
			elif event.index == aim_touch_index:
				var drag_offset = aim_pos - aim_center
				if drag_offset.length() < 18.0:
					_trigger_quick_tap_shoot()
				else:
					_trigger_aim_shoot(drag_offset.angle())
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
				current_input_dir = move_dir
				current_input_angle = angle
			else:
				current_input_dir = Vector2.ZERO
				
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
		
		# Target reticle
		joystick_draw_node.draw_circle(aim_pos, 28.0, Color(1.0, 0.3, 0.3, 0.25))
		joystick_draw_node.draw_circle(aim_pos, 24.0, Color(1.0, 0.3, 0.3, 0.75))
		joystick_draw_node.draw_arc(aim_pos, 24.0, 0.0, TAU, 24, Color.WHITE, 2.0)
		
		# Draw aiming line in game world overlay if player data exists
		if my_player_data is Dictionary:
			var p_pos = _get_safe_vector2(my_player_data, "pos")
			var angle = (aim_pos - aim_center).angle()
			var line_end = p_pos + Vector2(cos(angle), sin(angle)) * 400.0
			joystick_draw_node.draw_line(p_pos, line_end, Color(1.0, 0.3, 0.3, 0.4), 2.0)
			
	if mouse_aim_active and not aim_active and my_player_data is Dictionary:
		var p_pos = _get_safe_vector2(my_player_data, "pos")
		var mouse_pos = get_global_mouse_position()
		var angle = (mouse_pos - p_pos).angle()
		var line_end = p_pos + Vector2(cos(angle), sin(angle)) * 400.0
		joystick_draw_node.draw_line(p_pos, line_end, Color(1.0, 0.3, 0.3, 0.4), 2.0)

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
		# Fallback for local editor / APK development
		var server_input_text = $UI/Lobby/Panel/VBox/ServerInput.text.strip_edges()
		if server_input_text != "":
			var final_url = server_input_text
			if not (final_url.begins_with("ws://") or final_url.begins_with("wss://")):
				final_url = "ws://" + final_url
			
			# If the input doesn't end with "/ws" (case insensitive), append it
			var url_lower = final_url.to_lower()
			if not url_lower.ends_with("/ws"):
				if url_lower.ends_with("/"):
					final_url = final_url + "ws"
				else:
					final_url = final_url + "/ws"
			server_url = final_url
		else:
			server_url = "wss://prts.kyoiryi.top/archer/ws"
		
	# Append query param for nickname and hero class selection
	var selected_hero_idx = hero_select_btn.selected
	var ws_url = server_url + "?name=" + nickname.uri_encode() + "&hero=" + str(selected_hero_idx)
	
	add_chat_message("System", "Connecting to " + ws_url + "...")
	if status_label:
		status_label.text = "Connecting to " + ws_url + "..."
		status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8)) # grey
	
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
			if status_label:
				status_label.text = ""
		
		# Read server packets
		while socket.get_available_packet_count() > 0:
			var packet = socket.get_packet()
			var data_str = packet.get_string_from_utf8()
			
			# Server may batch packets separated by newlines
			var packets = data_str.split("\n")
			for p_str in packets:
				if p_str.strip_edges() == "":
					continue
				
				var parsed_data = JSON.parse_string(p_str)
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
			if status_label:
				status_label.text = "Connection failed!\nEnsure local server is running.\nIf using PC, try entering its IP (e.g. 192.168.x.x:8090)\ninstead of localhost."
				status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3)) # light red
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
			if status_label:
				status_label.text = "Connection timed out.\nEnsure address is reachable & server is listening."
				status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3)) # light red
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
		_send_movement_if_changed()
		
	# 4. Handle Chat Open key (Enter)
	if Input.is_key_pressed(KEY_ENTER) or Input.is_physical_key_pressed(KEY_ENTER):
		if not is_chatting:
			$UI/HUD/ChatBox/ChatInput.grab_focus()
			is_chatting = true
			
	# Process Cooldowns
	if client_dash_cooldown > 0:
		client_dash_cooldown -= delta
		var db = $UI/HUD.get_node_or_null("DashButton")
		if db:
			db.text = "⚡ " + str(snapped(client_dash_cooldown, 0.1)) + "s"
			db.disabled = true
	else:
		var db = $UI/HUD.get_node_or_null("DashButton")
		if db:
			db.text = "⚡ DASH"
			db.disabled = false
			
	if client_shoot_cooldown > 0:
		client_shoot_cooldown -= delta
			
	if not is_chatting and (Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_SHIFT)):
		_on_dash_pressed()
			
	# 5. Process Visual FX (texts, particles)
	_update_visual_effects(delta)
	
	# Redraw the world
	$World.queue_redraw()

func _process_movement_input(delta):
	if joystick_active:
		# Touch joystick takes absolute priority, ignore keyboard inputs
		return
		
	var move_dir = Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): move_dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): move_dir.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): move_dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): move_dir.x += 1
	
	move_dir = move_dir.normalized()
	
	current_input_dir = move_dir
	if move_dir != Vector2.ZERO:
		current_input_angle = move_dir.angle()

func _send_movement_if_changed():
	# Only send network updates if movement vector or direction angle changes significantly or if time passed
	var dir_changed_significantly = last_move_dir.distance_squared_to(current_input_dir) > 0.01
	var angle_changed_significantly = current_input_dir != Vector2.ZERO and abs(current_input_angle - last_angle) > 0.05
	
	if dir_changed_significantly or angle_changed_significantly or (current_input_dir == Vector2.ZERO and last_move_dir != Vector2.ZERO):
		var now = Time.get_ticks_msec()
		if now - last_move_send_time > 16 or current_input_dir == Vector2.ZERO: # 60hz limit, except when stopping
			last_move_send_time = now
			last_move_dir = current_input_dir
			last_angle = current_input_angle
			
			var msg = {
				"type": "move",
				"is_moving": current_input_dir != Vector2.ZERO,
				"x": current_input_dir.x,
				"y": current_input_dir.y,
				"angle": current_input_angle
			}
			socket.send_text(JSON.stringify(msg))

func _trigger_aim_shoot(angle: float):
	if client_shoot_cooldown <= 0:
		var msg = {
			"type": "shoot",
			"angle": angle
		}
		socket.send_text(JSON.stringify(msg))
		_apply_shoot_cooldown()

func _apply_shoot_cooldown():
	var base_cd = 0.25
	var hero = _get_safe_string(my_player_data, "hero", "ranger")
	if hero == "knight":
		base_cd = 0.40
	elif hero == "mage":
		base_cd = 0.35
	elif hero == "assassin":
		base_cd = 0.20
	elif hero == "sniper":
		base_cd = 0.60
	
	var atk_speed_lvl = 0
	if my_player_data is Dictionary:
		var skills = my_player_data.get("skills", {})
		if skills is Dictionary:
			atk_speed_lvl = skills.get("atk_speed", 0)
	
	client_shoot_cooldown = base_cd * pow(0.85, atk_speed_lvl) - 0.02

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
			_apply_shoot_cooldown()

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
			portals = _get_safe_array(data, "portals")
			heal_zones = _get_safe_array(data, "heal_zones")
			trap_zones = _get_safe_array(data, "trap_zones")
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
			
		"effect":
			var eff_type = _get_safe_string(data, "effect_type", "")
			if eff_type == "bomb":
				var e_pos = Vector2(_get_safe_float(data, "effect_x", 0.0), _get_safe_float(data, "effect_y", 0.0))
				screen_shake = 20.0
				if hit_sparks.size() < 120:
					for i in range(30):
						var speed = randf_range(150, 450)
						var angle = randf_range(0, TAU)
						hit_sparks.append({
							"pos": e_pos,
							"vel": Vector2(cos(angle), sin(angle)) * speed,
							"color": Color(1.0, randf_range(0.3, 0.7), 0.1),
							"life": randf_range(0.3, 0.8),
							"size": randf_range(4.0, 10.0)
						})
			elif eff_type == "teleport":
				var e_pos = Vector2(_get_safe_float(data, "effect_x", 0.0), _get_safe_float(data, "effect_y", 0.0))
				if hit_sparks.size() < 120:
					for i in range(15):
						var speed = randf_range(50, 150)
						var angle = randf_range(0, TAU)
						hit_sparks.append({
							"pos": e_pos,
							"vel": Vector2(cos(angle), sin(angle)) * speed,
							"color": Color(0.6, 0.2, 1.0),
							"life": randf_range(0.2, 0.6),
							"size": randf_range(3.0, 7.0)
						})
			
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
				
				# Spawn Damage Floating Text (Capped to prevent text clutter and performance drops)
				if damage_texts.size() < 25:
					damage_texts.append({
						"pos": e_pos + Vector2(randf_range(-15, 15), -20),
						"text": str(int(diff)),
						"color": Color(1.0, 0.3, 0.3) if _get_safe_string(e, "team", "") != my_team else Color(1.0, 0.9, 0.2),
						"life": 0.8
					})
				
				# Hit Sparks (Capped to avoid WebGL / Mobile drawing lag)
				if hit_sparks.size() < 40:
					for i in range(2):
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
	
	var list_container = $UI/HUD/Scoreboard/List
	var existing_children = list_container.get_children()
	var existing_count = existing_children.size()
	
	# Draw top 6 (Reuse existing label nodes to avoid GC spikes)
	var count = 0
	for p in list:
		if not (p is Dictionary):
			continue
		if count >= 6: break
		
		var p_name = _get_safe_string(p, "name", "Archer")
		var p_id = _get_safe_string(p, "id", "")
		var p_score = _get_safe_int(p, "score", 0)
		var p_level = _get_safe_int(p, "level", 1)
		var text_val = p_name + ": " + str(p_score) + " (Lvl " + str(p_level) + ")"
		
		var l: Label
		if count < existing_count:
			l = existing_children[count]
			l.visible = true
		else:
			l = Label.new()
			list_container.add_child(l)
			
		l.text = text_val
		if p_id == client_id:
			l.add_theme_color_override("font_color", Color(0.4, 0.6, 1.0))
		else:
			l.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		count += 1
		
	# Hide any extra labels that are no longer needed
	for i in range(count, existing_count):
		existing_children[i].visible = false

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
	
	# 2. Draw Background Grid (Optimized grid_size = 200 to cut draw calls in half)
	var grid_size = 200
	var start_x = int(max(0, floor(view_min.x / grid_size) * grid_size))
	var end_x = int(min(3000, ceil(view_max.x / grid_size) * grid_size))
	var start_y = int(max(0, floor(view_min.y / grid_size) * grid_size))
	var end_y = int(min(1200, ceil(view_max.y / grid_size) * grid_size))
	
	for x in range(start_x, end_x + 1, grid_size):
		world_node.draw_line(Vector2(x, max(0, view_min.y)), Vector2(x, min(1200, view_max.y)), grid_color, 1.0)
	for y in range(start_y, end_y + 1, grid_size):
		world_node.draw_line(Vector2(max(0, view_min.x), y), Vector2(min(3000, view_max.x), y), grid_color, 1.0)
		
	# Tech dots at grid intersections (Dramatically reduced iterations with larger grid layout)
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
		# Floating internal energy particles (Reduced count)
		for i in range(2):
			var angle_offset = time_ms * 0.0008 + i * (PI)
			var offset_r = (b.radius * 0.5) + 5.0 * sin(time_ms * 0.002 + i)
			var part_pos = b.pos + Vector2(cos(angle_offset), sin(angle_offset)) * offset_r
			world_node.draw_circle(part_pos, 2.5, Color(0.4, 1.0, 0.6, 0.6))

	# 4. Draw Obstacle Walls (Hazard cybernetic core walls - Optimized to draw simple crossing lines instead of loops)
	for w in walls:
		if w.x + w.w < view_min.x or w.x > view_max.x or w.y + w.h < view_min.y or w.y > view_max.y:
			continue
		var r = Rect2(w.x, w.y, w.w, w.h)
		# Charcoal core
		world_node.draw_rect(r, Color(0.06, 0.08, 0.12, 0.85), true)
		# Simple crossing cyber lines instead of 10+ separate loops
		var stripe_color = Color(0.15, 0.28, 0.42, 0.6)
		world_node.draw_line(Vector2(w.x, w.y), Vector2(w.x + w.w, w.y + w.h), stripe_color, 3.0)
		world_node.draw_line(Vector2(w.x + w.w, w.y), Vector2(w.x, w.y + w.h), stripe_color, 3.0)
		# Glowing cyan neon border
		world_node.draw_rect(r, Color(0.15, 0.7, 1.0, 0.22), false, 5.0)
		world_node.draw_rect(r, Color(0.2, 0.8, 1.0, 0.85), false, 2.0)

	# 4.1 Draw New Map Zones (Portals, HealZones, TrapZones)
	for hz in heal_zones:
		var pos = _get_safe_vector2(hz, "pos")
		var radius = _get_safe_float(hz, "radius", 100.0)
		if pos.distance_to(cam_pos) > radius + 800.0: continue
		world_node.draw_circle(pos, radius, Color(0.1, 0.8, 0.3, 0.1 + 0.05 * sin(time_ms*0.002)))
		world_node.draw_arc(pos, radius, 0.0, TAU, 32, Color(0.3, 1.0, 0.5, 0.5), 3.0)
		world_node.draw_string(system_font, pos + Vector2(-35, 0), "+ HEAL ZONE", HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color(0.4, 1.0, 0.6))
		for i in range(3):
			var r_offset = fmod(time_ms*0.05 + i*40.0, radius)
			world_node.draw_arc(pos, r_offset, 0.0, TAU, 24, Color(0.2, 1.0, 0.4, 0.3 * (1.0 - r_offset/radius)), 1.5)

	for tz in trap_zones:
		var pos = _get_safe_vector2(tz, "pos")
		var radius = _get_safe_float(tz, "radius", 100.0)
		if pos.distance_to(cam_pos) > radius + 800.0: continue
		world_node.draw_circle(pos, radius, Color(0.9, 0.2, 0.0, 0.2 + 0.1 * sin(time_ms*0.005)))
		world_node.draw_arc(pos, radius, 0.0, TAU, 32, Color(1.0, 0.3, 0.1, 0.6), 3.0)
		world_node.draw_string(system_font, pos + Vector2(-35, 0), "LAVA TRAP", HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color(1.0, 0.4, 0.2))
		for i in range(5):
			var bubble_a = time_ms*0.001 + i
			var bubble_r = fmod(time_ms*0.04 + i*20.0, radius)
			world_node.draw_circle(pos + Vector2(cos(bubble_a), sin(bubble_a)) * bubble_r, 4.0, Color(1.0, 0.5, 0.1, 0.8))

	for pt in portals:
		var pos = _get_safe_vector2(pt, "pos")
		var radius = _get_safe_float(pt, "radius", 45.0)
		if pos.distance_to(cam_pos) > radius + 800.0: continue
		var p_a = time_ms * 0.003
		world_node.draw_circle(pos, radius, Color(0.5, 0.1, 0.9, 0.2))
		world_node.draw_arc(pos, radius, p_a, p_a + TAU, 24, Color(0.8, 0.3, 1.0, 0.7), 4.0)
		world_node.draw_arc(pos, radius - 8.0, -p_a, -p_a + TAU, 16, Color(0.6, 0.1, 1.0, 0.5), 2.0)
		world_node.draw_circle(pos, radius*0.4, Color(0.4, 0.0, 0.8, 0.6))
		world_node.draw_string(system_font, pos + Vector2(-30, 4), "PORTAL", HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color(0.9, 0.6, 1.0))
	# 4.2 Draw Crates
	var crates_list = _get_safe_array(game_state, "crates")
	for c in crates_list:
		if not (c is Dictionary): continue
		var c_pos = _get_safe_vector2(c, "pos")
		var c_rad = _get_safe_float(c, "radius", 40.0)
		if c_pos.distance_to(cam_pos) > c_rad + 800.0: continue
		
		# TODO: Replace with Sprite / Texture later!
		# For now, draw a wooden box
		var crate_rect = Rect2(c_pos.x - c_rad, c_pos.y - c_rad, c_rad*2, c_rad*2)
		world_node.draw_rect(crate_rect, Color(0.5, 0.3, 0.1), true) # Base wood color
		world_node.draw_rect(crate_rect, Color(0.3, 0.15, 0.05), false, 4.0) # Dark outline
		# Draw wooden planks cross pattern
		world_node.draw_line(Vector2(c_pos.x - c_rad, c_pos.y - c_rad), Vector2(c_pos.x + c_rad, c_pos.y + c_rad), Color(0.3, 0.15, 0.05), 3.0)
		world_node.draw_line(Vector2(c_pos.x + c_rad, c_pos.y - c_rad), Vector2(c_pos.x - c_rad, c_pos.y + c_rad), Color(0.3, 0.15, 0.05), 3.0)
		world_node.draw_circle(c_pos, 6.0, Color(0.8, 0.7, 0.2)) # lock/bolt

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
		
		var gem_type = _get_safe_string(g, "type", "xp")
		if gem_type == "hp":
			# Glowing red base shadow
			world_node.draw_circle(g_pos + Vector2(0, 8), 8.0, Color(1.0, 0.2, 0.2, 0.2))
			world_node.draw_circle(final_pos, 14.0, Color(1.0, 0.2, 0.2, 0.15)) # Neon Aura
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
		elif gem_type == "bomb":
			world_node.draw_circle(g_pos + Vector2(0, 8), 10.0, Color(0.2, 0.2, 0.2, 0.3))
			world_node.draw_circle(final_pos, 14.0, Color(1.0, 0.4, 0.1, 0.15)) # Neon Aura
			world_node.draw_circle(final_pos, 9.0, Color(0.15, 0.15, 0.15))
			world_node.draw_circle(final_pos - Vector2(3, 4), 3.0, Color(1.0, 0.4, 0.1)) # bomb spark
		elif gem_type == "mushroom":
			world_node.draw_circle(g_pos + Vector2(0, 8), 10.0, Color(0.8, 0.3, 0.8, 0.3))
			world_node.draw_circle(final_pos, 14.0, Color(0.8, 0.3, 0.8, 0.15)) # Neon Aura
			world_node.draw_circle(final_pos + Vector2(0, 3), 5.0, Color(0.9, 0.9, 0.9)) # stem
			world_node.draw_arc(final_pos, 8.0, PI, TAU, 16, Color(0.8, 0.2, 0.3), 8.0) # cap
		elif gem_type == "star":
			world_node.draw_circle(g_pos + Vector2(0, 8), 8.0, Color(1.0, 0.9, 0.2, 0.3))
			world_node.draw_circle(final_pos, 14.0, Color(1.0, 0.9, 0.2, 0.15)) # Neon Aura
			var raw_pts = [
				Vector2(0, -10), Vector2(3, -3), Vector2(10, -3), Vector2(4, 2),
				Vector2(6, 10), Vector2(0, 5), Vector2(-6, 10), Vector2(-4, 2),
				Vector2(-10, -3), Vector2(-3, -3)
			]
			var rotated_pts = PackedVector2Array()
			for pt in raw_pts:
				rotated_pts.append(final_pos + pt.rotated(angle_rot))
			world_node.draw_colored_polygon(rotated_pts, Color(1.0, 0.9, 0.2))
			world_node.draw_polyline(rotated_pts, Color(1.0, 1.0, 0.8), 1.5)
		elif gem_type == "haste":
			world_node.draw_circle(g_pos + Vector2(0, 8), 8.0, Color(0.3, 0.8, 1.0, 0.3))
			world_node.draw_circle(final_pos, 14.0, Color(0.3, 0.8, 1.0, 0.15)) # Neon Aura
			var raw_pts = [
				Vector2(2, -10), Vector2(-4, 0), Vector2(2, 0), Vector2(-2, 10),
				Vector2(6, -2), Vector2(0, -2)
			]
			var rotated_pts = PackedVector2Array()
			for pt in raw_pts:
				rotated_pts.append(final_pos + pt.rotated(angle_rot))
			world_node.draw_colored_polygon(rotated_pts, Color(0.2, 0.7, 1.0))
		else:
			# Glowing green base shadow
			world_node.draw_circle(g_pos + Vector2(0, 8), 7.0, Color(0.2, 0.9, 0.4, 0.2))
			world_node.draw_circle(final_pos, 15.0, Color(0.2, 0.9, 0.4, 0.15)) # Neon Aura
			# XP: spinning diamond
			var raw_pts = [
				Vector2(0, -10),
				Vector2(7, 0),
				Vector2(0, 10),
				Vector2(-7, 0)
			]
			var rotated_pts = PackedVector2Array()
			for pt in raw_pts:
				rotated_pts.append(final_pos + pt.rotated(angle_rot))
			world_node.draw_colored_polygon(rotated_pts, Color(0.2, 0.85, 0.4))
			world_node.draw_polyline(rotated_pts, Color(0.6, 1.0, 0.7), 1.5)

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
		
		# --- ANIMATED ION TRAIL ---
		var trail_pts = proj_trails.get(proj_id, [p_pos])
		if trail_pts.size() > 1:
			var pts_array = PackedVector2Array(trail_pts)
			
		# Glow layers for plasma trail (toned down to reduce visual clutter)
			world_node.draw_polyline(pts_array, Color(arrow_color.r, arrow_color.g, arrow_color.b, 0.3), 4.0)
			world_node.draw_polyline(pts_array, Color(1.0, 1.0, 1.0, 0.8), 1.5)
			
		# --- PROJECTILE HEAD ANIMATION ---
		var head_angle = vel.angle()
		var phase = time_ms * 0.015
		
		if is_ice:
			# Shard shape for ice (Spinning diamond)
			var ice_pts = PackedVector2Array()
			for i in range(4):
				var a = head_angle + i * PI / 2.0 + phase * 0.5
				var r = 16.0 if i % 2 == 0 else 6.0
				ice_pts.append(p_pos + Vector2(cos(a), sin(a)) * r)
			world_node.draw_colored_polygon(ice_pts, Color(0.2, 0.9, 1.0, 0.9))
			world_node.draw_polyline(ice_pts, Color.WHITE, 1.5)
		elif is_fire:
			# Fireball (Pulsating fiery star)
			var fire_pts = PackedVector2Array()
			for i in range(5):
				var a1 = head_angle + i * TAU / 5.0 - phase
				var a2 = head_angle + (i + 0.5) * TAU / 5.0 - phase
				var pulse = 2.0 * sin(time_ms * 0.04)
				fire_pts.append(p_pos + Vector2(cos(a1), sin(a1)) * (14.0 + pulse))
				fire_pts.append(p_pos + Vector2(cos(a2), sin(a2)) * 6.0)
			world_node.draw_colored_polygon(fire_pts, Color(1.0, 0.35, 0.0, 0.95))
			world_node.draw_polyline(fire_pts, Color(1.0, 0.9, 0.3), 1.5)
			world_node.draw_circle(p_pos, 4.0, Color.WHITE)
		elif is_poison:
			# Acid bubble (Wobbly toxic blob)
			var blob_r = 10.0 + 2.0 * sin(phase * 1.5)
			world_node.draw_circle(p_pos, blob_r, Color(0.7, 0.1, 0.9, 0.8))
			world_node.draw_circle(p_pos + Vector2(-3, -3).rotated(phase), blob_r * 0.4, Color(0.9, 0.5, 1.0, 0.9))
			world_node.draw_circle(p_pos, 3.0, Color.WHITE)
		else:
			# Standard Energetic Ion Core Head (Arrow shape with inner energy)
			var core_pts = PackedVector2Array([
				p_pos + vel * 12.0,
				p_pos - vel.rotated(0.5) * 10.0,
				p_pos - vel * 6.0,
				p_pos - vel.rotated(-0.5) * 10.0
			])
			world_node.draw_colored_polygon(core_pts, arrow_color)
			world_node.draw_polyline(core_pts, Color.WHITE, 1.5)
			
			# Rotating outer halo for high-tech look
			world_node.draw_arc(p_pos, 14.0, phase, phase + PI * 0.6, 12, Color(arrow_color.r, arrow_color.g, arrow_color.b, 0.6), 2.0)
			world_node.draw_arc(p_pos, 14.0, phase + PI, phase + PI * 1.6, 12, Color(arrow_color.r, arrow_color.g, arrow_color.b, 0.6), 2.0)
			world_node.draw_circle(p_pos, 3.0, Color.WHITE)



	# 9. Draw Players (Futuristic heroes with outline glows & active elemental statuses)
	var players_list = _get_safe_array(game_state, "players")
	for p in players_list:
		if not (p is Dictionary): continue
		var p_id = _get_safe_string(p, "id", "")
		if p_id == "": continue
		
		var p_pos = smooth_positions.get(p_id)
		if p_pos == null:
			p_pos = _get_safe_vector2(p, "pos")
			
		# Cull off-screen players to dramatically optimize draw calls
		if p_id != client_id and p_pos.distance_to(cam_pos) > 850.0:
			continue
			
		if _get_safe_bool(p, "dead", false):
			if p_id == client_id:
				world_node.draw_string(system_font, p_pos, "☠️ RESPAWNING...", HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color.RED)
			continue
			
		var p_color = Color(0.3, 0.5, 1.0) if p_id == client_id else Color(1.0, 0.3, 0.3)
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
			if p_id != client_id:
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
		
		var is_giant = _get_safe_float(p, "giant_timer", 0.0) > 0.0
		var is_invincible = _get_safe_float(p, "invincible_timer", 0.0) > 0.0
		var is_haste = _get_safe_float(p, "haste_timer", 0.0) > 0.0
		
		if is_giant:
			base_r *= 1.8
		
		if is_haste:
			world_node.draw_circle(p_pos, base_r + 12.0, Color(1.0, 0.9, 0.2, 0.3 + 0.2 * sin(time_ms * 0.03)))
			
		if is_invincible:
			var inv_col = Color.from_hsv(fmod(time_ms * 0.002, 1.0), 0.8, 1.0, p_alpha)
			col = inv_col
			acc = inv_col
		
		# Soft drop shadow
		world_node.draw_circle(p_pos + Vector2(0, 8), base_r * 0.8, Color(0, 0, 0, p_alpha * 0.3))
		
		# --- GEOMETRIC AVATAR RENDERING ---
		var hero_class_str = _get_safe_string(p, "hero", "ranger")
		var aim_angle = _get_safe_float(p, "angle", 0.0)
		var f_dir = Vector2(cos(aim_angle), sin(aim_angle))
		
		# Draw styling according to Hero class
		if hero_class_str == "knight":
			# Knight: Heavy shielded hexagon
			var kn_pts = PackedVector2Array()
			for i in range(6):
				var a = aim_angle + i * TAU / 6.0
				kn_pts.append(p_pos + Vector2(cos(a), sin(a)) * base_r)
			world_node.draw_colored_polygon(kn_pts, Color(0.1, 0.15, 0.2, p_alpha))
			world_node.draw_polyline(kn_pts, col, 3.5)
			# Front shield plate
			world_node.draw_line(p_pos + f_dir * base_r, p_pos + f_dir.rotated(PI/3) * base_r, acc, 4.0)
			world_node.draw_line(p_pos + f_dir * base_r, p_pos + f_dir.rotated(-PI/3) * base_r, acc, 4.0)
			
		elif hero_class_str == "mage":
			# Mage: Floating runic circles and star
			world_node.draw_circle(p_pos, base_r - 2.0, Color(0.1, 0.1, 0.2, p_alpha))
			var magic_a = time_ms * 0.003
			world_node.draw_arc(p_pos, base_r, magic_a, magic_a + TAU, 24, col, 3.0)
			
			# Inner Star
			var star_pts = PackedVector2Array()
			for i in range(3):
				var a1 = aim_angle + magic_a + i * TAU / 3.0
				star_pts.append(p_pos + Vector2(cos(a1), sin(a1)) * (base_r - 4.0))
			world_node.draw_colored_polygon(star_pts, acc * Color(1, 1, 1, 0.3))
			world_node.draw_polyline(star_pts, acc, 2.0)
			
		else:
			# Ranger/Default: Sleek aerodynamic arrow ship
			var arr_pts = PackedVector2Array([
				p_pos + f_dir * (base_r + 6.0),
				p_pos + f_dir.rotated(2.4) * base_r,
				p_pos - f_dir * (base_r * 0.3), # indentation at back
				p_pos + f_dir.rotated(-2.4) * base_r
			])
			world_node.draw_colored_polygon(arr_pts, Color(0.08, 0.1, 0.13, p_alpha))
			world_node.draw_polyline(arr_pts, col, 3.0)
			# Thruster
			world_node.draw_circle(p_pos - f_dir * (base_r * 0.3), 5.0, Color(0.3, 0.8, 1.0, 0.8))
			
		# Energy center orb
		world_node.draw_circle(p_pos, 5.0, col)
		world_node.draw_circle(p_pos, 2.5, Color.WHITE)
		
		# Direction indicator (if not ranger, since ranger is already an arrow)
		if hero_class_str != "ranger":
			world_node.draw_line(p_pos + f_dir * (base_r * 0.5), p_pos + f_dir * (base_r + 10.0), acc, 3.0)
			world_node.draw_circle(p_pos + f_dir * (base_r + 10.0), 3.0, acc)
		
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
		# Draw Bounty Crown if applicable
		if _get_safe_bool(p, "has_crown", false):
			var crown_y = p_pos.y - base_r - 20.0
			var crown_pts = PackedVector2Array([
				Vector2(p_pos.x - 15, crown_y),
				Vector2(p_pos.x - 20, crown_y - 20),
				Vector2(p_pos.x - 8, crown_y - 10),
				Vector2(p_pos.x, crown_y - 25),
				Vector2(p_pos.x + 8, crown_y - 10),
				Vector2(p_pos.x + 20, crown_y - 20),
				Vector2(p_pos.x + 15, crown_y)
			])
			world_node.draw_colored_polygon(crown_pts, Color(1.0, 0.8, 0.1))
			world_node.draw_polyline(crown_pts, Color(1.0, 1.0, 0.5), 2.0)
			# Crown gems
			world_node.draw_circle(Vector2(p_pos.x, crown_y - 15), 3.0, Color(1.0, 0.2, 0.2))
			world_node.draw_circle(Vector2(p_pos.x - 10, crown_y - 12), 2.0, Color(0.2, 0.5, 1.0))
			world_node.draw_circle(Vector2(p_pos.x + 10, crown_y - 12), 2.0, Color(0.2, 1.0, 0.5))

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

	for t in damage_texts:
		world_node.draw_string(system_font, t.pos, t.text, HORIZONTAL_ALIGNMENT_CENTER, 80, 16, t.color)

	# 12. Draw Global Event Warning UI
	var global_event = _get_safe_string(game_state, "global_event", "")
	if global_event != "":
		# Draw a large flashing text over the screen center
		var screen_center = cam_pos
		var flash_alpha = 0.5 + 0.5 * sin(time_ms * 0.01)
		var event_color = Color(1.0, 0.2, 0.2, flash_alpha)
		if global_event == "SPEED_BOOST":
			event_color = Color(0.2, 0.8, 1.0, flash_alpha)
		
		# Darkened overlay if DARKNESS
		if global_event == "DARKNESS":
			# Draw a giant dark circle with a hole in the middle (faux lighting)
			# Since drawing a full screen overlay with a hole in Godot CanvasItem draw is tricky,
			# We will draw 4 huge rectangles around the player, or just a translucent full screen
			# Just an overlay for now to simulate darkness:
			world_node.draw_rect(Rect2(cam_pos.x - 1500, cam_pos.y - 1500, 3000, 3000), Color(0.0, 0.0, 0.0, 0.85), true)
			# Player vision circle
			world_node.draw_circle(cam_pos, 250.0, Color(1.0, 1.0, 1.0, 0.1))

		world_node.draw_string(system_font, screen_center + Vector2(-300, -200), "⚠️ GLOBAL EVENT: " + global_event, HORIZONTAL_ALIGNMENT_CENTER, 600, 32, event_color)

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
			proj_trails[id] = [server_pos]
		else:
			# Increased projectile interpolation speed to prevent hit delay
			var t = clamp(45.0 * delta, 0.0, 1.0)
			smooth_positions[id] = smooth_positions[id].lerp(server_pos, t)
			if not proj_trails.has(id):
				proj_trails[id] = []
			proj_trails[id].push_front(smooth_positions[id])
			if proj_trails[id].size() > 10:
				proj_trails[id].pop_back()

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
			proj_trails.erase(id)

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
