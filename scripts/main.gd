extends Control

signal clicked(total_count: int)

const SAVE_PATH := "user://isaac_bongo_save.cfg"
const USER_HELPER_PATH := "user://global_input_helper.exe"
const HELPER_BLOB := preload("res://scripts/global_input_helper_blob.gd")
const BASE_SIZE := Vector2i(212, 236)
const ANIM_IDLE := &"idle"
const ANIM_THUMBS_UP := &"thumbs_up"
const ANIM_DANCE := &"dance"

enum MenuId {
	DANCE = 0,
	DANCE_MUSIC = 1,
	ALWAYS_ON_TOP = 2,
	SOUND = 3,
	SCALE_75 = 4,
	SCALE_100 = 5,
	SCALE_125 = 6,
	RESET = 7,
	QUIT = 8,
}

@onready var isaac_pivot: Node2D = $IsaacPivot
@onready var isaac_sprite: Sprite2D = $IsaacPivot/IsaacSprite
@onready var dance_sprite: Sprite2D = $IsaacPivot/DanceSprite
@onready var anim_player: AnimationPlayer = $IsaacPivot/AnimationPlayer
@onready var counter_panel: PanelContainer = $BottomBar/CounterPanel
@onready var counter_label: Label = $BottomBar/CounterPanel/CounterLabel
@onready var menu_button: Button = $BottomBar/MenuButton
@onready var options_menu: PopupMenu = $OptionsMenu
@onready var like_sfx: AudioStreamPlayer = $LikeSfx
@onready var dance_music: AudioStreamPlayer = $DanceMusic

var click_count: int = 0
var _always_on_top: bool = true
var _sound_enabled: bool = false
var _dance_music_enabled: bool = true
var _is_dancing: bool = false
var _window_scale: float = 1.0
var _saved_pos: Vector2i = Vector2i.ZERO
var _has_saved_pos: bool = false

var _udp := PacketPeerUDP.new()
var _helper_pid: int = -1
var _helper_active: bool = false

var _is_dragging: bool = false
var _drag_offset: Vector2i = Vector2i.ZERO

var _save_dirty: bool = false
var _save_timer: float = 0.0
var _sfx_cooldown: float = 0.0


func _ready() -> void:
	_load_config()

	var win := get_window()
	win.transparent_bg = true
	win.transparent = true
	win.borderless = true
	win.unresizable = true
	win.always_on_top = _always_on_top
	RenderingServer.set_default_clear_color(Color(0.0, 0.0, 0.0, 0.0))

	_apply_scale(_window_scale, false)
	if _has_saved_pos:
		win.position = _saved_pos
	_clamp_window_to_screen()

	_setup_menu()
	menu_button.pressed.connect(_on_menu_button_pressed)
	options_menu.id_pressed.connect(_on_menu_id_pressed)
	anim_player.animation_finished.connect(_on_animation_finished)
	counter_panel.gui_input.connect(_on_counter_panel_gui_input)
	get_viewport().size_changed.connect(_update_layout)

	mouse_default_cursor_shape = Control.CURSOR_MOVE
	counter_panel.mouse_default_cursor_shape = Control.CURSOR_MOVE

	_update_layout()
	_update_counter_display()
	set_dancing(false)
	_start_global_input_helper()


func _update_layout() -> void:
	var vp_size := get_viewport_rect().size
	isaac_pivot.position = Vector2(vp_size.x * 0.5, vp_size.y - 42.0)


func _process(delta: float) -> void:
	if _helper_active:
		while _udp.get_available_packet_count() > 0:
			var pkt := _udp.get_packet().get_string_from_ascii()
			register_click(pkt)

	if _is_dragging:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			get_window().position = DisplayServer.mouse_get_position() - _drag_offset
		else:
			_is_dragging = false
			_save_dirty = true

	if _sfx_cooldown > 0.0:
		_sfx_cooldown -= delta

	if _save_dirty:
		_save_timer += delta
		if _save_timer >= 1.5:
			_save_config()


func _input(event: InputEvent) -> void:
	if _helper_active:
		return
	if event is InputEventKey:
		var key_ev := event as InputEventKey
		if key_ev.pressed and not key_ev.echo:
			register_click("K")
	elif event is InputEventMouseButton:
		var mb_ev := event as InputEventMouseButton
		if mb_ev.pressed:
			register_click("M")


func _gui_input(event: InputEvent) -> void:
	if _handle_pointer_event(event):
		accept_event()


func _on_counter_panel_gui_input(event: InputEvent) -> void:
	if _handle_pointer_event(event):
		counter_panel.accept_event()


func _handle_pointer_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_is_dragging = true
				_drag_offset = DisplayServer.mouse_get_position() - get_window().position
			else:
				if _is_dragging:
					_is_dragging = false
					_save_dirty = true
			return true
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_open_menu_at(DisplayServer.mouse_get_position())
			return true
	return false


func register_click(_source: String = "input") -> void:
	click_count += 1
	_update_counter_display()
	clicked.emit(click_count)

	if not _is_dancing:
		if anim_player.current_animation == ANIM_THUMBS_UP:
			var pos := anim_player.current_animation_position
			if pos >= 0.045 and pos < 0.30:
				anim_player.seek(0.045, true)
			else:
				anim_player.stop()
				anim_player.play(ANIM_THUMBS_UP)
		else:
			anim_player.stop()
			anim_player.play(ANIM_THUMBS_UP)

		if _sound_enabled and like_sfx != null and like_sfx.stream != null and _sfx_cooldown <= 0.0:
			like_sfx.pitch_scale = randf_range(0.95, 1.08)
			like_sfx.play()
			_sfx_cooldown = 0.08

	_save_dirty = true


func set_dancing(enabled: bool) -> void:
	_is_dancing = enabled
	isaac_sprite.visible = not enabled
	dance_sprite.visible = enabled

	if enabled:
		anim_player.stop()
		anim_player.play(ANIM_DANCE)
		if _dance_music_enabled and dance_music != null and dance_music.stream != null and not dance_music.playing:
			dance_music.play()
	else:
		if dance_music != null:
			dance_music.stop()
		anim_player.stop()
		anim_player.play(ANIM_IDLE)

	_sync_menu_checks()


func _on_animation_finished(anim_name: StringName) -> void:
	if anim_name == ANIM_THUMBS_UP and not _is_dancing:
		anim_player.play(ANIM_IDLE)


func _update_counter_display() -> void:
	var formatted := _format_with_spaces(click_count)
	counter_label.text = formatted
	var char_len := formatted.length()
	if char_len > 12:
		counter_label.add_theme_font_size_override("font_size", 11)
	elif char_len > 9:
		counter_label.add_theme_font_size_override("font_size", 13)
	else:
		counter_label.remove_theme_font_size_override("font_size")


func _format_with_spaces(value: int) -> String:
	var s := str(maxi(0, value))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			out = " " + out
		out = s[i] + out
		count += 1
	return out


func _setup_menu() -> void:
	options_menu.clear()
	options_menu.add_check_item("Танцевать", MenuId.DANCE)
	options_menu.add_check_item("Музыка танца", MenuId.DANCE_MUSIC)
	options_menu.add_separator()
	options_menu.add_check_item("Поверх всех окон", MenuId.ALWAYS_ON_TOP)
	options_menu.add_check_item("Звук лайка", MenuId.SOUND)
	options_menu.add_separator()
	options_menu.add_radio_check_item("Размер: 0.75x", MenuId.SCALE_75)
	options_menu.add_radio_check_item("Размер: 1x", MenuId.SCALE_100)
	options_menu.add_radio_check_item("Размер: 1.25x", MenuId.SCALE_125)
	options_menu.add_separator()
	options_menu.add_item("Сбросить счётчик", MenuId.RESET)
	options_menu.add_item("Выход", MenuId.QUIT)
	_sync_menu_checks()


func _sync_menu_checks() -> void:
	options_menu.set_item_checked(options_menu.get_item_index(MenuId.DANCE), _is_dancing)
	options_menu.set_item_checked(options_menu.get_item_index(MenuId.DANCE_MUSIC), _dance_music_enabled)
	options_menu.set_item_checked(options_menu.get_item_index(MenuId.ALWAYS_ON_TOP), _always_on_top)
	options_menu.set_item_checked(options_menu.get_item_index(MenuId.SOUND), _sound_enabled)
	options_menu.set_item_checked(options_menu.get_item_index(MenuId.SCALE_75), is_equal_approx(_window_scale, 0.75))
	options_menu.set_item_checked(options_menu.get_item_index(MenuId.SCALE_100), is_equal_approx(_window_scale, 1.0))
	options_menu.set_item_checked(options_menu.get_item_index(MenuId.SCALE_125), is_equal_approx(_window_scale, 1.25))


func _on_menu_button_pressed() -> void:
	var win := get_window()
	var btn_rect := menu_button.get_global_rect()
	var popup_pos := win.position + Vector2i(int(btn_rect.position.x), int(btn_rect.end.y) + 4)
	_open_menu_at(popup_pos)


func _open_menu_at(screen_pos: Vector2i) -> void:
	_sync_menu_checks()
	options_menu.reset_size()
	options_menu.position = screen_pos
	options_menu.popup()


func _on_menu_id_pressed(id: int) -> void:
	match id:
		MenuId.DANCE:
			set_dancing(not _is_dancing)
		MenuId.DANCE_MUSIC:
			_dance_music_enabled = not _dance_music_enabled
			if _is_dancing and dance_music != null:
				if _dance_music_enabled and dance_music.stream != null:
					if not dance_music.playing:
						dance_music.play()
				else:
					dance_music.stop()
			_save_config()
		MenuId.ALWAYS_ON_TOP:
			_always_on_top = not _always_on_top
			get_window().always_on_top = _always_on_top
			_save_config()
		MenuId.SOUND:
			_sound_enabled = not _sound_enabled
			_save_config()
		MenuId.SCALE_75:
			_apply_scale(0.75)
		MenuId.SCALE_100:
			_apply_scale(1.0)
		MenuId.SCALE_125:
			_apply_scale(1.25)
		MenuId.RESET:
			click_count = 0
			_update_counter_display()
			_save_config()
		MenuId.QUIT:
			_save_config()
			_stop_global_input_helper()
			get_tree().quit()
	_sync_menu_checks()


func _apply_scale(new_scale: float, save_after: bool = true) -> void:
	_window_scale = new_scale
	var win := get_window()
	win.size = Vector2i(roundi(BASE_SIZE.x * new_scale), roundi(BASE_SIZE.y * new_scale))
	_clamp_window_to_screen()
	if save_after:
		_save_config()


func _clamp_window_to_screen() -> void:
	var win := get_window()
	var screen_rect := DisplayServer.screen_get_usable_rect(win.current_screen)
	var max_x := screen_rect.position.x + maxi(0, screen_rect.size.x - win.size.x)
	var max_y := screen_rect.position.y + maxi(0, screen_rect.size.y - win.size.y)
	win.position = Vector2i(
		clampi(win.position.x, screen_rect.position.x, max_x),
		clampi(win.position.y, screen_rect.position.y, max_y)
	)


func _ensure_helper_extracted() -> String:
	if FileAccess.file_exists(USER_HELPER_PATH) and FileAccess.get_sha256(USER_HELPER_PATH) == HELPER_BLOB.HELPER_SHA256:
		return ProjectSettings.globalize_path(USER_HELPER_PATH)

	var bytes: PackedByteArray = Marshalls.base64_to_raw(HELPER_BLOB.HELPER_BASE64)
	if bytes.is_empty():
		push_warning("[IsaacBongo] Embedded helper blob failed to decode.")
		return ""

	var f := FileAccess.open(USER_HELPER_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[IsaacBongo] Failed to write helper to %s (err=%d)." % [USER_HELPER_PATH, FileAccess.get_open_error()])
		return ""
	f.store_buffer(bytes)
	f.close()
	return ProjectSettings.globalize_path(USER_HELPER_PATH)


func _start_global_input_helper() -> void:
	var err := _udp.bind(0, "127.0.0.1")
	if err != OK:
		push_warning("[IsaacBongo] UDP bind failed (%d), using local input fallback." % err)
		return

	var port := _udp.get_local_port()
	var exe_path := _ensure_helper_extracted()
	if exe_path.is_empty():
		push_warning("[IsaacBongo] Embedded global input helper unavailable, using local input fallback.")
		_udp.close()
		return

	var args := PackedStringArray([str(port), str(OS.get_process_id())])
	_helper_pid = OS.create_process(exe_path, args, false)
	if _helper_pid <= 0:
		push_warning("[IsaacBongo] Failed to launch extracted global_input_helper.exe, using local input fallback.")
		_udp.close()
		return

	_helper_active = true
	print("[IsaacBongo] Global input helper started (pid=%d, port=%d)" % [_helper_pid, port])


func _stop_global_input_helper() -> void:
	_helper_active = false
	_udp.close()
	if _helper_pid > 0:
		OS.kill(_helper_pid)
		_helper_pid = -1


func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	click_count = int(cfg.get_value("stats", "click_count", 0))
	_always_on_top = bool(cfg.get_value("window", "always_on_top", true))
	_sound_enabled = bool(cfg.get_value("audio", "sound_enabled", false))
	_dance_music_enabled = bool(cfg.get_value("audio", "dance_music_enabled", true))
	_window_scale = float(cfg.get_value("window", "scale", 1.0))
	if cfg.has_section_key("window", "pos"):
		var pos_val: Variant = cfg.get_value("window", "pos", Vector2i.ZERO)
		if pos_val is Vector2i:
			_saved_pos = pos_val
			_has_saved_pos = true


func _save_config() -> void:
	_save_dirty = false
	_save_timer = 0.0
	var cfg := ConfigFile.new()
	cfg.set_value("stats", "click_count", click_count)
	cfg.set_value("window", "always_on_top", _always_on_top)
	cfg.set_value("window", "scale", _window_scale)
	cfg.set_value("window", "pos", get_window().position)
	cfg.set_value("audio", "sound_enabled", _sound_enabled)
	cfg.set_value("audio", "dance_music_enabled", _dance_music_enabled)
	cfg.save(SAVE_PATH)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_config()
		_stop_global_input_helper()


func _exit_tree() -> void:
	_save_config()
	_stop_global_input_helper()
