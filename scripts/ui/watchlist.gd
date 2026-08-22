extends Control
## Watchlist: live price rows with add/remove; clicking a ticker jumps to the
## Chart tab (via the chart_requested signal handled by Main).

signal chart_requested(ticker: String)

var _rows_box: VBoxContainer
var _add_option: OptionButton
var _add_btn: Button
var _row_refs: Array = []


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

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 6)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)

	PortfolioManager.portfolio_changed.connect(_rebuild)
	MarketSimulator.market_ticked.connect(_update_prices)
	_rebuild()


func _build_toolbar() -> Control:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)

	var title := Label.new()
	title.text = "Watchlist"
	title.add_theme_font_size_override("font_size", 16)
	top.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	var add_caption := Label.new()
	add_caption.text = "Add:"
	add_caption.add_theme_color_override("font_color", Utils.MUTED)
	top.add_child(add_caption)

	_add_option = OptionButton.new()
	_add_option.custom_minimum_size = Vector2(110, 0)
	top.add_child(_add_option)

	_add_btn = Button.new()
	_add_btn.text = "Add"
	_add_btn.pressed.connect(_on_add)
	top.add_child(_add_btn)
	return top


func _rebuild() -> void:
	for child in _rows_box.get_children():
		child.queue_free()
	_row_refs.clear()

	if PortfolioManager.watchlist.is_empty():
		var empty := Label.new()
		empty.text = "Watchlist is empty - add a ticker above."
		empty.add_theme_color_override("font_color", Utils.MUTED)
		_rows_box.add_child(empty)

	for ticker in PortfolioManager.watchlist:
		_rows_box.add_child(_make_row(str(ticker)))

	var remaining: Array = []
	for ticker in MarketSimulator.get_tickers_sorted():
		if not PortfolioManager.watchlist.has(ticker):
			remaining.append(ticker)
	_add_option.clear()
	for ticker in remaining:
		_add_option.add_item(str(ticker))
	_add_option.disabled = remaining.is_empty()
	_add_btn.disabled = remaining.is_empty()
	_update_prices()


func _make_row(ticker: String) -> Control:
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	var open_btn := Button.new()
	open_btn.text = ticker
	open_btn.flat = true
	open_btn.tooltip_text = "Open chart"
	open_btn.custom_minimum_size = Vector2(64, 0)
	open_btn.add_theme_color_override("font_color", Utils.ACCENT)
	open_btn.pressed.connect(func() -> void: chart_requested.emit(ticker))
	hbox.add_child(open_btn)

	var name_label := Label.new()
	name_label.text = str(MarketSimulator.get_stock_info(ticker).get("name", ""))
	name_label.add_theme_color_override("font_color", Utils.MUTED)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	hbox.add_child(name_label)

	var price_label := Label.new()
	price_label.custom_minimum_size = Vector2(84, 0)
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(price_label)

	var chg_label := Label.new()
	chg_label.custom_minimum_size = Vector2(76, 0)
	chg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(chg_label)

	var remove_btn := Button.new()
	remove_btn.text = "x"
	remove_btn.flat = true
	remove_btn.tooltip_text = "Remove from watchlist"
	remove_btn.add_theme_color_override("font_color", Utils.MUTED)
	remove_btn.pressed.connect(func() -> void: PortfolioManager.remove_from_watchlist(ticker))
	hbox.add_child(remove_btn)

	_row_refs.append({"ticker": ticker, "price": price_label, "chg": chg_label})
	return panel


func _update_prices() -> void:
	for ref in _row_refs:
		var ticker: String = ref["ticker"]
		var chg := MarketSimulator.get_day_change(ticker)
		var price_label: Label = ref["price"]
		var chg_label: Label = ref["chg"]
		price_label.text = Utils.money(MarketSimulator.get_price(ticker))
		chg_label.text = Utils.pct(MarketSimulator.get_day_change_pct(ticker))
		chg_label.add_theme_color_override("font_color", Utils.change_color(chg))


func _on_add() -> void:
	if _add_option.item_count == 0:
		return
	PortfolioManager.add_to_watchlist(_add_option.get_item_text(_add_option.selected))
