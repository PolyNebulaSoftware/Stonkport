extends Node
## Tray launcher module (desktop builds only).
##
## Minimizes LocalStoport to the system tray via the built-in StatusIndicator
## node, serves web_dist/ over localhost with a tiny HTTP server, and opens
## the served web app in the default browser when the tray icon is clicked.
## On the Web platform the module disables itself entirely.

const WebServerScript := preload("res://scripts/tray/local_web_server.gd")

const PORT_HINT := 17400
const WEB_DIR_NAME := "web_dist"
const TOOLTIP_TEXT := "LocalStoport"

const MENU_OPEN_WEB_APP := 0
const MENU_SHOW_WINDOW := 1
const MENU_QUIT := 2
const OPEN_DEBOUNCE_MSEC := 1500

var _indicator: StatusIndicator
var _menu: PopupMenu
var _server: Node
var _url := ""
var _last_open_msec := -OPEN_DEBOUNCE_MSEC


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
	_hide_window.call_deferred()


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
		get_window().hide()


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
	var win := get_window()
	win.show()
	win.move_to_foreground()


func _quit() -> void:
	if _server != null:
		_server.stop()
	get_tree().quit()


func _hide_window() -> void:
	get_window().hide()
