extends PanelContainer
## Right-hand icon-only navigation rail: Stonkport logo, Dashboard, Trades,
## Analyze, Settings.

signal nav_selected(screen: String)  # "dashboard" | "trades" | "analyze" | "settings"

const WIDTH := 56.0

var _buttons := {}
var _group := ButtonGroup.new()


func _ready() -> void:
	custom_minimum_size = Vector2(WIDTH, 0)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	var logo := TextureRect.new()
	logo.texture = load("res://icon.svg")
	logo.custom_minimum_size = Vector2(WIDTH, 46)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.tooltip_text = "Stonkport"
	vbox.add_child(logo)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 4)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(gap)

	_add_button(vbox, "dashboard", NavIcon.Kind.DASHBOARD, "Dashboard")
	_add_button(vbox, "trades", NavIcon.Kind.TRADES, "Trades")
	_add_button(vbox, "analyze", NavIcon.Kind.ANALYZE, "Analyze")
	_add_button(vbox, "settings", NavIcon.Kind.SETTINGS, "Settings")

	var flex := Control.new()
	flex.size_flags_vertical = Control.SIZE_EXPAND_FILL
	flex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(flex)

	set_active("dashboard")


func _add_button(parent: Control, id: String, kind: int, tip: String) -> void:
	var btn := Button.new()
	btn.toggle_mode = true
	btn.button_group = _group
	btn.custom_minimum_size = Vector2(WIDTH - 10, 40)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.tooltip_text = tip
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_stylebox_override("normal", _style(false))
	btn.add_theme_stylebox_override("hover", _style(false, true))
	btn.add_theme_stylebox_override("pressed", _style(true))
	btn.add_theme_stylebox_override("hover_pressed", _style(true))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var icon := NavIcon.new()
	icon.kind = kind
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 11
	icon.offset_top = 10
	icon.offset_right = -11
	icon.offset_bottom = -10
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(icon)
	btn.set_meta("icon", icon)

	btn.pressed.connect(func(): _on_pressed(id))
	_buttons[id] = btn
	parent.add_child(btn)


func _on_pressed(id: String) -> void:
	set_active(id)
	nav_selected.emit(id)


func set_active(id: String) -> void:
	for key in _buttons:
		var btn: Button = _buttons[key]
		btn.button_pressed = key == id
		var icon: NavIcon = btn.get_meta("icon")
		icon.set_active(key == id)


func _style(active: bool, hover := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(10)
	if active:
		sb.bg_color = Color(0.114, 0.169, 0.244)
	elif hover:
		sb.bg_color = Color(0.114, 0.129, 0.161)
	else:
		sb.bg_color = Color.TRANSPARENT
	return sb


class NavIcon extends Control:
	enum Kind { DASHBOARD, TRADES, ANALYZE, SETTINGS }

	var kind: int = Kind.DASHBOARD
	var active := false

	func set_active(value: bool) -> void:
		active = value
		queue_redraw()

	func _draw() -> void:
		var c := Utils.ACCENT if active else Utils.MUTED
		match kind:
			Kind.DASHBOARD:
				for rect in [Rect2(2, 2, 8, 8), Rect2(12, 2, 8, 8), Rect2(2, 12, 8, 8), Rect2(12, 12, 8, 8)]:
					_rounded(rect, c)
			Kind.TRADES:
					draw_line(Vector2(3, 5), Vector2(19, 5), c, 2.0)
					draw_line(Vector2(3, 11), Vector2(14, 11), c, 2.0)
					draw_line(Vector2(3, 17), Vector2(17, 17), c, 2.0)
			Kind.ANALYZE:
				draw_line(Vector2(7, 3), Vector2(7, 19), c, 1.6)
				draw_rect(Rect2(4.5, 7, 5, 7), c)
				draw_line(Vector2(16, 4), Vector2(16, 17), c, 1.6)
				draw_rect(Rect2(13.5, 9, 5, 6), c)
			Kind.SETTINGS:
				for i in 3:
					var y := 4.0 + i * 7.0
					draw_line(Vector2(2, y), Vector2(20, y), c, 2.0)
					var knobs := [7.0, 15.0, 10.0]
					draw_circle(Vector2(knobs[i], y), 3.4, Utils.BG)
					draw_arc(Vector2(knobs[i], y), 3.4, 0.0, TAU, 24, c, 2.0)

	func _rounded(rect: Rect2, color: Color) -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = color
		sb.set_corner_radius_all(2)
		sb.draw(get_canvas_item(), rect)
