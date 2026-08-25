extends Control
## Trades screen: state filter chips, asset search, a square add-trade button
## pinned top-right, and the journal rendered as a GridContainer so the
## header and every row share exact column alignment.

const TradeDialogScene := preload("res://scenes/dialogs/trade_dialog.tscn")

## Column layout shared by the header and every trade row.
const COLS := [
	{"ratio": 1.5, "align": HORIZONTAL_ALIGNMENT_LEFT},
	{"ratio": 0.45, "align": HORIZONTAL_ALIGNMENT_CENTER},
	{"ratio": 1.05, "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"ratio": 1.1, "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"ratio": 0.85, "align": HORIZONTAL_ALIGNMENT_CENTER},
	{"ratio": 0.75, "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"ratio": 1.3, "align": HORIZONTAL_ALIGNMENT_RIGHT},
]
const HEADERS := ["ASSET", "DIR", "QTY @ ENTRY", "POSITION", "STATE", "HOLD", "P/L"]

## Column indices that collapse first when the workspace narrows.
const COLS_POSITION := 3
const COLS_HOLD := 5

var _min_ts := 0
var _max_ts := 0
var _state_filter := "all"  # all | open | closed
var _search := ""
var _grid: GridContainer
var _empty: Label
var _dialog: AcceptDialog
var _vp_width := 0.0

var _price_provider := func(asset: String) -> float: return MarketSimulator.get_price(asset)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 4)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	_vp_width = get_viewport().get_visible_rect().size.x

	vbox.add_child(_build_toolbar())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = COLS.size()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 2)
	scroll.add_child(_grid)

	_empty = Label.new()
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.add_theme_color_override("font_color", Utils.MUTED)
	_empty.visible = false
	vbox.add_child(_empty)

	get_viewport().size_changed.connect(_on_viewport_resized)
	TradeManager.trades_changed.connect(_refresh)
	MarketSimulator.market_ticked.connect(_refresh)
	_refresh()


func set_range(min_ts: int, max_ts: int) -> void:
	_min_ts = min_ts
	_max_ts = max_ts
	_refresh()


func _build_toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)

	var group := ButtonGroup.new()
	for chip_def in [["All", "all"], ["Open", "open"], ["Closed", "closed"]]:
		var chip := Button.new()
		chip.text = chip_def[0]
		chip.toggle_mode = true
		chip.button_group = group
		chip.focus_mode = Control.FOCUS_NONE
		chip.add_theme_font_size_override("font_size", 11)
		if chip_def[1] == "all":
			chip.button_pressed = true
		chip.pressed.connect(_on_state_chip.bind(chip_def[1]))
		bar.add_child(chip)

	var search := LineEdit.new()
	search.placeholder_text = "Search asset"
	search.custom_minimum_size = Vector2(160, 0)
	search.clear_button_enabled = true
	search.text_changed.connect(func(text: String):
		_search = text.strip_edges().to_upper()
		_refresh())
	bar.add_child(search)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(spacer)

	var add_btn := Button.new()
	add_btn.text = "+"
	add_btn.tooltip_text = "New trade"
	add_btn.focus_mode = Control.FOCUS_NONE
	add_btn.custom_minimum_size = Vector2(30, 30)
	add_btn.add_theme_font_size_override("font_size", 16)
	add_btn.pressed.connect(_open_create)
	bar.add_child(add_btn)
	return bar


func _on_state_chip(filter: String) -> void:
	_state_filter = filter
	_refresh()


func _refresh() -> void:
	if _grid == null:
		return
	for child in _grid.get_children():
		child.queue_free()

	_fill_header()

	var query := _search.strip_edges().to_upper()
	var rows: Array = []
	for t in TradeManager.trades:
		if _state_filter != "all" and str(t.get("state", "")) != _state_filter:
			continue
		if query != "" and not str(t.get("asset", "")).contains(query):
			continue
		if not TradeMetrics.in_range(t, _min_ts, _max_ts):
			continue
		rows.append(t)
	rows.sort_custom(func(a, b): return TradeMetrics.last_activity(a) > TradeMetrics.last_activity(b))

	for t in rows:
		_append_row(t)

	var has_trades := not TradeManager.trades.is_empty()
	_empty.text = "No trades yet - press + to log your first trade." if not has_trades \
			else "No trades match the current filters."
	_empty.visible = rows.is_empty()


func _fill_header() -> void:
	for i in COLS.size():
		var label := Label.new()
		label.text = HEADERS[i]
		label.horizontal_alignment = COLS[i].align
		label.add_theme_color_override("font_color", Utils.MUTED)
		label.add_theme_font_size_override("font_size", 10)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_grid.add_child(label)


## Secondary columns drop out as the workspace narrows.
func _col_visible(index: int) -> bool:
	match index:
		COLS_POSITION:
			return _vp_width >= 820.0
		COLS_HOLD:
			return _vp_width >= 720.0
		_:
			return true


func _on_viewport_resized() -> void:
	_vp_width = get_viewport().get_visible_rect().size.x
	_refresh()


func _append_row(trade: Dictionary) -> void:
	var bd := TradeMetrics.breakdown(trade, _price_provider)
	var now := int(Time.get_unix_time_from_system())
	var id := str(trade.get("id", ""))

	# Asset + type badge
	var asset_cell := HBoxContainer.new()
	asset_cell.alignment = BoxContainer.ALIGNMENT_BEGIN
	asset_cell.add_theme_constant_override("separation", 6)
	var name_label := Label.new()
	name_label.text = str(trade.get("asset", "?"))
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Utils.TEXT)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	asset_cell.add_child(name_label)
	asset_cell.add_child(_badge(_type_tag(str(trade.get("asset_type", "stock"))), _type_color(trade)))
	_add_cell(asset_cell, 0, id)

	var dir_label := Label.new()
	dir_label.text = "L" if str(trade.get("direction", "long")) == "long" else "S"
	dir_label.add_theme_color_override("font_color", Utils.ACCENT if dir_label.text == "L" else Utils.ORANGE)
	_add_cell(dir_label, 1, id)

	_add_cell(_cell_label("%s @ %s" % [Utils.qty(float(bd.entry_qty)), Utils.money(float(bd.avg_entry))]), 2, id)

	var open_state := str(trade.get("state", "open")) == "open"

	# Current market value of the remaining position; closed trades have none.
	var pos_text := "-"
	if open_state:
		pos_text = Utils.money(float(bd.net_qty) * float(bd.mark))
	_add_cell(_cell_label(pos_text, Utils.TEXT if open_state else Utils.MUTED), 3, id)

	_add_cell(_badge("OPEN" if open_state else "CLOSED",
			Utils.GREEN if open_state else Utils.MUTED), 4, id)

	var closed_at := int(trade.get("closed_at", 0))
	var hold := 0.0
	if open_state:
		hold = float(now - int(trade.get("opened_at", 0)))
	else:
		hold = float(closed_at - int(trade.get("opened_at", 0)))
	_add_cell(_cell_label(Utils.duration(hold)), 5, id)

	_add_cell(_cell_label("%s (%s)" % [Utils.money(float(bd.pnl), true), Utils.pct(float(bd.pnl_pct))],
			Utils.change_color(float(bd.pnl))), 6, id)


func _add_cell(content: Control, index: int, trade_id := "") -> void:
	if not _col_visible(index):
		content.queue_free()
		return
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if content is Label:
		content.horizontal_alignment = COLS[index].align
	elif content is HBoxContainer:
		match COLS[index].align:
			HORIZONTAL_ALIGNMENT_CENTER:
				content.alignment = BoxContainer.ALIGNMENT_CENTER
			HORIZONTAL_ALIGNMENT_RIGHT:
				content.alignment = BoxContainer.ALIGNMENT_END
	content.mouse_filter = Control.MOUSE_FILTER_STOP
	if trade_id != "":
		content.gui_input.connect(_on_cell_input.bind(trade_id))
	_grid.add_child(content)


func _on_cell_input(event: InputEvent, trade_id: String) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_open_edit(trade_id)


func _cell_label(text: String, color := Utils.TEXT) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 12)
	return label


func _badge(text: String, fg: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", fg)
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_stylebox_override("normal", Utils.flat_style(Color(fg.r, fg.g, fg.b, 0.16), Color.TRANSPARENT, 4, 5, 1))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _type_tag(asset_type: String) -> String:
	return {
		"stock": "STOCK",
		"crypto": "CRYPTO",
		"custom": "CUSTOM",
		"option": "OPTION",
	}.get(asset_type, "STOCK")


func _type_color(trade: Dictionary) -> Color:
	match str(trade.get("asset_type", "stock")):
		"crypto":
			return Utils.ORANGE
		"option":
			return Utils.PURPLE
		"custom":
			return Utils.MUTED
		_:
			return Utils.ACCENT


func _open_create() -> void:
	_ensure_dialog().open_create()


func _open_edit(id: String) -> void:
	_ensure_dialog().open_edit(id)


func _ensure_dialog() -> AcceptDialog:
	if _dialog == null:
		_dialog = TradeDialogScene.instantiate()
		add_child(_dialog)
	return _dialog
