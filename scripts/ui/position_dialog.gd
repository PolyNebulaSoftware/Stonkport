extends AcceptDialog
## Add/Edit position dialog.
##  - trade mode: pick ticker, Buy/Sell, shares, price (validated against
##    cash balance and held shares).
##  - adjust mode: directly set shares + avg cost for an existing position.

var _mode := "trade"
var _rows: Dictionary = {}
var _ticker_option: OptionButton
var _action_option: OptionButton
var _shares_spin: SpinBox
var _price_spin: SpinBox
var _avg_spin: SpinBox
var _error_label: Label
var _adjust_ticker := ""


func _ready() -> void:
	title = "Position"
	min_size = Vector2i(430, 0)
	get_ok_button().hide()

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	content.custom_minimum_size = Vector2(400, 0)
	add_child(content)

	_ticker_option = OptionButton.new()
	_ticker_option.item_selected.connect(func(_index: int) -> void:
		_sync_price_to_ticker()
		_sync_limits())
	_rows["ticker"] = _form_row(content, "Ticker", _ticker_option)

	_action_option = OptionButton.new()
	_action_option.add_item("Buy")
	_action_option.add_item("Sell")
	_action_option.item_selected.connect(func(_index: int) -> void: _sync_limits())
	_rows["action"] = _form_row(content, "Action", _action_option)

	_shares_spin = SpinBox.new()
	_shares_spin.min_value = 0.0
	_shares_spin.max_value = 1000000000.0
	_shares_spin.step = 1.0
	_shares_spin.suffix = " sh"
	_rows["shares"] = _form_row(content, "Shares", _shares_spin)

	_price_spin = SpinBox.new()
	_price_spin.min_value = 0.01
	_price_spin.max_value = 1000000.0
	_price_spin.step = 0.01
	_rows["price"] = _form_row(content, "Price (USD)", _price_spin)

	_avg_spin = SpinBox.new()
	_avg_spin.min_value = 0.01
	_avg_spin.max_value = 1000000.0
	_avg_spin.step = 0.01
	_rows["avg_cost"] = _form_row(content, "Avg Cost (USD)", _avg_spin)

	_error_label = Label.new()
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.add_theme_color_override("font_color", Utils.RED)
	content.add_child(_error_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	content.add_child(buttons)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(hide)
	buttons.add_child(cancel_btn)

	var confirm_btn := Button.new()
	confirm_btn.text = "Confirm"
	confirm_btn.pressed.connect(_on_confirm)
	buttons.add_child(confirm_btn)


func _form_row(parent: Control, label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(110, 0)
	label.add_theme_color_override("font_color", Utils.MUTED)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)
	return row


## Open for a new Buy/Sell trade.
func setup_trade() -> void:
	_mode = "trade"
	title = "Add Position"
	_fill_tickers()
	_rows["ticker"].show()
	_rows["action"].show()
	_rows["price"].show()
	_rows["avg_cost"].hide()
	_action_option.selected = 0
	_error_label.text = ""
	_sync_price_to_ticker()
	_sync_limits()
	popup_centered()


## Open to directly edit an existing position's shares / avg cost.
func setup_adjust(ticker: String) -> void:
	_mode = "adjust"
	_adjust_ticker = ticker
	title = "Edit Position - %s" % ticker
	_rows["ticker"].hide()
	_rows["action"].hide()
	_rows["price"].hide()
	_rows["avg_cost"].show()
	var h: Dictionary = PortfolioManager.get_holding(ticker)
	_shares_spin.set_value_no_signal(float(h.get("shares", 0.0)))
	_avg_spin.set_value_no_signal(float(h.get("avg_cost", 0.0)))
	_error_label.text = ""
	popup_centered()


func _fill_tickers() -> void:
	_ticker_option.clear()
	for ticker in MarketSimulator.get_tickers_sorted():
		_ticker_option.add_item(str(ticker))


func _current_ticker() -> String:
	if _ticker_option.item_count == 0:
		return ""
	return _ticker_option.get_item_text(_ticker_option.selected)


func _sync_price_to_ticker() -> void:
	var ticker := _current_ticker()
	if not ticker.is_empty():
		_price_spin.set_value_no_signal(maxf(MarketSimulator.get_price(ticker), 0.01))


func _sync_limits() -> void:
	if _mode != "trade":
		return
	var ticker := _current_ticker()
	if _action_option.selected == 1 and PortfolioManager.holdings.has(ticker):
		_shares_spin.max_value = maxf(float(PortfolioManager.holdings[ticker]["shares"]), 1.0)
	else:
		_shares_spin.max_value = 1000000000.0


func _on_confirm() -> void:
	if _mode == "trade":
		var err := ""
		var ticker := _current_ticker()
		if _action_option.selected == 0:
			err = PortfolioManager.buy(ticker, _shares_spin.value, _price_spin.value)
		else:
			err = PortfolioManager.sell(ticker, _shares_spin.value, _price_spin.value)
		if err.is_empty():
			hide()
		else:
			_error_label.text = err
	else:
		var err := PortfolioManager.adjust_holding(_adjust_ticker, _shares_spin.value, _avg_spin.value)
		if err.is_empty():
			hide()
		else:
			_error_label.text = err
