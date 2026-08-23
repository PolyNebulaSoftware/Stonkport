extends Node
## Tray launcher module (desktop builds only).
##
## Serves web_dist/ over localhost with a tiny HTTP server, opens the served
## web app in the default browser right away, and lives in the system tray via
## the built-in StatusIndicator node. On startup the main window is restyled
## into a borderless splash banner (icon + title) for a few seconds, then the
## app drops to the tray.
##
## Godot 4.7 blocks hiding the main window through the Window API ("Can't
## change visibility of main window"), so true hide/show is done by shelling
## out to StonkportTrayHelper.exe (user32 ShowWindowAsync on our HWND — async
## because the synchronous call deadlocks against OS.execute). When the
## helper is missing, a plain engine minimize is used instead — functional,
## but it keeps a taskbar button.
##
## On the Web platform the module disables itself entirely.

const WebServerScript := preload("res://scripts/tray/local_web_server.gd")

const PORT_HINT := 17400
const WEB_DIR_NAME := "web_dist"
const TOOLTIP_TEXT := "Stonkport"

const MENU_OPEN_WEB_APP := 0
const MENU_SHOW_WINDOW := 1
const MENU_QUIT := 2
const OPEN_DEBOUNCE_MSEC := 1500

const BANNER_DURATION_SEC := 3.0
const BANNER_SIZE := Vector2i(420, 132)
const BANNER_BG := Color(0.0509804, 0.0666667, 0.0901961)
const BANNER_FG := Color(0.902, 0.929, 0.953)
const HELPER_NAME := "StonkportTrayHelper.exe"
const HELPER_SEARCH_SUBDIRS := ["", "build/windows"]

var _indicator: StatusIndicator
var _menu: PopupMenu
var _server: Node
var _url := ""
var _last_open_msec := -OPEN_DEBOUNCE_MSEC
var _banner: Control
var _banner_active := false
var _pre_banner_size := Vector2i.ZERO


func _ready() -> void:
	if not _should_activate():
		queue_free()
		return
	if _is_port_taken(PORT_HINT):
		# Base port owned: reveal it only if it is really our launcher;
		# otherwise it is some unrelated program and start() scans onward.
		if await _probe_existing_instance():
			print("TrayLauncher: instance already running — revealing it.")
			OS.shell_open("http://127.0.0.1:%d/" % PORT_HINT)
			get_tree().quit()
			return
	_server = WebServerScript.new() as Node
	add_child(_server)
	var root := _resolve_web_root()
	if not DirAccess.dir_exists_absolute(root):
		push_warning("TrayLauncher: '%s' is missing — export the Web preset into it first. Requests will 404." % root)
	var port: int = _server.start(PORT_HINT, root)
	if port == -1:
		queue_free()
		return
	_url = "http://127.0.0.1:%d/" % port
	_build_tray_ui()
	# Closing the window must hide to tray, not terminate the app.
	get_tree().auto_accept_quit = false
	if OS.has_feature("editor"):
		# Launched from the editor (F5): keep the server and tray, but don't
		# hijack the default browser on every test run.
		print("TrayLauncher: editor run — web app available at ", _url)
	else:
		_open_web_app()
	_run_startup_banner()


## Activate only on native desktop platforms. Whitelisting display servers
## (rather than only blacklisting "web"/"headless") guarantees the module stays
## inert everywhere else — otherwise the browser-tab opener above could run
## inside the WASM build and reopen its own URL in an endless tab loop.
func _should_activate() -> bool:
	if OS.has_feature("web") or OS.has_feature("android") or OS.has_feature("ios"):
		return false
	if not ClassDB.class_exists("StatusIndicator"):
		return false
	# DisplayServer.get_name() is capitalized on some platforms ("Windows").
	return DisplayServer.get_name().to_lower() in ["windows", "x11", "macos"]


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _banner_active:
			_end_banner_and_restore()
		_hide_to_tray()


func _build_tray_ui() -> void:
	_menu = PopupMenu.new()
	_menu.add_item("Open Web App", MENU_OPEN_WEB_APP)
	_menu.add_item("Show Window", MENU_SHOW_WINDOW)
	_menu.add_separator()
	_menu.add_item("Quit", MENU_QUIT)
	_menu.id_pressed.connect(_on_menu_id_pressed)
	add_child(_menu)

	_indicator = StatusIndicator.new()
	# Enter the tree first: StatusIndicator resolves its menu NodePath eagerly.
	add_child(_indicator)
	_indicator.icon = load("res://icon.svg")
	_indicator.tooltip = TOOLTIP_TEXT
	# StatusIndicator.menu is a NodePath pointing at a PopupMenu in the tree.
	_indicator.menu = _menu.get_path()
	_indicator.pressed.connect(_on_indicator_pressed)


## Show a small borderless banner window (icon + title) for a few seconds,
## then restore the real UI and drop to the tray. The main window itself plays
## the banner: Godot 4.7 will not let us hide it during this phase anyway.
func _run_startup_banner() -> void:
	await get_tree().process_frame  # current_scene enters the tree after autoloads
	var win := get_window()
	var scene := get_tree().current_scene
	_pre_banner_size = win.size
	_banner = _build_banner()
	win.add_child(_banner)
	if scene != null:
		scene.visible = false  # free the window to shrink below the UI min size
	_banner_active = true
	win.borderless = true
	win.always_on_top = true
	win.size = BANNER_SIZE
	win.move_to_center()
	await get_tree().create_timer(BANNER_DURATION_SEC).timeout
	if not _banner_active:
		return  # closed early (Alt+F4); _notification already restored + hid us
	_end_banner_and_restore()
	_hide_to_tray()


func _end_banner_and_restore() -> void:
	_banner_active = false
	if _banner != null:
		_banner.queue_free()
		_banner = null
	var win := get_window()
	var scene := get_tree().current_scene
	if scene != null:
		scene.visible = true
	win.borderless = false
	win.always_on_top = false
	if _pre_banner_size != Vector2i.ZERO:
		win.size = _pre_banner_size
	win.move_to_center()


func _build_banner() -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = BANNER_BG
	panel.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 18)
	panel.add_child(hbox)

	var icon_rect := TextureRect.new()
	icon_rect.texture = load("res://icon.svg")
	icon_rect.custom_minimum_size = Vector2(72, 72)
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hbox.add_child(icon_rect)

	var title := Label.new()
	title.text = TOOLTIP_TEXT
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", BANNER_FG)
	hbox.add_child(title)
	return panel


## Prefer a web_dist/ folder shipped next to the executable so the web build
## can be swapped without re-exporting; fall back to the pck-embedded copy.
func _resolve_web_root() -> String:
	var sibling := OS.get_executable_path().get_base_dir().path_join(WEB_DIR_NAME)
	if DirAccess.dir_exists_absolute(sibling):
		return sibling
	return "res://" + WEB_DIR_NAME


func _is_port_taken(port: int) -> bool:
	var probe := TCPServer.new()
	var taken := probe.listen(port, "127.0.0.1") != OK
	if not taken:
		probe.stop()
	return taken


## True only when something on PORT_HINT answers our launcher ping, i.e. it is
## another instance of this app rather than an unrelated local server.
func _probe_existing_instance() -> bool:
	var req := HTTPRequest.new()
	req.timeout = 1.5
	add_child(req)
	var err := req.request("http://127.0.0.1:%d/%s" % [PORT_HINT, WebServerScript.LAUNCHER_PING_PATH])
	if err != OK:
		req.queue_free()
		return false
	var result: Array = await req.request_completed
	req.queue_free()
	if result[0] != OK:
		return false
	return PackedByteArray(result[3]).get_string_from_ascii() == WebServerScript.LAUNCHER_PING_BODY


## Locate StonkportTrayHelper.exe: next to the executable first (exported
## builds), then build/windows/ inside the project for dev runs where the
## executable lives in the editor installation.
func _find_helper() -> String:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var candidates := []
	for rel in HELPER_SEARCH_SUBDIRS:
		candidates.append(exe_dir.path_join(HELPER_NAME) if rel.is_empty() else exe_dir.path_join(rel).path_join(HELPER_NAME))
	candidates.append(ProjectSettings.globalize_path("res://build/windows").path_join(HELPER_NAME))
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


## Run a window command through the Win32 helper. Returns false when the
## helper is unavailable or the operation failed.
func _helper_window_cmd(cmd: String) -> bool:
	var helper := _find_helper()
	if helper.is_empty():
		push_warning("TrayLauncher: %s not found — falling back to engine window handling." % HELPER_NAME)
		return false
	var hwnd := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var output := []
	return OS.execute(helper, PackedStringArray([cmd, str(hwnd)]), output) == 0


## Hide the main window so only the tray icon remains. Godot 4.7 forbids
## hiding the main window via the Window API, hence the helper detour.
func _hide_to_tray() -> void:
	if _helper_window_cmd("hide"):
		return
	# Fallback: engine minimize stays functional but keeps a taskbar button.
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)


func _on_indicator_pressed(_position: Vector2i, button: MouseButton) -> void:
	if button == MOUSE_BUTTON_LEFT:
		_open_web_app()


func _on_menu_id_pressed(menu_id: int) -> void:
	match menu_id:
		MENU_OPEN_WEB_APP:
			_open_web_app()
		MENU_SHOW_WINDOW:
			_show_window()
		MENU_QUIT:
			_quit()


func _open_web_app() -> void:
	# Debounce: a stuck/repeated pressed signal must not spawn tab storms.
	var now := Time.get_ticks_msec()
	if now - _last_open_msec < OPEN_DEBOUNCE_MSEC:
		return
	_last_open_msec = now
	OS.shell_open(_url)


func _show_window() -> void:
	var restored := _helper_window_cmd("show")
	if not restored:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# Foregrounding from Godot itself avoids any cross-thread messaging in
	# the helper while our main thread is blocked inside OS.execute().
	DisplayServer.window_move_to_foreground()


func _quit() -> void:
	if _server != null:
		_server.stop()
	get_tree().quit()
