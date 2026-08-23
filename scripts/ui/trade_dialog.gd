extends AcceptDialog
## Create/edit trade dialog. Create mode collects the opening log; edit mode
## manages metadata plus the full log list (add/reduce/close entries).

const TYPE_NAMES := ["stock", "crypto", "custom"]
const DIR_NAMES := ["long", "short"]
const LOG_ACTIONS := ["add", "reduce", "close"]

var _mode := "create"
var _trade_id := ""
var _armed_delete := false

var _create_box: VBoxContainer
var _edit_box: VBoxContainer
var _f := {}       # create-mode fields
var _m := {}       # edit-mode meta fields
var _log_form := {}
var _summary_box: HBoxContainer
var _logs_box: VBoxContainer
var _error: Label
var _delete_btn: Button

var _price_provider := func(asset: String) -> float: return MarketSimulator.get_price(asset)


func _ready() -> void:
	title = "New Trade"
	min_size = Vector2i(620, 0)
	get_ok_button().hide()

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	outer.custom_minimum_size = Vector2(580, 0)
	add_child(outer)

	outer.add_child(_build_create_box())
	outer.add_child(_build_edit_box())

	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_color_override("font_color", Utils.RED)
	_error.visible = false
	outer.add_child(_error)

	TradeManager.trades_changed.connect(_on_trades_changed)


# --- Create mode -------------------------------------------------------------


func _build_create_box() -> Control:
	_create_box = VBoxContainer.new()
	_create_box.add_theme_constant_override("separation", 6)

	_f.asset = LineEdit.new()
	_f.asset.placeholder_text = "AAPL"
	_form_row(_create_box, "Asset", _f.asset, 180)

	_f.type = OptionButton.new()
	for item in ["Stock", "Crypto", "Custom"]:
		_f.type.add_item(item)
	_form_row(_create_box, "Type", _f.type, 180)

	_f.dir = OptionButton.new()
	_f.dir.add_item("Long")
	_f.dir.add_item("Short")
	_form_row(_create_box, "Direction", _f.dir, 180)

	_f.qty = _spin(0.0, 1000000000.0, 0.01)
	_form_row(_create_box, "Quantity", _f.qty, 140)

	_f.price = _spin(0.0, 10000000.0, 0.01)
	_form_row(_create_box, "Entry price", _f.price, 140)

	_f.fee = _spin(0.0, 100000.0, 0.01)
	_form_row(_create_box, "Fee", _f.fee, 140)

	_f.opened = LineEdit.new()
	_f.opened.placeholder_text = "YYYY-MM-DD"
	_form_row(_create_box, "Opened", _f.opened, 140)

	_f.notes = LineEdit.new()
	_f.notes.placeholder_text = "Optional notes"
	_form_row(_create_box, "Notes", _f.notes, 380)

	_create_box.add_child(_button_row([
		{"text": "Cancel", "action": hide},
		{"text": "Create Trade", "action": _submit_create, "primary": true},
	]))
	return _create_box


func _submit_create() -> void:
	var ts := Utils.parse_date(_f.opened.text)
	if ts <= 0:
		_show_error("Opening date must be a valid YYYY-MM-DD value.")
		return
	var err := TradeManager.create_trade(
			_f.asset.text, TYPE_NAMES[_f.type.selected], DIR_NAMES[_f.dir.selected],
			float(_f.qty.value), float(_f.price.value), float(_f.fee.value), ts,
			_f.notes.text)
	if err != "":
		_show_error(err)
		return
	hide()


# --- Edit mode ---------------------------------------------------------------


func _build_edit_box() -> Control:
	_edit_box = VBoxContainer.new()
	_edit_box.add_theme_constant_override("separation", 8)

	_summary_box = HBoxContainer.new()
	_summary_box.add_theme_constant_override("separation", 6)
	_edit_box.add_child(_summary_box)

	_m.asset = LineEdit.new()
	_m.asset.placeholder_text = "AAPL"
	_form_row(_edit_box, "Asset", _m.asset, 180)

	_m.type = OptionButton.new()
	for item in ["Stock", "Crypto", "Custom"]:
		_m.type.add_item(item)
	_form_row(_edit_box, "Type", _m.type, 180)

	_m.dir = OptionButton.new()
	_m.dir.add_item("Long")
	_m.dir.add_item("Short")
	_form_row(_edit_box, "Direction", _m.dir, 180)

	_m.notes = LineEdit.new()
	_m.notes.placeholder_text = "Optional notes"
	_form_row(_edit_box, "Notes", _m.notes, 380)

	var logs_caption := Label.new()
	logs_caption.text = "Logs"
	logs_caption.add_theme_font_size_override("font_size", 13)
	_edit_box.add_child(logs_caption)

	var hint := Label.new()
	hint.text = "Chronological entries. Close logs realize P/L."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Utils.MUTED)
	_edit_box.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 130)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_edit_box.add_child(scroll)

	_logs_box = VBoxContainer.new()
	_logs_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_logs_box.add_theme_constant_override("separation", 2)
	scroll.add_child(_logs_box)

	_build_log_form()

	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.focus_mode = Control.FOCUS_NONE
	_delete_btn.pressed.connect(_on_delete_pressed)

	_edit_box.add_child(_button_row([
		{"text": "", "action": func(): pass, "custom": _delete_btn},
		{"text": "Cancel", "action": hide},
		{"text": "Save Changes", "action": _submit_save, "primary": true},
	]))
	return _edit_box


func _build_log_form() -> void:
	var form := HBoxContainer.new()
	form.add_theme_constant_override("separation", 6)

	_log_form.action = OptionButton.new()
	for item in ["Add", "Reduce", "Close"]:
		_log_form.action.add_item(item)
	_log_form.action.custom_minimum_size = Vector2(92, 0)
	_log_form.action.item_selected.connect(func(_i: int): _prefill_exit())
	form.add_child(_log_form.action)

	_log_form.qty = _spin(0.0, 1000000000.0, 0.01)
	_log_form.qty.custom_minimum_size = Vector2(84, 0)
	form.add_child(_log_form.qty)

	_log_form.price = _spin(0.0, 10000000.0, 0.01)
	_log_form.price.custom_minimum_size = Vector2(104, 0)
	form.add_child(_log_form.price)

	_log_form.fee = _spin(0.0, 100000.0, 0.01)
	_log_form.fee.custom_minimum_size = Vector2(84, 0)
	form.add_child(_log_form.fee)

	_log_form.date = LineEdit.new()
	_log_form.date.placeholder_text = "YYYY-MM-DD"
	_log_form.date.custom_minimum_size = Vector2(112, 0)
	form.add_child(_log_form.date)

	var add_btn := Button.new()
	add_btn.text = "Add"
	add_btn.focus_mode = Control.FOCUS_NONE
	add_btn.pressed.connect(_on_add_log)
	form.add_child(add_btn)

	_edit_box.add_child(form)


func _log_action() -> String:
	return LOG_ACTIONS[_log_form.action.selected]


## Prefills quantity/price when an exit action is picked.
func _prefill_exit() -> void:
	var action := _log_action()
	if action == "add":
		return
	var t := TradeManager.get_trade(_trade_id)
	if t.is_empty():
		return
	if action == "close":
		_log_form.qty.value = TradeManager.remaining_quantity(t)
	var mark := TradeManager.get_mark_price(t)
	if mark > 0.0:
		_log_form.price.value = mark


func _on_add_log() -> void:
	var ts := Utils.parse_date(_log_form.date.text)
	if ts <= 0:
		ts = int(Time.get_unix_time_from_system())
	var err := TradeManager.append_log(_trade_id, _log_action(),
			float(_log_form.qty.value), float(_log_form.price.value),
			float(_log_form.fee.value), ts)
	if err != "":
		_show_error(err)
	else:
		_clear_error()


func _on_remove_log(index: int) -> void:
	var err := TradeManager.remove_log(_trade_id, index)
	if err != "":
		_show_error(err)


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


func _submit_save() -> void:
	var err := TradeManager.update_meta(_trade_id, _m.asset.text,
			TYPE_NAMES[_m.type.selected], DIR_NAMES[_m.dir.selected], _m.notes.text)
	if err != "":
		_show_error(err)
		return
	hide()


# --- Log list rendering ------------------------------------------------------


func _reload_logs() -> void:
	for child in _logs_box.get_children():
		child.queue_free()
	var t := TradeManager.get_trade(_trade_id)
	if t.is_empty():
		return
	var logs: Array = t.get("logs", [])
	for i in logs.size():
		_logs_box.add_child(_make_log_row(i, logs[i]))
	_reload_summary(t)


func _make_log_row(index: int, log: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var colors := {
		"open": Utils.ACCENT,
		"add": Utils.GREEN,
		"reduce": Utils.ORANGE,
		"close": Utils.RED,
	}
	var action := str(log.get("action", ""))
	row.add_child(_badge(action.to_upper(), colors.get(action, Utils.MUTED)))

	var date_label := Label.new()
	date_label.text = Utils.datetime_str(int(log.get("ts", 0)))
	date_label.add_theme_font_size_override("font_size", 11)
	date_label.add_theme_color_override("font_color", Utils.MUTED)
	row.add_child(date_label)

	var main := Label.new()
	main.text = "%s @ %.2f" % [Utils.qty(float(log.get("qty", 0.0))), float(log.get("price", 0.0))]
	main.add_theme_font_size_override("font_size", 12)
	row.add_child(main)

	var fee := Label.new()
	fee.text = "fee %s" % Utils.money(float(log.get("fee", 0.0)))
	fee.add_theme_font_size_override("font_size", 11)
	fee.add_theme_color_override("font_color", Utils.MUTED)
	row.add_child(fee)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	var remove_btn := Button.new()
	remove_btn.text = "x"
	remove_btn.tooltip_text = "Remove this log entry"
	remove_btn.focus_mode = Control.FOCUS_NONE
	remove_btn.custom_minimum_size = Vector2(26, 26)
	remove_btn.add_theme_font_size_override("font_size", 11)
	remove_btn.pressed.connect(_on_remove_log.bind(index))
	row.add_child(remove_btn)
	return row


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
	_f.asset.text = ""
	_f.type.selected = 0
	_f.dir.selected = 0
	_f.qty.value = 1.0
	_f.price.value = 0.0
	_f.fee.value = 0.0
	_f.opened.text = Utils.date_str(int(Time.get_unix_time_from_system()))
	_f.notes.text = ""
	_apply_mode()
	popup_centered()


func open_edit(id: String) -> void:
	var t := TradeManager.get_trade(id)
	if t.is_empty():
		return
	_mode = "edit"
	_trade_id = id
	title = "Edit - %s" % str(t.get("asset", "?"))
	_m.asset.text = str(t.get("asset", ""))
	_m.type.selected = TYPE_NAMES.find(str(t.get("asset_type", "stock")))
	_m.dir.selected = DIR_NAMES.find(str(t.get("direction", "long")))
	_m.notes.text = str(t.get("notes", ""))
	_armed_delete = false
	_delete_btn.text = "Delete"
	_delete_btn.remove_theme_color_override("font_color")
	_apply_mode()
	_reload_logs()
	popup_centered()


func _apply_mode() -> void:
	_create_box.visible = _mode == "create"
	_edit_box.visible = _mode == "edit"
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


func _spin(min_value: float, max_value: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = 0.0
	return spin


func _show_error(message: String) -> void:
	_error.text = message
	_error.visible = true


func _clear_error() -> void:
	_error.visible = false
