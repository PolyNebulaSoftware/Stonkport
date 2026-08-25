extends AcceptDialog
## Create/edit trade dialog. Both modes share one metadata row (Asset / Type /
## Direction), a spreadsheet-style log grid (Action / Time / Quantity / Price /
## Fee) with a trailing "+" row, and notes pinned to the bottom.

const TYPE_NAMES := ["stock", "crypto", "custom", "option"]
const DIR_NAMES := ["long", "short"]
const LOG_ACTIONS := ["open", "add", "reduce", "close"]
const ROW_KEYS := ["action", "time", "qty", "price", "fee", "x"]

var _mode := "create"
var _trade_id := ""
var _armed_delete := false

var _summary_box: HBoxContainer
var _meta := {}            # shared Asset / Type / Direction controls
var _log_grid: GridContainer
var _log_rows: Array = []  # per-row control dictionaries
var _plus_cells: Array = []
var _notes: LineEdit
var _error: Label
var _create_buttons: Control
var _edit_buttons: Control
var _delete_btn: Button

var _price_provider := func(asset: String) -> float: return MarketSimulator.get_price(asset)


func _ready() -> void:
	title = "New Trade"
	min_size = Vector2i(580, 0)
	get_ok_button().hide()

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	outer.custom_minimum_size = Vector2(540, 0)
	add_child(outer)

	_summary_box = HBoxContainer.new()
	_summary_box.add_theme_constant_override("separation", 6)
	outer.add_child(_summary_box)

	outer.add_child(_build_meta_row())
	_build_log_section(outer)

	_notes = LineEdit.new()
	_notes.placeholder_text = "Optional notes"
	_form_row(outer, "Notes", _notes, 380)

	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_color_override("font_color", Utils.RED)
	_error.visible = false
	outer.add_child(_error)

	_create_buttons = _button_row([
		{"text": "Cancel", "action": hide},
		{"text": "Create Trade", "action": _submit_create, "primary": true},
	])
	outer.add_child(_create_buttons)

	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.focus_mode = Control.FOCUS_NONE
	_delete_btn.pressed.connect(_on_delete_pressed)

	_edit_buttons = _button_row([
		{"text": "", "action": func(): pass, "custom": _delete_btn},
		{"text": "Cancel", "action": hide},
		{"text": "Save Changes", "action": _submit_save, "primary": true},
	])
	outer.add_child(_edit_buttons)

	TradeManager.trades_changed.connect(_on_trades_changed)


# --- Metadata row ------------------------------------------------------------


func _build_meta_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	_meta.asset = LineEdit.new()
	_meta.asset.placeholder_text = "GLD"
	_meta.asset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_caption("Asset"))
	row.add_child(_meta.asset)

	_meta.type = OptionButton.new()
	for item in ["Stock", "Crypto", "Custom", "Option"]:
		_meta.type.add_item(item)
	_meta.type.custom_minimum_size = Vector2(100, 0)
	row.add_child(_caption("Type"))
	row.add_child(_meta.type)

	_meta.dir = OptionButton.new()
	_meta.dir.add_item("Long")
	_meta.dir.add_item("Short")
	_meta.dir.custom_minimum_size = Vector2(86, 0)
	row.add_child(_caption("Direction"))
	row.add_child(_meta.dir)
	return row


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Utils.MUTED)
	return label


# --- Log grid ----------------------------------------------------------------


func _build_log_section(parent: Control) -> void:
	var logs_caption := Label.new()
	logs_caption.text = "Logs"
	logs_caption.add_theme_font_size_override("font_size", 13)
	parent.add_child(logs_caption)

	var hint := Label.new()
	hint.text = "One entry per row, sorted by time. Close entries realize P/L."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Utils.MUTED)
	parent.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)

	_log_grid = GridContainer.new()
	_log_grid.columns = 6
	_log_grid.add_theme_constant_override("h_separation", 6)
	_log_grid.add_theme_constant_override("v_separation", 4)
	_log_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_log_grid)

	for col in ["Action", "Time", "Quantity", "Price", "Fee", ""]:
		var head := Label.new()
		head.text = col
		head.add_theme_font_size_override("font_size", 11)
		head.add_theme_color_override("font_color", Utils.MUTED)
		_log_grid.add_child(head)

	var add_btn := Button.new()
	add_btn.text = "+"
	add_btn.tooltip_text = "Add log entry"
	add_btn.focus_mode = Control.FOCUS_NONE
	add_btn.custom_minimum_size = Vector2(26, 26)
	add_btn.pressed.connect(_on_add_row)
	_plus_cells = [add_btn]
	for i in 5:
		var spacer := Control.new()
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_plus_cells.append(spacer)
	_restack_plus_row()


func _add_log_row(data := {}) -> Dictionary:
	var row := {}

	var action := OptionButton.new()
	for i in LOG_ACTIONS.size():
		action.add_item(LOG_ACTIONS[i].capitalize())
	action.selected = clampi(LOG_ACTIONS.find(str(data.get("action", "open"))), 0, LOG_ACTIONS.size() - 1)
	action.custom_minimum_size = Vector2(92, 0)
	action.item_selected.connect(_on_action_selected.bind(row))
	row.action = action

	row.time = LineEdit.new()
	row.time.placeholder_text = "YYYY-MM-DD"
	row.time.custom_minimum_size = Vector2(112, 0)
	var ts := int(data.get("ts", 0))
	if ts > 0:
		row.time.text = Utils.date_str(ts)

	row.qty = _num_edit(_num_text(float(data.get("qty", 0.0))), "0", 84)
	row.price = _num_edit(_num_text(float(data.get("price", 0.0))), "0.00", 104)
	row.fee = _num_edit(_num_text(float(data.get("fee", 0.0))), "0", 76)
	for key in ["time", "qty", "price", "fee"]:
		row[key].text_changed.connect(_filter_numeric.bind(row[key]))

	var remove_btn := Button.new()
	remove_btn.text = "x"
	remove_btn.tooltip_text = "Remove this entry"
	remove_btn.focus_mode = Control.FOCUS_NONE
	remove_btn.custom_minimum_size = Vector2(26, 26)
	remove_btn.add_theme_font_size_override("font_size", 11)
	remove_btn.pressed.connect(_on_remove_row.bind(row))
	row.x = remove_btn

	_log_rows.append(row)
	for key in ROW_KEYS:
		_log_grid.add_child(row[key])
	_restack_plus_row()
	return row


## Keeps the "+" row as the last row of the grid.
func _restack_plus_row() -> void:
	for cell in _plus_cells:
		if cell.get_parent() == null:
			_log_grid.add_child(cell)
	for cell in _plus_cells:
		_log_grid.move_child(cell, _log_grid.get_child_count() - 1)


func _on_add_row() -> void:
	_add_log_row()


func _on_remove_row(row: Dictionary) -> void:
	_log_rows.erase(row)
	_drop_row(row)


func _drop_row(row: Dictionary) -> void:
	for key in ROW_KEYS:
		var cell: Control = row.get(key)
		if cell != null:
			_log_grid.remove_child(cell)
			cell.queue_free()


func _reset_log_rows(rows_data: Array) -> void:
	for row in _log_rows:
		_drop_row(row)
	_log_rows.clear()
	for data in rows_data:
		_add_log_row(data)


## Prefills quantity/price when an exit action is picked.
func _on_action_selected(index: int, row: Dictionary) -> void:
	var action: String = LOG_ACTIONS[index]
	if not action in ["reduce", "close"] or _trade_id.is_empty():
		return
	var t := TradeManager.get_trade(_trade_id)
	if t.is_empty():
		return
	if action == "close":
		row.qty.text = _num_text(TradeManager.remaining_quantity(t))
	var mark := TradeManager.get_mark_price(t)
	if mark > 0.0 and row.price.text.strip_edges().is_empty():
		row.price.text = _num_text(mark)


func _filter_numeric(new_text: String, edit: LineEdit) -> void:
	var filtered := ""
	for ch in new_text:
		if (ch >= "0" and ch <= "9") or ch == "." or ch == "-":
			filtered += ch
	if filtered != new_text:
		edit.text = filtered
		edit.caret_column = filtered.length()


func _num_edit(text: String, placeholder: String, width: float) -> LineEdit:
	var edit := LineEdit.new()
	edit.text = text
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(width, 0)
	return edit


func _num_text(value: float) -> String:
	var text := "%.8f" % value
	while text.ends_with("0"):
		text = text.substr(0, text.length() - 1)
	return text.rstrip(".")


func _parse_num(text: String) -> float:
	return text.strip_edges().replace(",", "").to_float()


## Reads the grid into validated log dicts. Returns an Array or a String error.
func _gather_logs() -> Variant:
	var logs: Array = []
	for i in _log_rows.size():
		var row: Dictionary = _log_rows[i]
		var n := i + 1
		var ts := Utils.parse_date(row.time.text)
		if ts <= 0:
			return "Row %d: time must be a valid YYYY-MM-DD value." % n
		var qty := _parse_num(row.qty.text)
		if qty <= 0.0:
			return "Row %d: quantity must be positive." % n
		var price := _parse_num(row.price.text)
		if price <= 0.0:
			return "Row %d: price must be positive." % n
		var fee := _parse_num(row.fee.text)
		if fee < 0.0:
			return "Row %d: fee cannot be negative." % n
		logs.append({
			"ts": ts,
			"action": LOG_ACTIONS[int(row.action.selected)],
			"qty": qty,
			"price": price,
			"fee": fee,
		})
	return logs


# --- Submit ------------------------------------------------------------------


func _submit_create() -> void:
	var logs: Variant = _gather_logs()
	if logs is String:
		_show_error(logs)
		return
	var err := TradeManager.create_trade(_meta.asset.text,
			TYPE_NAMES[_meta.type.selected], DIR_NAMES[_meta.dir.selected],
			_notes.text, logs)
	if err != "":
		_show_error(err)
		return
	hide()


func _submit_save() -> void:
	if _meta.asset.text.strip_edges().to_upper().is_empty():
		_show_error("Asset identifier is required.")
		return
	var logs: Variant = _gather_logs()
	if logs is String:
		_show_error(logs)
		return
	var err := TradeManager.set_logs(_trade_id, logs)
	if err != "":
		_show_error(err)
		return
	err = TradeManager.update_meta(_trade_id, _meta.asset.text,
			TYPE_NAMES[_meta.type.selected], DIR_NAMES[_meta.dir.selected], _notes.text)
	if err != "":
		_show_error(err)
		return
	hide()


func _on_delete_pressed() -> void:
	if not _armed_delete:
		_armed_delete = true
		_delete_btn.text = "Confirm delete?"
		_delete_btn.add_theme_color_override("font_color", Utils.RED)
		return
	var err := TradeManager.delete_trade(_trade_id)
	if err != "":
		_show_error(err)
		return
	hide()


# --- Summary rendering -------------------------------------------------------


func _reload_summary(trade: Dictionary) -> void:
	for child in _summary_box.get_children():
		child.queue_free()
	var bd := TradeMetrics.breakdown(trade, _price_provider)
	var open_state := str(trade.get("state", "open")) == "open"

	_summary_box.add_child(_badge("OPEN" if open_state else "CLOSED",
			Utils.GREEN if open_state else Utils.MUTED))
	_summary_box.add_child(_badge("L" if str(trade.get("direction")) == "long" else "S",
			Utils.ACCENT if str(trade.get("direction")) == "long" else Utils.ORANGE))

	var pnl := Label.new()
	pnl.text = "%s (%s)" % [Utils.money(float(bd.pnl), true), Utils.pct(float(bd.pnl_pct))]
	pnl.add_theme_font_size_override("font_size", 14)
	pnl.add_theme_color_override("font_color", Utils.change_color(float(bd.pnl)))
	_summary_box.add_child(pnl)

	var mark := Label.new()
	mark.text = "Mark %.2f" % float(bd.mark) if float(bd.mark) > 0.0 else "Mark -"
	mark.add_theme_font_size_override("font_size", 12)
	mark.add_theme_color_override("font_color", Utils.MUTED)
	_summary_box.add_child(mark)


# --- Open / reset ------------------------------------------------------------


func open_create() -> void:
	_mode = "create"
	_trade_id = ""
	title = "New Trade"
	_meta.asset.text = ""
	_meta.type.selected = 0
	_meta.dir.selected = 0
	_notes.text = ""
	_reset_log_rows([{
		"action": "open",
		"ts": int(Time.get_unix_time_from_system()),
		"qty": 1.0,
	}])
	_apply_mode()
	popup_centered()


func open_edit(id: String) -> void:
	var t := TradeManager.get_trade(id)
	if t.is_empty():
		return
	_mode = "edit"
	_trade_id = id
	title = "Edit - %s" % str(t.get("asset", "?"))
	_meta.asset.text = str(t.get("asset", ""))
	_meta.type.selected = TYPE_NAMES.find(str(t.get("asset_type", "stock")))
	_meta.dir.selected = DIR_NAMES.find(str(t.get("direction", "long")))
	_notes.text = str(t.get("notes", ""))
	_armed_delete = false
	_delete_btn.text = "Delete"
	_delete_btn.remove_theme_color_override("font_color")
	_apply_mode()
	_reload_logs()
	popup_centered()


func _reload_logs() -> void:
	var t := TradeManager.get_trade(_trade_id)
	if t.is_empty():
		return
	_reset_log_rows(t.get("logs", []))
	_reload_summary(t)


func _apply_mode() -> void:
	_summary_box.visible = _mode == "edit"
	_create_buttons.visible = _mode == "create"
	_edit_buttons.visible = _mode == "edit"
	_clear_error()


func _on_trades_changed() -> void:
	if visible and _mode == "edit" and not _trade_id.is_empty():
		_reload_logs()


# --- Shared helpers ----------------------------------------------------------


func _form_row(parent: Control, caption: String, control: Control, width := 0.0) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label := Label.new()
	label.text = caption
	label.custom_minimum_size = Vector2(110, 0)
	label.add_theme_color_override("font_color", Utils.MUTED)
	row.add_child(label)
	if width > 0.0:
		control.custom_minimum_size = Vector2(width, control.custom_minimum_size.y)
	row.add_child(control)
	parent.add_child(row)


func _button_row(specs: Array) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	for spec in specs:
		if spec.has("custom"):
			row.add_child(spec.custom)
			continue
		var btn := Button.new()
		btn.text = str(spec.text)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(spec.action)
		if spec.has("primary"):
			var spacer := _spacer()
			row.add_child(spacer)
			row.move_child(spacer, 0)
		row.add_child(btn)
	return row


func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _badge(text: String, fg: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", fg)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_stylebox_override("normal",
			Utils.flat_style(Color(fg.r, fg.g, fg.b, 0.16), Color.TRANSPARENT, 4, 6, 1))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _show_error(message: String) -> void:
	_error.text = message
	_error.visible = true


func _clear_error() -> void:
	_error.visible = false
