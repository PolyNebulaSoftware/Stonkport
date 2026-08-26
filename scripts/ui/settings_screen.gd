extends Control
## Settings screen: display currency, trade-log spacing, CSV export/import,
## and data reset.

const CSV_HEADER := "id,asset,asset_type,direction,state,opened_at,closed_at,quantity,entry_price,exit_price,fees,pnl,pnl_pct,notes"

## Loaded as a resource so constants are reachable without the autoload
## instance (keeps the parser testable headless).
const TradeManagerScript := preload("res://scripts/autoload/trade_manager.gd")

## Optional CSV import formats. Each entry provides FORMAT_NAME, can_parse()
## and parse(); add or remove entries (and their script files) freely — the
## default Stonkport importer below is unaffected.
const IMPORTERS := [
	preload("res://scripts/trades/importers/sj_importer.gd"),
]

var _last_format := "Stonkport"
var _codes: Array = []
var _currency: OptionButton
var _status: Label
var _clear_btn: Button
var _armed_clear := false
var _export_dialog: FileDialog
var _import_dialog: FileDialog
var _paste_dialog: AcceptDialog
var _paste_edit: TextEdit
var _pending_csv := ""

var _price_provider := func(asset: String) -> float: return MarketSimulator.get_price(asset)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	scroll.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(vbox)

	vbox.add_child(_build_currency_section())
	vbox.add_child(_build_appearance_section())
	vbox.add_child(_build_data_section())
	vbox.add_child(_build_about_section())


# --- Sections ----------------------------------------------------------------


func _build_currency_section() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Utils.panel_style())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	box.add_child(_section_title("Currency"))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)

	var caption := Label.new()
	caption.text = "Display currency"
	row.add_child(caption)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	_currency = OptionButton.new()
	_codes = Utils.CURRENCIES.keys()
	var current := str(TradeManager.settings.get("currency", "USD"))
	var selected := 0
	for i in _codes.size():
		var code: String = _codes[i]
		_currency.add_item("%s   %s" % [code, String(Utils.CURRENCIES[code]).strip_edges()])
		if code == current:
			selected = i
	_currency.selected = selected
	_currency.item_selected.connect(_on_currency_selected)
	row.add_child(_currency)
	return panel


func _build_appearance_section() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Utils.panel_style())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	box.add_child(_section_title("Appearance"))

	box.add_child(_slider_row("Trade log spacing",
			"Scales padding and gaps between trade log rows.",
			clampf(float(TradeManager.settings.get("row_spacing", 1.0)), 0.5, 2.5),
			0.5, 2.5,
			func(v: float) -> void:
				TradeManager.set_row_spacing(v)
				_set_status("Trade log spacing set to %.2f×." % v, true)))

	box.add_child(_slider_row("Mobile UI scale",
			"Interface magnifier applied when the web build runs on a phone.",
			clampf(float(TradeManager.settings.get("mobile_scale",
					TradeManager.MOBILE_SCALE_DEFAULT)), 1.0, 3.0),
			1.0, 3.0,
			func(v: float) -> void:
				TradeManager.set_mobile_scale(v)
				_set_status("Mobile UI scale set to %.2f×." % v, true)))
	return panel


## Caption + spacer + live value label + commit-on-release slider row.
func _slider_row(caption_text: String, tip: String, value: float,
		min_value: float, max_value: float, on_commit: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var caption := Label.new()
	caption.text = caption_text
	caption.tooltip_text = tip
	row.add_child(caption)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	var value_label := Label.new()
	value_label.text = "%.2f×" % value
	value_label.custom_minimum_size = Vector2(40, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_color_override("font_color", Utils.MUTED)
	row.add_child(value_label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = 0.05
	slider.value = value
	slider.custom_minimum_size = Vector2(150, 0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(v: float) -> void:
		value_label.text = "%.2f×" % v)
	slider.drag_ended.connect(func(changed: bool) -> void:
		if changed:
			on_commit.call(float(slider.value)))
	row.add_child(slider)
	return row


func _build_data_section() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Utils.panel_style())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	box.add_child(_section_title("Data"))

	var export_row := HBoxContainer.new()
	export_row.add_theme_constant_override("separation", 10)
	var export_caption := Label.new()
	export_caption.text = "Save every trade to a CSV file."
	export_caption.add_theme_color_override("font_color", Utils.MUTED)
	export_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	export_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	export_row.add_child(export_caption)
	var export_btn := Button.new()
	export_btn.text = "Export CSV"
	export_btn.focus_mode = Control.FOCUS_NONE
	export_btn.pressed.connect(_on_export)
	export_row.add_child(export_btn)
	box.add_child(export_row)

	var import_row := HBoxContainer.new()
	import_row.add_theme_constant_override("separation", 10)
	var import_caption := Label.new()
	import_caption.text = "Import trades from CSV. Rows merge by id."
	import_caption.add_theme_color_override("font_color", Utils.MUTED)
	import_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	import_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_row.add_child(import_caption)
	var import_btn := Button.new()
	import_btn.text = "Import CSV..."
	import_btn.focus_mode = Control.FOCUS_NONE
	import_btn.pressed.connect(_on_import_file)
	import_row.add_child(import_btn)
	var paste_btn := Button.new()
	paste_btn.text = "Paste CSV..."
	paste_btn.focus_mode = Control.FOCUS_NONE
	paste_btn.pressed.connect(_on_import_paste)
	import_row.add_child(paste_btn)
	box.add_child(import_row)

	var clear_row := HBoxContainer.new()
	clear_row.add_theme_constant_override("separation", 10)
	var clear_caption := Label.new()
	clear_caption.text = "Permanently deletes every trade."
	clear_caption.add_theme_color_override("font_color", Utils.MUTED)
	clear_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	clear_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_row.add_child(clear_caption)
	_clear_btn = Button.new()
	_clear_btn.text = "Clear All Data"
	_clear_btn.focus_mode = Control.FOCUS_NONE
	_clear_btn.pressed.connect(_on_clear_pressed)
	clear_row.add_child(_clear_btn)
	box.add_child(clear_row)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.visible = false
	box.add_child(_status)
	return panel


func _build_about_section() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Utils.panel_style())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	box.add_child(_section_title("About"))
	var info := Label.new()
	info.text = "Stonkport - client-side trade journal.\nData persists locally (user://trades.json, browser storage on web). Nothing leaves this device."
	info.add_theme_font_size_override("font_size", 11)
	info.add_theme_color_override("font_color", Utils.MUTED)
	box.add_child(info)
	return panel


func _section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	return label


# --- Actions -----------------------------------------------------------------


func _on_currency_selected(index: int) -> void:
	TradeManager.set_currency(str(_codes[index]))
	_set_status("Currency set to %s." % str(_codes[index]), true)


func _on_export() -> void:
	_pending_csv = _build_csv()
	if OS.has_feature("web"):
		_web_download("stonkport_trades.csv", _pending_csv)
		_set_status("Export started as a browser download.", true)
	else:
		_ensure_export_dialog().popup_centered()


func _on_import_file() -> void:
	if OS.has_feature("web"):
		_set_status("File picking is unavailable on web - use Paste CSV.", false)
		return
	_ensure_import_dialog().popup_centered()


func _on_import_paste() -> void:
	_ensure_paste_dialog().popup_centered()


func _on_clear_pressed() -> void:
	if not _armed_clear:
		_armed_clear = true
		_clear_btn.text = "Click again to confirm"
		_clear_btn.add_theme_color_override("font_color", Utils.RED)
		return
	for t in TradeManager.trades.duplicate():
		TradeManager.delete_trade(str(t.get("id", "")))
	_reset_clear_button()
	_set_status("All trades deleted.", true)


func _reset_clear_button() -> void:
	_armed_clear = false
	_clear_btn.text = "Clear All Data"
	_clear_btn.remove_theme_color_override("font_color")


func _set_status(text: String, ok: bool) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", Utils.GREEN if ok else Utils.RED)
	_status.visible = true


# --- CSV ---------------------------------------------------------------------


func _build_csv() -> String:
	var lines := [CSV_HEADER]
	for t in TradeManager.trades:
		var bd := TradeMetrics.breakdown(t, _price_provider)
		var closed_at := int(t.get("closed_at", 0))
		lines.append(",".join([
			Utils.csv_field(str(t.get("id", ""))),
			Utils.csv_field(str(t.get("asset", ""))),
			str(t.get("asset_type", "stock")),
			str(t.get("direction", "long")),
			str(t.get("state", "open")),
			Utils.date_str(int(t.get("opened_at", 0))),
			Utils.date_str(closed_at) if closed_at > 0 else "",
			Utils.qty(float(bd.entry_qty)),
			"%.4f" % float(bd.avg_entry),
			"%.4f" % float(bd.avg_exit),
			"%.2f" % float(bd.fees),
			"%.2f" % float(bd.pnl),
			"%.2f" % float(bd.pnl_pct),
			Utils.csv_field(str(t.get("notes", ""))),
		]))
	return "\n".join(lines) + "\n"


func _parse_csv(text: String) -> Array:
	var out: Array = []
	var lines := text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	var header_idx := -1
	for i in lines.size():
		var lower := str(lines[i]).to_lower()
		if lower.contains(",") and (lower.contains("asset") or lower.contains("symbol")):
			header_idx = i
			break
	if header_idx == -1:
		return out
	for importer in IMPORTERS:
		if importer.can_parse(str(lines[header_idx])):
			_last_format = importer.FORMAT_NAME
			return importer.parse(lines, header_idx, TradeManagerScript.ASSET_TYPES)
	_last_format = "Stonkport"
	var headers := Utils.csv_split(str(lines[header_idx]))
	for i in range(header_idx + 1, lines.size()):
		if str(lines[i]).strip_edges().is_empty():
			continue
		var cells := Utils.csv_split(str(lines[i]))
		var row := {}
		for h in headers.size():
			if h < cells.size():
				row[str(headers[h]).strip_edges().to_lower()] = str(cells[h])
		var trade := _trade_from_row(row)
		if not trade.is_empty():
			out.append(trade)
	return out


func _trade_from_row(row: Dictionary) -> Dictionary:
	var asset := str(row.get("asset", "")).strip_edges().to_upper()
	var qty := float(row.get("quantity", "0")) if row.has("quantity") else 0.0
	var entry := float(row.get("entry_price", "0")) if row.has("entry_price") else 0.0
	if asset.is_empty() or qty <= 0.0 or entry <= 0.0:
		return {}
	var opened := Utils.parse_date(str(row.get("opened_at", "")))
	if opened <= 0:
		return {}
	var fee := maxf(float(row.get("fees", "0")) if row.has("fees") else 0.0, 0.0)
	var logs: Array = [{"ts": opened, "action": "open", "qty": qty, "price": entry, "fee": fee * 0.5}]
	var closed := Utils.parse_date(str(row.get("closed_at", "")))
	var exit_price := float(row.get("exit_price", "0")) if row.has("exit_price") else 0.0
	if closed > 0 and exit_price > 0.0:
		logs.append({"ts": closed, "action": "close", "qty": qty, "price": exit_price, "fee": fee * 0.5})
	var direction := str(row.get("direction", "long")).to_lower()
	var asset_type := str(row.get("asset_type", "stock")).to_lower()
	return {
		"id": str(row.get("id", "")),
		"asset": asset,
		"asset_type": asset_type if TradeManagerScript.ASSET_TYPES.has(asset_type) else "stock",
		"direction": direction if direction in ["long", "short"] else "long",
		"state": "open",
		"opened_at": 0,
		"closed_at": 0,
		"notes": str(row.get("notes", "")),
		"logs": logs,
	}


func _apply_import(list: Array) -> void:
	var result := TradeManager.import_trades(list)
	_set_status("Imported %d trade(s) from %s CSV, skipped %d." % [
			int(result.imported), _last_format, int(result.skipped)],
			int(result.imported) > 0)


# --- Dialogs -----------------------------------------------------------------


func _ensure_export_dialog() -> FileDialog:
	if _export_dialog == null:
		_export_dialog = FileDialog.new()
		_export_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_export_dialog.filters = PackedStringArray(["*.csv"])
		_export_dialog.current_file = "stonkport_trades.csv"
		_export_dialog.file_selected.connect(_on_export_path)
		add_child(_export_dialog)
	return _export_dialog


func _ensure_import_dialog() -> FileDialog:
	if _import_dialog == null:
		_import_dialog = FileDialog.new()
		_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_import_dialog.filters = PackedStringArray(["*.csv"])
		_import_dialog.file_selected.connect(_on_import_path)
		add_child(_import_dialog)
	return _import_dialog


func _ensure_paste_dialog() -> AcceptDialog:
	if _paste_dialog == null:
		_paste_dialog = AcceptDialog.new()
		_paste_dialog.title = "Paste CSV"
		_paste_dialog.min_size = Vector2i(460, 340)
		_paste_dialog.get_ok_button().hide()
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 8)
		_paste_dialog.add_child(box)
		_paste_edit = TextEdit.new()
		_paste_edit.placeholder_text = CSV_HEADER
		_paste_edit.custom_minimum_size = Vector2(400, 240)
		box.add_child(_paste_edit)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		box.add_child(row)
		var import_btn := Button.new()
		import_btn.text = "Import"
		import_btn.pressed.connect(func():
			_apply_import(_parse_csv(_paste_edit.text))
			_paste_dialog.hide())
		row.add_child(import_btn)
		add_child(_paste_dialog)
	return _paste_dialog


func _on_export_path(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_set_status("Could not write to %s." % path, false)
		return
	f.store_string(_pending_csv)
	f.flush()
	f.close()
	_set_status("Exported %d trade(s)." % TradeManager.trades.size(), true)


func _on_import_path(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_set_status("Could not read %s." % path, false)
		return
	_apply_import(_parse_csv(f.get_as_text()))


## Triggers a browser download when running as WASM. Uses the engine-managed
## blob download: revoking the object URL right after click() (as a manual
## DOM dance does) races Chrome's fetch of the blob and aborts the save.
func _web_download(filename: String, text: String) -> void:
	JavaScriptBridge.download_buffer(text.to_utf8_buffer(), filename, "text/csv")
