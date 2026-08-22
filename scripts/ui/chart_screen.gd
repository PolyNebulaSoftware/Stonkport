extends Control
## Chart screen: ticker + timeframe selectors, live price header, and the
## custom-drawn CandlestickChart widget.

const CandlestickChartScript := preload("res://scripts/chart/candlestick_chart.gd")

const TIMEFRAMES := ["1D", "1W", "1M", "1Y"]

var _ticker_option: OptionButton
var _tf_option: OptionButton
var _price_label: Label
var _chg_label: Label
var _chart: Control


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

	vbox.add_child(_build_selector_row())

	_chart = CandlestickChartScript.new()
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_chart)

	MarketSimulator.market_ticked.connect(_on_market_ticked)

	var start := ""
	var invested: Array = PortfolioManager.get_invested_tickers()
	if not invested.is_empty():
		start = str(invested[0])
	elif MarketSimulator.universe.has("AAPL"):
		start = "AAPL"
	_select_ticker(start)


func _build_selector_row() -> Control:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)

	var ticker_caption := Label.new()
	ticker_caption.text = "Ticker:"
	ticker_caption.add_theme_color_override("font_color", Utils.MUTED)
	top.add_child(ticker_caption)

	_ticker_option = OptionButton.new()
	for ticker in MarketSimulator.get_tickers_sorted():
		_ticker_option.add_item(str(ticker))
	_ticker_option.item_selected.connect(func(_index: int) -> void: _reload())
	top.add_child(_ticker_option)

	var tf_caption := Label.new()
	tf_caption.text = "Timeframe:"
	tf_caption.add_theme_color_override("font_color", Utils.MUTED)
	top.add_child(tf_caption)

	_tf_option = OptionButton.new()
	for timeframe in TIMEFRAMES:
		_tf_option.add_item(timeframe)
	_tf_option.select(0)
	_tf_option.item_selected.connect(func(_index: int) -> void: _reload())
	top.add_child(_tf_option)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	_price_label = Label.new()
	_price_label.add_theme_font_size_override("font_size", 18)
	top.add_child(_price_label)

	_chg_label = Label.new()
	top.add_child(_chg_label)
	return top


## Public entry point used by the watchlist deep-link.
func set_ticker(ticker: String) -> void:
	_select_ticker(ticker)


func _select_ticker(ticker: String) -> void:
	for i in _ticker_option.item_count:
		if _ticker_option.get_item_text(i) == ticker:
			_ticker_option.select(i)
			break
	_reload()


func _current_ticker() -> String:
	if _ticker_option.item_count == 0:
		return ""
	return _ticker_option.get_item_text(_ticker_option.selected)


func _current_timeframe() -> String:
	return _tf_option.get_item_text(_tf_option.selected)


func _reload() -> void:
	var ticker := _current_ticker()
	if ticker.is_empty():
		return
	_chart.set_series(ticker, _current_timeframe(), MarketSimulator.get_history(ticker, _current_timeframe()))
	_update_header(ticker)


func _on_market_ticked() -> void:
	var ticker := _current_ticker()
	if ticker.is_empty():
		return
	_chart.refresh_live(MarketSimulator.get_history(ticker, _current_timeframe()))
	_update_header(ticker)


func _update_header(ticker: String) -> void:
	var price := MarketSimulator.get_price(ticker)
	var chg := MarketSimulator.get_day_change(ticker)
	_price_label.text = Utils.money(price)
	_price_label.add_theme_color_override("font_color", Utils.TEXT)
	_chg_label.text = "%s (%s)" % [Utils.money(chg, true), Utils.pct(MarketSimulator.get_day_change_pct(ticker))]
	_chg_label.add_theme_color_override("font_color", Utils.change_color(chg))
