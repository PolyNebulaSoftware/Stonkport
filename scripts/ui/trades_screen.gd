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
const COLS_ENTRY := 2
const COLS_POSITION := 3
const COLS_HOLD := 5

var _min_ts := 0
var _max_ts := 0
var _state_filter := "all"  # all | open | closed
var _search := ""
var _card_mode := false     # narrow layout: one wrapped card per trade
var _grid: GridContainer
var _empty: Label
var _dialog: AcceptDialog
var _vp_width := 0.0

# Row hover highlight: one overlay panel stretched over the hovered row.
var _row_cells := {}      # trade_id -> Array[Control]
var _hover_id := ""
var _hover_overlay: Panel

var _price_provider := func(asset: String) -> float: return MarketSimulator.get_price(asset)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 4)
	add_child(margin)

	_hover_overlay = Panel.new()
	_hover_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_overlay.add_theme_stylebox_override("panel", _hover_style())
	_hover_overlay.visible = false
	add_child(_hover_overlay)

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
	_grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(_grid)

	_empty = Label.new()
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.add_theme_color_override("font_color", Utils.MUTED)
	_empty.visible = false
	vbox.add_child(_empty)

	get_viewport().size_changed.connect(_on_viewport_resized)
	TradeManager.trades_changed.connect(_refresh)
	MarketSimulator.market_ticked.connect(_refresh)
	_on_viewport_resized()


func set_range(min_ts: int, max_ts: int) -> void:
	_min_ts = min_ts
	_max_ts = max_ts
	_refresh()


func _build_toolbar() -> Control:
	# Wraps onto multiple lines on narrow/portrait layouts.
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 6)
	bar.add_theme_constant_override("v_separation", 6)

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
	search.custom_minimum_size = Vector2(120, 0)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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


func _process(_delta: float) -> void:
	if _hover_overlay != null and _hover_overlay.visible:
		_update_hover()


func _refresh() -> void:
	if _grid == null:
		return
	_row_cells.clear()
	_hover_id = ""
	if _hover_overlay != null:
		_hover_overlay.visible = false
	for child in _grid.get_children():
		child.queue_free()

	if _card_mode:
		_grid.columns = 1
	else:
		_grid.columns = _visible_cols().size()
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


## Column indices currently shown, in display order.
func _visible_cols() -> Array:
	var out: Array = []
	for i in COLS.size():
		if _col_visible(i):
			out.append(i)
	return out


func _fill_header() -> void:
	for i in _visible_cols():
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
		COLS_ENTRY:
			return _vp_width >= 620.0
		COLS_POSITION:
			return _vp_width >= 820.0
		COLS_HOLD:
			return _vp_width >= 720.0
		_:
			return true


func _on_viewport_resized() -> void:
	_vp_width = get_viewport().get_visible_rect().size.x
	var card := _vp_width < 620.0
	if card != _card_mode:
		_card_mode = card
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

	var dir_label := Label.new()
	dir_label.text = "L" if str(trade.get("direction", "long")) == "long" else "S"
	dir_label.add_theme_color_override("font_color", Utils.ACCENT if dir_label.text == "L" else Utils.ORANGE)

	var open_state := str(trade.get("state", "open")) == "open"

	# Current market value of the remaining position; closed trades have none.
	var pos_text := "-"
	if open_state:
		pos_text = Utils.money(float(bd.net_qty) * float(bd.mark))

	var closed_at := int(trade.get("closed_at", 0))
	var hold := 0.0
	if open_state:
		hold = float(now - int(trade.get("opened_at", 0)))
	else:
		hold = float(closed_at - int(trade.get("opened_at", 0)))

	var cells := {
		0: asset_cell,
		1: dir_label,
		2: _cell_label("%s @ %s" % [Utils.qty(float(bd.entry_qty)), Utils.money(float(bd.avg_entry))]),
		3: _cell_label(pos_text, Utils.TEXT if open_state else Utils.MUTED),
		4: _badge("OPEN" if open_state else "CLOSED",
				Utils.GREEN if open_state else Utils.MUTED),
		5: _cell_label(Utils.duration(hold)),
		6: _cell_label("%s (%s)" % [Utils.money(float(bd.pnl), true), Utils.pct(float(bd.pnl_pct))],
				Utils.change_color(float(bd.pnl))),
	}

	if _card_mode:
		_append_card(id, cells)
		return
	for i in _visible_cols():
		_add_cell(cells[i], i, id)


## Narrow layout: one self-contained card per trade whose fields wrap.
func _append_card(id: String, cells: Dictionary) -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Utils.panel_style())
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(cells[0])
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(spacer)
	head.add_child(cells[4])
	vbox.add_child(head)

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 12)
	flow.add_theme_constant_override("v_separation", 2)
	vbox.add_child(flow)
	for i in [1, 2, 3, 5, 6]:
		if cells.has(i):
			flow.add_child(_card_field(HEADERS[i], cells[i]))

	card.mouse_entered.connect(_on_row_hover.bind(id, true))
	card.mouse_exited.connect(_on_row_hover.bind(id, false))
	card.gui_input.connect(_on_cell_input.bind(id))
	_row_cells[id] = [card]
	_grid.add_child(card)


func _card_field(caption: String, value: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var cap := Label.new()
	cap.text = caption
	cap.add_theme_font_size_override("font_size", 9)
	cap.add_theme_color_override("font_color", Utils.MUTED)
	box.add_child(cap)
	box.add_child(value)
	return box


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
		content.mouse_entered.connect(_on_row_hover.bind(trade_id, true))
		content.mouse_exited.connect(_on_row_hover.bind(trade_id, false))
		if not _row_cells.has(trade_id):
			_row_cells[trade_id] = []
		_row_cells[trade_id].append(content)
	_grid.add_child(content)


func _hover_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.04)
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.16)
	return sb


func _on_row_hover(trade_id: String, entered: bool) -> void:
	if entered:
		_hover_id = trade_id
		_update_hover()
		_hover_overlay.visible = true
	elif _hover_id == trade_id:
		_hover_id = ""
		_hover_overlay.visible = false


## Stretches the overlay across the hovered row's full grid width.
func _update_hover() -> void:
	var cells: Array = _row_cells.get(_hover_id, [])
	var rect := Rect2()
	var first := true
	for c in cells:
		if not is_instance_valid(c):
			continue
		var r := Rect2(c.get_global_position() - get_global_position(), c.size)
		rect = r if first else rect.merge(r)
		first = false
	if first:
		_hover_overlay.visible = false
		return
	rect.position.x = _grid.get_global_position().x - get_global_position().x
	rect.size.x = _grid.size.x
	_hover_overlay.position = rect.position - Vector2(3, 1)
	_hover_overlay.size = rect.size + Vector2(6, 2)


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
