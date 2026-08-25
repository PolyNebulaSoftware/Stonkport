extends PanelContainer
## Top bar filtering trades by activity date: preset chips, custom From/To
## dates, and a dual-grip histogram timeline of trade activity. Emits
## range_changed(min_ts, max_ts); a bound of 0 means unbounded (all time).

signal range_changed(min_ts: int, max_ts: int)

const DAY := 86400
const PRESETS := ["All", "7D", "30D", "90D", "YTD", "1Y"]
const HistogramScript := preload("res://scripts/ui/time_histogram.gd")

var _from_edit: LineEdit
var _to_edit: LineEdit
var _chips := {}
var _chip_group := ButtonGroup.new()
var _histogram: Control
var _min_ts := 0
var _max_ts := 0


func _ready() -> void:
	add_theme_stylebox_override("panel", Utils.panel_style())

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	# Wraps chips/dates onto extra lines on narrow layouts.
	var hbox := HFlowContainer.new()
	hbox.add_theme_constant_override("h_separation", 6)
	hbox.add_theme_constant_override("v_separation", 4)
	vbox.add_child(hbox)

	for preset in PRESETS:
		var chip := Button.new()
		chip.text = preset
		chip.toggle_mode = true
		chip.button_group = _chip_group
		chip.focus_mode = Control.FOCUS_NONE
		chip.add_theme_font_size_override("font_size", 11)
		chip.pressed.connect(_on_preset.bind(preset))
		_chips[preset] = chip
		hbox.add_child(chip)
	_chips["All"].button_pressed = true

	hbox.add_child(_gap(10))

	hbox.add_child(_caption("From"))
	_from_edit = _make_date_edit()
	hbox.add_child(_from_edit)

	hbox.add_child(_caption("to"))
	_to_edit = _make_date_edit("Now")
	hbox.add_child(_to_edit)

	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.add_theme_font_size_override("font_size", 11)
	reset_btn.pressed.connect(reset)
	hbox.add_child(reset_btn)

	_histogram = HistogramScript.new()
	_histogram.custom_minimum_size = Vector2(0, 54)
	_histogram.visible = false
	_histogram.range_changed.connect(_on_histogram_range)
	vbox.add_child(_histogram)

	TradeManager.trades_changed.connect(_on_trades_changed)
	# Deferred so the shell has connected before the initial emission, and so
	# the histogram picks up the journal loaded by the autoloads.
	_on_trades_changed.call_deferred()
	_emit_range.call_deferred(0, 0)


func range_values() -> Array:
	return [_min_ts, _max_ts]


func reset() -> void:
	_select_chip("All")
	_on_preset("All")


func _on_preset(preset: String) -> void:
	var now := int(Time.get_unix_time_from_system())
	match preset:
		"7D":
			_min_ts = now - 7 * DAY
		"30D":
			_min_ts = now - 30 * DAY
		"90D":
			_min_ts = now - 90 * DAY
		"YTD":
			var dt := Time.get_datetime_dict_from_unix_time(now)
			_min_ts = int(Time.get_unix_time_from_datetime_dict({
				"year": dt.year, "month": 1, "day": 1,
				"hour": 0, "minute": 0, "second": 0,
			}))
		"1Y":
			_min_ts = now - 365 * DAY
		_:
			_min_ts = 0
	_max_ts = 0
	_from_edit.text = Utils.date_str(_min_ts) if _min_ts > 0 else ""
	_to_edit.text = ""
	if _min_ts == 0:
		_histogram.clear_selection()
	else:
		_histogram.set_selection(_min_ts, _max_ts)
	_emit_range(_min_ts, _max_ts)


func _on_dates_edited(_text := "") -> void:
	var from_ts := 0
	var to_ts := 0
	var valid := true
	if not _from_edit.text.strip_edges().is_empty():
		from_ts = Utils.parse_date(_from_edit.text)
		valid = valid and from_ts > 0
	if not _to_edit.text.strip_edges().is_empty():
		to_ts = Utils.parse_date(_to_edit.text, true)
		valid = valid and to_ts > 0
	if from_ts > 0 and to_ts > 0 and from_ts > to_ts:
		valid = false
	_style_edit(_from_edit, valid)
	_style_edit(_to_edit, valid)
	if not valid:
		return
	_deselect_chips()
	_min_ts = from_ts
	_max_ts = to_ts
	if _histogram.has_domain():
		if from_ts == 0 and to_ts == 0:
			_histogram.clear_selection()
		else:
			_histogram.set_selection(from_ts, to_ts)
	_emit_range(_min_ts, _max_ts)


func _on_histogram_range(min_ts: int, max_ts: int) -> void:
	_deselect_chips()
	_min_ts = min_ts
	_max_ts = max_ts
	_from_edit.text = Utils.date_str(min_ts)
	_to_edit.text = Utils.date_str(max_ts)
	_style_edit(_from_edit, true)
	_style_edit(_to_edit, true)
	_emit_range(_min_ts, _max_ts)


func _on_trades_changed() -> void:
	_histogram.set_trades(TradeManager.trades)


func _emit_range(min_ts: int, max_ts: int) -> void:
	_min_ts = min_ts
	_max_ts = max_ts
	range_changed.emit(_min_ts, _max_ts)


func _select_chip(preset: String) -> void:
	for key in _chips:
		_chips[key].button_pressed = key == preset


func _deselect_chips() -> void:
	for key in _chips:
		_chips[key].button_pressed = false


func _make_date_edit(placeholder := "YYYY-MM-DD") -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(92, 0)
	edit.clear_button_enabled = true
	edit.focus_mode = Control.FOCUS_CLICK
	edit.text_changed.connect(_on_dates_edited)
	edit.text_submitted.connect(func(_t: String): _on_dates_edited())
	return edit


func _style_edit(edit: LineEdit, valid: bool) -> void:
	edit.add_theme_color_override("font_color", Utils.TEXT if valid else Utils.RED)


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Utils.MUTED)
	label.add_theme_font_size_override("font_size", 12)
	return label


func _gap(width: float) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(width, 0)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer
