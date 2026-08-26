extends Control
## Root shell: center workspace (time-range bar above the active screen) with
## the icon-only navigation rail docked on the right.

const NavRailScene := preload("res://scenes/nav_rail.tscn")
const RangeBarScene := preload("res://scenes/time_range_bar.tscn")
const DashboardScene := preload("res://scenes/dashboard.tscn")
const TradesScene := preload("res://scenes/trades_screen.tscn")
const AnalyzeScene := preload("res://scenes/analyze_screen.tscn")
const SettingsScene := preload("res://scenes/settings_screen.tscn")

var _rail: Control
var _bar: Control
var _screens := {}
var _current := ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_apply_interface_scale()
	TradeManager.settings_changed.connect(_apply_interface_scale)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(hbox)

	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(center)

	_bar = RangeBarScene.instantiate()
	center.add_child(_bar)

	var workspace := MarginContainer.new()
	workspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		workspace.add_theme_constant_override(side, 4)
	center.add_child(workspace)

	_screens = {
		"dashboard": DashboardScene.instantiate(),
		"trades": TradesScene.instantiate(),
		"analyze": AnalyzeScene.instantiate(),
		"settings": SettingsScene.instantiate(),
	}
	for id in _screens:
		workspace.add_child(_screens[id])

	_rail = NavRailScene.instantiate()
	hbox.add_child(_rail)

	_bar.range_changed.connect(_on_range_changed)
	_rail.nav_selected.connect(_select)
	_select("dashboard")


func _select(id: String) -> void:
	_current = id
	for key in _screens:
		_screens[key].visible = key == id
	_bar.visible = id != "settings" and id != "analyze"
	_push_range()


func _on_range_changed(_min_ts: int, _max_ts: int) -> void:
	_push_range()


func _push_range() -> void:
	var screen: Control = _screens.get(_current)
	if screen != null and screen.has_method("set_range"):
		var bounds: Array = _bar.range_values()
		screen.set_range(int(bounds[0]), int(bounds[1]))


## True when the WASM build runs in a mobile browser; those get the interface
## scaled up through content scaling (default touch targets are tiny).
func _is_mobile_web() -> bool:
	return OS.has_feature("web") and (OS.has_feature("mobile")
			or OS.has_feature("web_android") or OS.has_feature("web_ios"))


func _apply_interface_scale() -> void:
	if not _is_mobile_web():
		return
	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	win.content_scale_factor = clampf(
			float(TradeManager.settings.get("mobile_scale",
			TradeManager.MOBILE_SCALE_DEFAULT)), 1.0, 3.0)
