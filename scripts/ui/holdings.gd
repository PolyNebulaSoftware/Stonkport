extends Control
## Holdings screen: Tree table of positions with Add / Edit / Remove actions.

const PositionDialogScene := preload("res://scenes/dialogs/position_dialog.tscn")

var _tree: Tree
var _edit_btn: Button
var _remove_btn: Button
var _footer: Label
var _dialog: AcceptDialog
var _confirm: ConfirmationDialog
var _pending_remove := ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 4)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	vbox.add_child(_build_toolbar())

	_tree = Tree.new()
	_tree.columns = 8
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.allow_reselect = true
	_tree.column_titles_visible = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_on_selection_changed)
	vbox.add_child(_tree)

	var headers := PackedStringArray(["Ticker", "Name", "Shares", "Avg Cost", "Price", "Market Value", "P&L", "P&L %"])
	for i in headers.size():
		_tree.set_column_title(i, headers[i])
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, 66)
	_tree.set_column_expand(1, true)
	for i in [2, 3, 4]:
		_tree.set_column_expand(i, false)
		_tree.set_column_custom_minimum_width(i, 84)
	_tree.set_column_expand(5, false)
	_tree.set_column_custom_minimum_width(5, 116)
	_tree.set_column_expand(6, false)
	_tree.set_column_custom_minimum_width(6, 104)
	_tree.set_column_expand(7, false)
	_tree.set_column_custom_minimum_width(7, 82)

	_dialog = PositionDialogScene.instantiate()
	add_child(_dialog)

	_confirm = ConfirmationDialog.new()
	_confirm.dialog_text = "Remove this position? The shares will be sold at the current market price."
	_confirm.ok_button_text = "Remove"
	_confirm.confirmed.connect(_do_remove)
	add_child(_confirm)

	PortfolioManager.portfolio_changed.connect(_rebuild)
	MarketSimulator.market_ticked.connect(_refresh_prices)
	_rebuild()


func _build_toolbar() -> Control:
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)

	var add_btn := Button.new()
	add_btn.text = "Add Position"
	add_btn.pressed.connect(func() -> void: _dialog.setup_trade())
	toolbar.add_child(add_btn)

	_edit_btn = Button.new()
	_edit_btn.text = "Edit"
	_edit_btn.disabled = true
	_edit_btn.pressed.connect(_on_edit)
	toolbar.add_child(_edit_btn)

	_remove_btn = Button.new()
	_remove_btn.text = "Remove"
	_remove_btn.disabled = true
	_remove_btn.pressed.connect(_on_remove)
	toolbar.add_child(_remove_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	_footer = Label.new()
	_footer.add_theme_color_override("font_color", Utils.MUTED)
	toolbar.add_child(_footer)
	return toolbar


func _selected_ticker() -> String:
	var item := _tree.get_selected()
	if item == null:
		return ""
	return str(item.get_metadata(0))


func _rebuild() -> void:
	_tree.clear()
	for ticker in PortfolioManager.holdings.keys():
		_make_row(str(ticker))
	_edit_btn.disabled = true
	_remove_btn.disabled = true
	_refresh_prices()
	_update_footer()


func _make_row(ticker: String) -> void:
	var item := _tree.create_item()
	item.set_metadata(0, ticker)
	item.set_text_alignment(2, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_text_alignment(3, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_text_alignment(4, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_text_alignment(5, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_text_alignment(6, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_text_alignment(7, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_text(0, ticker)
	item.set_text(1, str(MarketSimulator.get_stock_info(ticker).get("name", "")))


## Lightweight per-tick update: only price-derived cells change.
func _refresh_prices() -> void:
	var root := _tree.get_root()
	if root == null:
		_update_footer()
		return
	var item := root.get_first_child()
	while item != null:
		var ticker := str(item.get_metadata(0))
		if PortfolioManager.holdings.has(ticker):
			var h: Dictionary = PortfolioManager.holdings[ticker]
			var shares := float(h["shares"])
			var price := MarketSimulator.get_price(ticker)
			var value := shares * price
			var pnl := PortfolioManager.get_position_pnl(ticker)
			item.set_text(2, "%d" % int(shares))
			item.set_text(3, Utils.money(float(h["avg_cost"])))
			item.set_text(4, Utils.money(price))
			item.set_text(5, Utils.money(value))
			item.set_text(6, Utils.money(pnl, true))
			item.set_text(7, Utils.pct(PortfolioManager.get_position_pnl_pct(ticker)))
			item.set_custom_color(6, Utils.change_color(pnl))
			item.set_custom_color(7, Utils.change_color(pnl))
		item = item.get_next()
	_update_footer()


func _update_footer() -> void:
	_footer.text = "%d positions   |   Invested %s   |   Cash %s   |   Total %s" % [
		PortfolioManager.holdings.size(),
		Utils.money(PortfolioManager.get_holdings_value()),
		Utils.money(PortfolioManager.cash),
		Utils.money(PortfolioManager.get_total_value()),
	]


func _on_selection_changed() -> void:
	var has_selection := _tree.get_selected() != null
	_edit_btn.disabled = not has_selection
	_remove_btn.disabled = not has_selection


func _on_edit() -> void:
	var ticker := _selected_ticker()
	if not ticker.is_empty():
		_dialog.setup_adjust(ticker)


func _on_remove() -> void:
	var ticker := _selected_ticker()
	if ticker.is_empty():
		return
	_pending_remove = ticker
	_confirm.popup_centered()


func _do_remove() -> void:
	if not _pending_remove.is_empty():
		PortfolioManager.remove_holding(_pending_remove)
	_pending_remove = ""
