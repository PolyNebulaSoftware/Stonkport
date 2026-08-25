extends Control
## Analyze screen: draggable/zoomable candlestick chart for any asset with
## overlay analytics (MA ribbon, resizable Stoch RSI pane) and GBM simulation
## projections. Everything is drawn on a clipped canvas so nothing spills
## outside the graph frame. The floating top bar holds the ticker finder
## (trade-log search first, then Yahoo Finance) and the timespan dropdown;
## the collapsible left panel holds analytics/simulation options.

const LEFT_W := 248.0
const AXIS_W := 58.0
const TIMEFRAMES := ["1m", "5m", "1h", "1d", "1w"]
const EMA_LENGTHS := [9, 12, 21, 26, 50, 100]
const SMA_LENGTHS := [20, 50, 100, 200]
const RIBBON_COLORS := [
	Color("58a6ff"), Color("3fb950"), Color("d29922"),
	Color("a371f7"), Color("f85149"), Color("56d4dd"),
]
const SEARCH_URL := "https://query1.finance.yahoo.com/v1/finance/search?q=%s&quotesCount=10&newsCount=0"

var _ticker := ""
var _timeframe := "1d"

# Analytics options.
var _ribbon_on := true
var _ribbon_ema_on := true
var _ribbon_sma_on := false
var _ribbon_count := 4
var _stoch_on := false
var _stoch_ratio := 0.20     # stoch pane height as a fraction of the plot
var _rsi_len := 14
var _stoch_len := 14
var _k_smooth := 3
var _d_smooth := 3

# Simulation options.
var _gbm_on := false
var _gbm_days := 30
var _gbm_paths := 12
var _seed_val := 20260825

# Computed series.
var _bars: Array = []               # raw (USD) candles from the feed
var _view_bars_data: Array = []     # candles rescaled to the display currency
var _emas := {}                 # period -> PackedFloat64Array (EMA family)
var _smas := {}                 # period -> PackedFloat64Array (SMA family)
var _k_line := PackedFloat64Array()
var _d_line := PackedFloat64Array()
var _cone: Array = []           # per-step {"mid", "hi", "lo"}
var _paths: Array = []          # sample paths of future closes

# UI.
var _canvas: ChartCanvas        # clipped surface every chart primitive draws on
var _ticker_button: Button
var _price_label: Label
var _tf_button: OptionButton
var _options_panel: Control
var _collapse_btn: Button
var _seed_edit: LineEdit
var _ribbon_cfg: VBoxContainer
var _stoch_cfg: VBoxContainer
var _gbm_cfg: VBoxContainer
var _mouse_pos := Vector2(-1.0, -1.0)   # crosshair position; negative = hidden

# Ticker search dialog.
var _search_dialog: AcceptDialog
var _search_edit: LineEdit
var _results_list: ItemList
var _results: Array = []        # [{asset, label}, ...]
var _search_timer: Timer
var _search_http: HTTPRequest
var _searching := false
var _pending_query := ""

# Chart viewport (pan / zoom).
var _view_start := 0.0     # leftmost visible bar index
var _view_bars := 0.0      # visible candle count; 0 = fit all
var _y_zoom := 1.0         # vertical zoom from price-axis dragging
var _y_shift := 0.0        # vertical pan offset in price units
var _center_pending := false   # re-center the live price on the next draw
var _dragging := false
var _drag_mode := ""       # "", "pan", "scale_y", "scale_x", "scale_stoch"
var _drag_from_x := 0.0
var _drag_from_y := 0.0
var _drag_from_start := 0.0
var _drag_start_y_zoom := 1.0
var _drag_start_bars := 0.0
var _drag_start_shift := 0.0
var _drag_start_ratio := 0.0
var _layout := {}          # last drawn chart geometry for input mapping


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Invisible input layer behind every panel: owns pan / zoom / crosshair.
	var input := Control.new()
	input.set_anchors_preset(Control.PRESET_FULL_RECT)
	input.mouse_filter = Control.MOUSE_FILTER_STOP
	input.gui_input.connect(_on_chart_input)
	input.mouse_exited.connect(_on_chart_exit)
	add_child(input)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 4)
	# Layout shells must not swallow hits meant for the chart input layer;
	# their interactive children are still hit-tested individually.
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(hbox)

	_collapse_btn = Button.new()
	_collapse_btn.text = "‹"
	_collapse_btn.tooltip_text = "Toggle analytics panel"
	_collapse_btn.focus_mode = Control.FOCUS_NONE
	_collapse_btn.custom_minimum_size = Vector2(32, 0)
	_collapse_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_collapse_btn.pressed.connect(_toggle_options)
	hbox.add_child(_collapse_btn)

	_options_panel = _build_options_panel()
	hbox.add_child(_options_panel)

	var holder := Control.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(holder)

	_canvas = ChartCanvas.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_chart)
	holder.add_child(_canvas)

	# Floating top bar spans the whole screen and ignores the left panel.
	add_child(_build_top_overlay())
	_build_search_dialog()

	TradeManager.trades_changed.connect(_on_trades_changed)
	TradeManager.settings_changed.connect(_recompute)
	MarketSimulator.market_ticked.connect(_recompute)

	_ticker = _default_ticker()
	_update_ticker_button()
	_recompute()


# --- UI construction ---------------------------------------------------------


func _build_options_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(LEFT_W - 8, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Utils.panel_style())

	# Scrollable options on top; the disclaimer stays pinned below it.
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	panel.add_child(outer)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	var analytics := _add_section(vbox, "Analytics")
	analytics.add_child(_check("MA Ribbon overlay", _ribbon_on, "ribbon"))
	_ribbon_cfg = VBoxContainer.new()
	_ribbon_cfg.add_theme_constant_override("separation", 5)
	_ribbon_cfg.add_child(_check("EMAs", _ribbon_ema_on, "ribbon_ema"))
	_ribbon_cfg.add_child(_check("SMAs", _ribbon_sma_on, "ribbon_sma"))
	_ribbon_cfg.add_child(_spin_row("Lines per type", _ribbon_count, 1,
			maxi(EMA_LENGTHS.size(), SMA_LENGTHS.size()), "ema_count"))
	analytics.add_child(_ribbon_cfg)

	analytics.add_child(_check("Stoch RSI pane", _stoch_on, "stoch"))
	_stoch_cfg = VBoxContainer.new()
	_stoch_cfg.add_theme_constant_override("separation", 5)
	_stoch_cfg.add_child(_spin_row("RSI length", _rsi_len, 2, 50, "rsi_len"))
	_stoch_cfg.add_child(_spin_row("Stoch length", _stoch_len, 2, 50, "stoch_len"))
	_stoch_cfg.add_child(_spin_row("%K smooth", _k_smooth, 1, 10, "k_smooth"))
	_stoch_cfg.add_child(_spin_row("%D smooth", _d_smooth, 1, 10, "d_smooth"))
	analytics.add_child(_stoch_cfg)

	var sims := _add_section(vbox, "Simulations")
	sims.add_child(_check("GBM projection", _gbm_on, "gbm"))
	_gbm_cfg = VBoxContainer.new()
	_gbm_cfg.add_theme_constant_override("separation", 5)

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 6)
	seed_row.add_child(_muted("Seed"))
	_seed_edit = LineEdit.new()
	_seed_edit.text = str(_seed_val)
	_seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_edit.text_changed.connect(_on_seed_text)
	seed_row.add_child(_seed_edit)
	var dice := Button.new()
	dice.text = "Random"
	dice.tooltip_text = "Randomize seed"
	dice.focus_mode = Control.FOCUS_NONE
	dice.pressed.connect(_on_randomize_seed)
	seed_row.add_child(dice)
	_gbm_cfg.add_child(seed_row)

	_gbm_cfg.add_child(_spin_row("Days to simulate", _gbm_days, 1, 365, "days"))
	_gbm_cfg.add_child(_spin_row("Sample paths", _gbm_paths, 0, 40, "paths"))

	var note := _muted("Drift and volatility are estimated from the loaded candles.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gbm_cfg.add_child(note)
	sims.add_child(_gbm_cfg)

	var disclaimer := _muted("Analytics and simulations are for information only — not financial advice. Any interpretation or trading decision based on them is your own responsibility.")
	disclaimer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(disclaimer)

	_sync_option_visibility()
	return panel


## Floating top bar: ticker finder button, live price and timespan dropdown.
## Anchored to the screen edges so it never shifts with the left panel.
func _build_top_overlay() -> Control:
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.offset_left = 0
	panel.offset_right = 0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.offset_top = 6
	panel.offset_bottom = 36
	panel.add_theme_stylebox_override("panel",
			Utils.flat_style(Color(0.07, 0.09, 0.12, 0.85), Utils.BORDER, 8, 10.0, 6.0))
	# Transparent to hits so panning works around the widgets.
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	panel.add_child(bar)

	_ticker_button = Button.new()
	_ticker_button.text = _ticker + " ▾"
	_ticker_button.tooltip_text = "Find a ticker"
	_ticker_button.focus_mode = Control.FOCUS_NONE
	_ticker_button.custom_minimum_size = Vector2(120, 0)
	_ticker_button.pressed.connect(_on_ticker_button_pressed)
	bar.add_child(_ticker_button)

	_price_label = Label.new()
	_price_label.add_theme_font_size_override("font_size", 14)
	bar.add_child(_price_label)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(16, 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(gap)

	bar.add_child(_muted("Timespan"))
	_tf_button = OptionButton.new()
	for tf in TIMEFRAMES:
		_tf_button.add_item(tf)
	_tf_button.select(TIMEFRAMES.find(_timeframe))
	_tf_button.custom_minimum_size = Vector2(76, 0)
	_tf_button.focus_mode = Control.FOCUS_NONE
	_tf_button.item_selected.connect(_on_timeframe_selected)
	bar.add_child(_tf_button)
	return panel


## Modal ticker finder: matches trade-log tickers instantly, then queries
## Yahoo Finance's search endpoint for anything else.
func _build_search_dialog() -> void:
	_search_dialog = AcceptDialog.new()
	_search_dialog.title = "Find Ticker"
	_search_dialog.min_size = Vector2i(440, 500)
	_search_dialog.get_ok_button().text = "Close"
	add_child(_search_dialog)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(410, 400)
	_search_dialog.add_child(vbox)

	vbox.add_child(_muted("Searches your trade log first, then Yahoo Finance."))

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Type a ticker or company name…"
	_search_edit.clear_button_enabled = true
	_search_edit.text_changed.connect(_on_search_text)
	vbox.add_child(_search_edit)

	_results_list = ItemList.new()
	_results_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_results_list.item_activated.connect(_on_result_activated)
	vbox.add_child(_results_list)

	_search_timer = Timer.new()
	_search_timer.wait_time = 0.45
	_search_timer.one_shot = true
	_search_timer.timeout.connect(_run_yf_search)
	_search_dialog.add_child(_search_timer)

	_search_http = HTTPRequest.new()
	_search_http.timeout = 8.0
	_search_http.request_completed.connect(_on_search_response)
	_search_dialog.add_child(_search_http)


func _add_section(parent: Control, title: String) -> VBoxContainer:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)
	var head := Button.new()
	head.text = "▾ " + title
	head.toggle_mode = true
	head.button_pressed = true
	head.flat = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.focus_mode = Control.FOCUS_NONE
	head.add_theme_font_size_override("font_size", 13)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	head.toggled.connect(func(on: bool): _toggle_section(body, head, title, on))
	wrap.add_child(head)
	wrap.add_child(body)
	parent.add_child(wrap)
	return body


func _toggle_section(body: Control, head: Button, title: String, on: bool) -> void:
	body.visible = on
	head.text = ("▾ " if on else "▸ ") + title


func _toggle_options() -> void:
	var show := not _options_panel.visible
	_options_panel.visible = show
	_collapse_btn.text = "‹" if show else "›"


func _check(text: String, pressed: bool, key: String) -> CheckButton:
	var cb := CheckButton.new()
	cb.text = text
	cb.button_pressed = pressed
	cb.focus_mode = Control.FOCUS_NONE
	cb.toggled.connect(_on_toggle.bind(key))
	return cb


func _spin_row(label_text: String, value: int, min_v: int, max_v: int, key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_muted(label_text))
	var spin := SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = 1
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(_on_spin.bind(key))
	row.add_child(spin)
	return row


func _muted(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Utils.MUTED)
	return label


# --- Option handlers ---------------------------------------------------------


func _on_toggle(pressed: bool, key: String) -> void:
	match key:
		"ribbon":
			_ribbon_on = pressed
		"ribbon_ema":
			_ribbon_ema_on = pressed
		"ribbon_sma":
			_ribbon_sma_on = pressed
		"stoch":
			_stoch_on = pressed
		"gbm":
			_gbm_on = pressed
	_sync_option_visibility()
	_recompute()


## Disabled overlays/simulations hide their configuration rows along.
func _sync_option_visibility() -> void:
	if _ribbon_cfg != null:
		_ribbon_cfg.visible = _ribbon_on
	if _stoch_cfg != null:
		_stoch_cfg.visible = _stoch_on
	if _gbm_cfg != null:
		_gbm_cfg.visible = _gbm_on


func _on_spin(value: float, key: String) -> void:
	match key:
		"ema_count":
			_ribbon_count = int(value)
		"rsi_len":
			_rsi_len = int(value)
		"stoch_len":
			_stoch_len = int(value)
		"k_smooth":
			_k_smooth = int(value)
		"d_smooth":
			_d_smooth = int(value)
		"days":
			_gbm_days = int(value)
		"paths":
			_gbm_paths = int(value)
	_recompute()


func _on_seed_text(text: String) -> void:
	if text.is_valid_int():
		_seed_val = int(text)
		_recompute()


func _on_randomize_seed() -> void:
	_seed_val = randi() % 100000000
	_seed_edit.text = str(_seed_val)
	_recompute()


func _on_timeframe_selected(index: int) -> void:
	_timeframe = TIMEFRAMES[index]
	_reset_view()
	_recompute()


func _on_trades_changed() -> void:
	_update_ticker_button()


# --- Ticker search -----------------------------------------------------------


func _default_ticker() -> String:
	for t in TradeManager.trades:
		if str(t.get("state", "")) == "open":
			return str(t.get("asset", ""))
	var tickers: Array = MarketSimulator.get_tickers_sorted()
	return str(tickers[0]) if not tickers.is_empty() else "GLD"


func _update_ticker_button() -> void:
	if _ticker_button != null:
		_ticker_button.text = _ticker + " ▾"


func _on_ticker_button_pressed() -> void:
	_search_edit.text = ""
	_results.clear()
	_results_list.clear()
	_fill_local("")
	_search_dialog.popup_centered()
	_search_edit.grab_focus()


func _on_search_text(text: String) -> void:
	_search_timer.stop()
	_results.clear()
	_results_list.clear()
	_fill_local(text)
	if text.strip_edges().length() >= 2:
		_search_timer.start()


## Instant matches from the journal's own tickers, most-open first.
## Option-contract assets are hidden — they have no chartable feed.
func _fill_local(query: String) -> void:
	var q := query.strip_edges().to_upper()
	var stats := {}   # asset -> {"open": int, "total": int, "option": bool}
	var order: Array = []
	for t in TradeManager.trades:
		var asset := str(t.get("asset", "")).to_upper()
		if asset.is_empty():
			continue
		if not stats.has(asset):
			stats[asset] = {"open": 0, "total": 0, "option": true}
			order.append(asset)
		var s: Dictionary = stats[asset]
		s["total"] = int(s["total"]) + 1
		if str(t.get("state", "")) == "open":
			s["open"] = int(s["open"]) + 1
		if str(t.get("asset_type", "stock")) != "option":
			s["option"] = false
	var rows: Array = []
	for asset in order:
		var s: Dictionary = stats[asset]
		if bool(s["option"]):
			continue
		if not q.is_empty() and not asset.contains(q):
			continue
		rows.append({"asset": asset, "open": int(s["open"]), "total": int(s["total"])})
	rows.sort_custom(_cmp_rows)
	for row in rows:
		_add_result({
			"asset": row["asset"],
			"label": "%s  ·  %d trades (%d open)" % [row["asset"], row["total"], row["open"]],
		})


static func _cmp_rows(a: Dictionary, b: Dictionary) -> bool:
	if int(a["open"]) != int(b["open"]):
		return int(a["open"]) > int(b["open"])
	if int(a["total"]) != int(b["total"]):
		return int(a["total"]) > int(b["total"])
	return str(a["asset"]) < str(b["asset"])


func _run_yf_search() -> void:
	var q := _search_edit.text.strip_edges()
	if q.length() < 2:
		return
	if _searching:
		_pending_query = q
		return
	_searching = true
	var err := _search_http.request(SEARCH_URL % q.uri_encode())
	if err != OK:
		_searching = false
		push_warning("Analyze: Yahoo search request failed (%d)" % err)


func _on_search_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	_searching = false
	if result == HTTPRequest.RESULT_SUCCESS and code == HTTPClient.RESPONSE_OK:
		var data: Variant = JSON.parse_string(body.get_string_from_utf8())
		if typeof(data) == TYPE_DICTIONARY:
			var quotes: Variant = data.get("quotes")
			if typeof(quotes) == TYPE_ARRAY:
				for quote in quotes:
					if typeof(quote) != TYPE_DICTIONARY:
						continue
					var qtype := str(quote.get("quoteType", ""))
					if not qtype in ["EQUITY", "ETF", "CRYPTOCURRENCY", "INDEX"]:
						continue
					var symbol := str(quote.get("symbol", "")).to_upper()
					if symbol.is_empty():
						continue
					var asset := symbol
					if qtype == "CRYPTOCURRENCY":
						asset = asset.trim_suffix("-USD")
					var name := str(quote.get("shortname",
							str(quote.get("longname", ""))))
					var exch := str(quote.get("exchDisp",
							str(quote.get("exchange", ""))))
					var kind := "crypto" if qtype == "CRYPTOCURRENCY" else "stock"
					_add_result({
						"asset": asset,
						"label": "%s  ·  %s  ·  %s %s" % [symbol, name, exch, kind],
					})
	else:
		push_warning("Analyze: Yahoo search failed (result=%d, http=%d)" % [result, code])
	if not _pending_query.is_empty():
		_pending_query = ""
		_run_yf_search()


func _add_result(entry: Dictionary) -> void:
	var asset := str(entry.get("asset", ""))
	for existing in _results:
		if str(existing.get("asset", "")) == asset:
			return
	_results.append(entry)
	_results_list.add_item(str(entry.get("label", asset)))


func _on_result_activated(index: int) -> void:
	if index < 0 or index >= _results.size():
		return
	var asset := str(_results[index].get("asset", ""))
	if asset.is_empty():
		return
	_search_dialog.hide()
	_select_ticker(asset)


func _select_ticker(asset: String) -> void:
	_ticker = asset
	_update_ticker_button()
	_reset_view()
	_center_pending = true
	_recompute()


# --- Chart viewport (pan / zoom) ---------------------------------------------


## Root-space point -> canvas-space point.
func _to_canvas(p: Vector2) -> Vector2:
	if _canvas == null:
		return p
	return p - (_canvas.get_global_position() - get_global_position())


func _on_chart_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var pos := _to_canvas(mb.position)
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(pos.x, 1.0 / 1.15)
			get_viewport().set_input_as_handled()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(pos.x, 1.15)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and mb.double_click:
				# Double-clicking an axis resets just that axis to fit.
				match _hit_mode(pos):
					"scale_y":
						_y_zoom = 1.0
						_y_shift = 0.0
						_canvas.queue_redraw()
					"scale_x":
						_view_start = 0.0
						_view_bars = 0.0
						_canvas.queue_redraw()
			else:
				_dragging = mb.pressed
				if _dragging:
					_drag_mode = _hit_mode(pos)
					_drag_from_x = pos.x
					_drag_from_y = pos.y
					_drag_from_start = _view_start
					_drag_start_y_zoom = _y_zoom
					_drag_start_bars = _view_bars
					_drag_start_shift = _y_shift
					_drag_start_ratio = _stoch_ratio
				else:
					# Release: snap horizontal pan to whole candles.
					if _drag_mode == "pan":
						_view_start = roundf(_view_start)
						_clamp_view()
						_canvas.queue_redraw()
					_drag_mode = ""
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var pos := _to_canvas(mm.position)
		_mouse_pos = pos
		if _dragging:
			match _drag_mode:
				"pan":
					var slot := float(_layout.get("slot", 0.0))
					if slot > 0.0:
						_view_start = roundf(_drag_from_start + (_drag_from_x - pos.x) / slot)
						_clamp_view()
					var span := float(_layout.get("span", 0.0))
					var main_h := float(_layout.get("main_h", 0.0))
					if span > 0.0 and main_h > 0.0:
						_y_shift = _drag_start_shift \
								+ (pos.y - _drag_from_y) * (span / main_h)
						var lim := span * 3.0
						_y_shift = clampf(_y_shift, -lim, lim)
				"scale_y":
					_y_zoom = clampf(_drag_start_y_zoom \
							* exp((_drag_from_y - pos.y) / 150.0), 0.25, 12.0)
				"scale_x":
					_view_bars = _drag_start_bars * exp((pos.x - _drag_from_x) / 150.0)
					_clamp_view()
				"scale_stoch":
					var plot_h := float(_layout.get("plot_h", 0.0))
					if plot_h > 0.0:
						_stoch_ratio = clampf(
								_drag_start_ratio - (pos.y - _drag_from_y) / plot_h,
								0.08, 0.60)
		_canvas.queue_redraw()


func _on_chart_exit() -> void:
	_mouse_pos = Vector2(-1.0, -1.0)
	_canvas.queue_redraw()


## Classifies a press point: the price gutter scales Y, the time strip scales
## X, the stoch divider resizes that pane, anything else pans.
func _hit_mode(pos: Vector2) -> String:
	var main: Rect2 = _layout.get("main", Rect2())
	if main.size == Vector2.ZERO:
		return "pan"
	if pos.x > main.end.x and pos.x <= main.end.x + AXIS_W \
			and pos.y >= main.position.y and pos.y <= main.end.y:
		return "scale_y"
	if _stoch_on and absf(pos.y - (main.end.y + 4.0)) <= 5.0 \
			and pos.x >= main.position.x and pos.x <= main.end.x:
		return "scale_stoch"
	if pos.y > main.end.y + 10.0 and pos.y <= main.end.y + 44.0 \
			and pos.x >= main.position.x and pos.x <= main.end.x:
		return "scale_x"
	return "pan"


## Zooms while keeping the bar under [param mouse_x] anchored.
func _zoom_at(mouse_x: float, factor: float) -> void:
	if _view_bars_data.is_empty():
		return
	var main: Rect2 = _layout.get("main", Rect2())
	var past_w := float(_layout.get("past_w", 0.0))
	if past_w <= 0.0:
		return
	var anchor := _view_start + (mouse_x - main.position.x) / past_w * _view_bars
	_view_bars *= factor
	_clamp_view()
	_view_start = anchor - (mouse_x - main.position.x) / past_w * _view_bars
	_clamp_view()
	_canvas.queue_redraw()


func _clamp_view() -> void:
	var total := maxf(float(_view_bars_data.size()), 8.0)
	_view_bars = clampf(_view_bars, 8.0, total)
	# Allow overscrolling by up to one full view width on either side.
	_view_start = clampf(_view_start, -_view_bars,
			maxf(total - _view_bars, 0.0) + _view_bars)


## Fits all candles on the next draw.
func _reset_view() -> void:
	_view_start = 0.0
	_view_bars = 0.0
	_y_zoom = 1.0
	_y_shift = 0.0


# --- Series computation ------------------------------------------------------


func _recompute() -> void:
	_bars = MarketSimulator.get_history(_ticker, _timeframe)
	# Remote feeds are USD-denominated; rescale to the display currency so
	# every chart element (candles, ribbon, GBM, axes) matches the setting.
	var rate := maxf(Utils.currency_rate, 0.000001)
	_view_bars_data.clear()
	for b in _bars:
		_view_bars_data.append({
			"open": float(b.get("open", 0.0)) * rate,
			"high": float(b.get("high", 0.0)) * rate,
			"low": float(b.get("low", 0.0)) * rate,
			"close": float(b.get("close", 0.0)) * rate,
		})
	var closes := PackedFloat64Array()
	closes.resize(_view_bars_data.size())
	for i in _view_bars_data.size():
		closes[i] = float(_view_bars_data[i].get("close", 0.0))

	_emas.clear()
	_smas.clear()
	if _ribbon_on:
		var count := mini(_ribbon_count, 6)
		if _ribbon_ema_on:
			for j in mini(count, EMA_LENGTHS.size()):
				var period := int(EMA_LENGTHS[j])
				_emas[period] = _ema(closes, period)
		if _ribbon_sma_on:
			for j in mini(count, SMA_LENGTHS.size()):
				var period := int(SMA_LENGTHS[j])
				_smas[period] = _sma_series(closes, period)

	if _stoch_on and closes.size() > 0:
		var rsi := _rsi(closes, _rsi_len)
		var raw := _stochastic(rsi, _stoch_len)
		_k_line = _sma_series(raw, _k_smooth)
		_d_line = _sma_series(_k_line, _d_smooth)
	else:
		_k_line = PackedFloat64Array()
		_d_line = PackedFloat64Array()

	_cone.clear()
	_paths.clear()
	if _gbm_on and closes.size() > 12:
		_build_gbm(closes)

	_update_header()
	_canvas.queue_redraw()


func _update_header() -> void:
	var price := Utils.from_usd(MarketSimulator.get_price(_ticker))
	var prev := Utils.from_usd(MarketSimulator.get_prev_close(_ticker))
	if price > 0.0:
		_price_label.text = Utils.money(price)
		_price_label.add_theme_color_override("font_color",
				Utils.change_color(price - prev))
	else:
		_price_label.text = ""


func _minutes_per_bar() -> float:
	var spec: Dictionary = MarketSimulator.TIMEFRAME_SPECS.get(_timeframe, {})
	return maxf(float(spec.get("minutes", 390.0)), 1.0)


## Wall-clock duration of one candle (a daily candle spans a whole day,
## a weekly candle a whole week) used for timestamp placement.
func _seconds_per_bar() -> float:
	var spec: Dictionary = MarketSimulator.TIMEFRAME_SPECS.get(_timeframe, {})
	return maxf(float(spec.get("seconds", float(spec.get("minutes", 390.0)) * 60.0)), 1.0)


## Analytic GBM quantile cone plus seeded sample paths over [member _gbm_days].
func _build_gbm(closes: PackedFloat64Array) -> void:
	var rets := PackedFloat64Array()
	for i in range(1, closes.size()):
		if closes[i - 1] > 0.0 and closes[i] > 0.0:
			rets.append(log(closes[i] / closes[i - 1]))
	if rets.is_empty():
		return
	var mu := 0.0
	for r in rets:
		mu += r
	mu /= rets.size()
	var acc := 0.0
	for r in rets:
		acc += (r - mu) * (r - mu)
	var sigma := sqrt(acc / maxf(rets.size() - 1, 1))
	# Rescale per-bar statistics to daily steps.
	var per_day := clampf(390.0 / _minutes_per_bar(), 1.0, 390.0)
	mu *= per_day
	sigma *= sqrt(per_day)

	var s0 := closes[closes.size() - 1]
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_val
	_cone.clear()
	_paths.clear()
	for t in range(1, _gbm_days + 1):
		var m := mu * float(t)
		var sd := sigma * sqrt(float(t))
		_cone.append({
			"mid": s0 * exp(m),
			"hi": s0 * exp(m + 1.2816 * sd),
			"lo": s0 * exp(m - 1.2816 * sd),
		})
	for p in _gbm_paths:
		var path := PackedFloat64Array()
		path.resize(_gbm_days + 1)
		path[0] = s0
		var px := s0
		for t in range(1, _gbm_days + 1):
			px *= exp(mu + sigma * rng.randfn(0.0, 1.0))
			path[t] = px
		_paths.append(path)


static func _ema(values: PackedFloat64Array, period: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(values.size())
	out.fill(NAN)
	if values.size() < period or period < 1:
		return out
	var k := 2.0 / float(period + 1)
	var prev := 0.0
	for i in values.size():
		if i < period:
			prev += values[i]
			if i == period - 1:
				prev /= float(period)
				out[i] = prev
		else:
			prev = values[i] * k + prev * (1.0 - k)
			out[i] = prev
	return out


static func _rsi(values: PackedFloat64Array, period: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(values.size())
	out.fill(NAN)
	if values.size() <= period or period < 1:
		return out
	var gain := 0.0
	var loss := 0.0
	for i in range(1, period + 1):
		var d := values[i] - values[i - 1]
		gain += maxf(d, 0.0)
		loss += maxf(-d, 0.0)
	gain /= float(period)
	loss /= float(period)
	out[period] = _rsi_value(gain, loss)
	for i in range(period + 1, values.size()):
		var d := values[i] - values[i - 1]
		gain = (gain * float(period - 1) + maxf(d, 0.0)) / float(period)
		loss = (loss * float(period - 1) + maxf(-d, 0.0)) / float(period)
		out[i] = _rsi_value(gain, loss)
	return out


static func _rsi_value(gain: float, loss: float) -> float:
	if loss <= 0.0000001:
		return 100.0
	return 100.0 - 100.0 / (1.0 + gain / loss)


static func _stochastic(values: PackedFloat64Array, lookback: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(values.size())
	out.fill(NAN)
	var start := -1
	for i in values.size():
		if not is_nan(values[i]):
			start = i
			break
	if start < 0 or lookback < 1:
		return out
	for i in range(start + lookback - 1, values.size()):
		if is_nan(values[i]):
			continue
		var hi := -INF
		var lo := INF
		for j in range(i - lookback + 1, i + 1):
			hi = maxf(hi, values[j])
			lo = minf(lo, values[j])
		out[i] = 0.0 if hi - lo <= 0.0000001 else (values[i] - lo) / (hi - lo) * 100.0
	return out


static func _sma_series(values: PackedFloat64Array, period: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(values.size())
	out.fill(NAN)
	if period <= 1:
		return values.duplicate()
	var sum := 0.0
	var count := 0
	for i in values.size():
		if is_nan(values[i]):
			continue
		sum += values[i]
		count += 1
		if count > period:
			sum -= values[i - period]
			count = period
		if count == period:
			out[i] = sum / float(period)
	return out


# --- Rendering ---------------------------------------------------------------


func _draw_chart() -> void:
	var font := _canvas.get_theme_default_font()
	var n := _view_bars_data.size()

	# Canvas-local layout: the holder already sits right of the left panel,
	# so collapsing it lets the chart reclaim the space automatically.
	var cw := _canvas.size.x
	var ch := _canvas.size.y
	var plot := Rect2(Vector2(6, 38), Vector2(cw - 12.0 - AXIS_W, ch - 64.0))
	if plot.size.x < 60.0 or plot.size.y < 60.0:
		return
	if n == 0:
		_canvas.draw_string(font, Vector2(16, ch * 0.5),
				"No data for %s" % _ticker, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Utils.MUTED)
		return

	var stoch_gap := 8.0
	var stoch_h := plot.size.y * clampf(_stoch_ratio, 0.08, 0.60) if _stoch_on else 0.0
	var main := Rect2(plot.position,
			Vector2(plot.size.x, plot.size.y - stoch_h - (stoch_gap if stoch_h > 0.0 else 0.0)))
	var stoch_rect := Rect2(Vector2(plot.position.x, main.end.y + stoch_gap),
			Vector2(plot.size.x, stoch_h))

	var past_w := main.size.x

	# Resolve the pannable/zoomable viewport over the candle series.
	if _view_bars <= 0.0:
		_view_bars = float(maxi(n, 8))
	_clamp_view()
	var slot := past_w / _view_bars
	var i0 := clampi(int(floor(_view_start)), 0, maxi(n - 1, 0))
	var i1 := clampi(int(ceil(_view_start + _view_bars)), i0 + 1, n)

	# Projection geometry: anchored to the last candle, scaled with the zoom.
	var proj_from := -1
	var proj_to := -1     # inclusive visible day-step window
	var x_last := 0.0
	var day_slot := 0.0
	if not _cone.is_empty():
		var steps := _cone.size()
		x_last = main.position.x + (float(n - 1) - _view_start + 0.5) * slot
		day_slot = slot * clampf(390.0 / _minutes_per_bar(), 0.02, 390.0)
		if day_slot > 0.0001:
			proj_from = clampi(int(floor((main.position.x - x_last) / day_slot)), 0, steps)
			proj_to = clampi(int(ceil((main.end.x - x_last) / day_slot)), -1, steps - 1)

	# Price scale across the visible candles, ribbons and projection window.
	var lo := INF
	var hi := -INF
	for i in range(i0, i1):
		var bar: Dictionary = _bars[i]
		lo = minf(lo, float(bar["low"]))
		hi = maxf(hi, float(bar["high"]))
	for arr in _emas.values():
		for i in range(i0, mini(i1, arr.size())):
			var v: float = arr[i]
			if not is_nan(v):
				lo = minf(lo, v)
				hi = maxf(hi, v)
	for arr in _smas.values():
		for i in range(i0, mini(i1, arr.size())):
			var v: float = arr[i]
			if not is_nan(v):
				lo = minf(lo, v)
				hi = maxf(hi, v)
	if proj_from >= 0 and proj_to >= proj_from:
		for t in range(proj_from, proj_to + 1):
			var point: Dictionary = _cone[t]
			lo = minf(lo, float(point["lo"]))
			hi = maxf(hi, float(point["hi"]))
		for path in _paths:
			for t in range(proj_from, mini(proj_to, path.size() - 2) + 1):
				lo = minf(lo, float(path[t + 1]))
				hi = maxf(hi, float(path[t + 1]))
	if lo > hi:
		_canvas.draw_string(font, Vector2(16, ch * 0.5),
				"No data for %s" % _ticker, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Utils.MUTED)
		return
	var pad := (hi - lo) * 0.05
	if pad <= 0.0:
		pad = maxf(hi * 0.02, 1.0)
	lo -= pad
	hi += pad
	# Vertical zoom driven by dragging the price axis...
	var mid := (lo + hi) * 0.5
	var half := (hi - lo) * 0.5 / clampf(_y_zoom, 0.05, 30.0)
	lo = mid - half
	hi = mid + half
	# ...and vertical pan applied as a straight price-unit shift. A pending
	# ticker switch first re-centers the live price on the Y axis.
	if _center_pending:
		_center_pending = false
		_y_shift = 0.0
		var live_now := MarketSimulator.get_price(_ticker)
		if live_now > 0.0:
			_y_shift = live_now - (lo + hi) * 0.5
	lo += _y_shift
	hi += _y_shift

	_layout = {
		"main": main, "past_w": past_w, "slot": slot,
		"span": hi - lo, "main_h": main.size.y, "plot_h": plot.size.y,
	}

	var grid := _alpha(Utils.BORDER, 0.55)

	# Horizontal grid + price labels outside on the right.
	for g in 5:
		var gy := main.position.y + main.size.y * float(g) / 4.0
		_canvas.draw_line(Vector2(main.position.x, gy), Vector2(main.end.x, gy), grid, 1.0)
		var val := hi - (hi - lo) * float(g) / 4.0
		_canvas.draw_string(font, Vector2(main.end.x + 6, gy - 4), _axis_price(val),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Utils.MUTED)

	# Vertical time grid + labels aligned to calendar boundaries: month
	# starts on daily/weekly views, midnight on hourly views, top of the
	# hour on 5m and quarter hours on 1m. Lines run through both panes and
	# into the overscroll zones.
	var now_ts := int(Time.get_unix_time_from_system())
	var sec_pb := _seconds_per_bar()
	var span_min := sec_pb * _view_bars / 60.0
	var last_label := ""
	var prev_key := ""
	# Extrapolate across the whole draggable window — including virtual
	# bars before the first and after the latest candle — so gridlines and
	# their dates continue to the frame limits.
	var i0v := int(floor(_view_start))
	var i1v := int(ceil(_view_start + _view_bars))
	prev_key = _boundary_key(now_ts - int(float(n - 1 - (i0v - 1)) * sec_pb))
	for i in range(i0v, i1v):
		var ts := now_ts - int(float(n - 1 - i) * sec_pb)
		var key := _boundary_key(ts)
		var is_boundary := key != prev_key
		prev_key = key
		if not is_boundary:
			continue
		var cx := main.position.x + (float(i) - _view_start + 0.5) * slot
		if cx < main.position.x - 1.0 or cx > main.end.x + 1.0:
			continue
		_canvas.draw_line(Vector2(cx, plot.position.y),
				Vector2(cx, plot.end.y), grid, 1.0)
		var label := _fmt_axis_time(ts, span_min)
		if label == last_label:
			continue
		last_label = label
		_canvas.draw_string(font, Vector2(cx - 30, plot.end.y + 16), label,
				HORIZONTAL_ALIGNMENT_CENTER, 60, 10, Utils.MUTED)

	# GBM projection: quantile cone + seeded sample paths, anchored to the
	# last candle and clipped to the visible day-step window.
	if proj_from >= 0 and proj_to >= proj_from:
		var s0 := float(_view_bars_data[n - 1]["close"])
		var y0 := _map_y(s0, lo, hi, main)
		var hi_pts := PackedVector2Array([Vector2(x_last, y0)])
		var mid_pts := PackedVector2Array([Vector2(x_last, y0)])
		var lo_pts := PackedVector2Array([Vector2(x_last, y0)])
		for t in range(proj_from, proj_to + 1):
			var pt: Dictionary = _cone[t]
			var x := x_last + float(t + 1) * day_slot
			hi_pts.append(Vector2(x, _map_y(float(pt["hi"]), lo, hi, main)))
			mid_pts.append(Vector2(x, _map_y(float(pt["mid"]), lo, hi, main)))
			lo_pts.append(Vector2(x, _map_y(float(pt["lo"]), lo, hi, main)))
		if hi_pts.size() >= 2:
			var poly := PackedVector2Array(hi_pts)
			for k in range(lo_pts.size() - 1, -1, -1):
				poly.append(lo_pts[k])
			_canvas.draw_colored_polygon(poly, _alpha(Utils.ACCENT, 0.08))
			_canvas.draw_polyline(hi_pts, _alpha(Utils.ACCENT, 0.35), 1.0, true)
			_canvas.draw_polyline(lo_pts, _alpha(Utils.ACCENT, 0.35), 1.0, true)
			_canvas.draw_polyline(mid_pts, _alpha(Utils.GREEN, 0.85), 1.4, true)
		for path in _paths:
			var pp := PackedVector2Array([Vector2(x_last, y0)])
			for t in range(proj_from, proj_to + 1):
				pp.append(Vector2(x_last + float(t + 1) * day_slot,
						_map_y(float(path[t + 1]), lo, hi, main)))
			if pp.size() >= 2:
				_canvas.draw_polyline(pp, _alpha(Utils.TEXT, 0.18), 1.0, true)
		if x_last >= main.position.x and x_last <= main.end.x:
			_canvas.draw_line(Vector2(x_last, main.position.y), Vector2(x_last, main.end.y),
					_alpha(Utils.MUTED, 0.5), 1.0)

	# Candles.
	if i1 > i0:
		var body_w := maxf(slot * 0.62, 1.5)
		for i in range(i0, i1):
			var bar: Dictionary = _view_bars_data[i]
			var cx := main.position.x + (float(i) - _view_start + 0.5) * slot
			var o := float(bar["open"])
			var h := float(bar["high"])
			var l := float(bar["low"])
			var c := float(bar["close"])
			var col := Utils.GREEN if c >= o else Utils.RED
			_canvas.draw_line(Vector2(cx, _map_y(h, lo, hi, main)),
					Vector2(cx, _map_y(l, lo, hi, main)), col, 1.2)
			var y_open := _map_y(o, lo, hi, main)
			var y_close := _map_y(c, lo, hi, main)
			_canvas.draw_rect(Rect2(cx - body_w * 0.5, minf(y_open, y_close),
					body_w, maxf(absf(y_close - y_open), 1.2)), col)

	# Live price marker: dotted guide from the last candle to the axis.
	var live := Utils.from_usd(MarketSimulator.get_price(_ticker))
	if live > 0.0:
		var ly := _map_y(live, lo, hi, main)
		if ly >= main.position.y and ly <= main.end.y:
			var lcol := Utils.change_color(live - MarketSimulator.get_prev_close(_ticker))
			var xs := clampf(main.position.x + (float(n - 1) - _view_start + 0.5) * slot,
					main.position.x, main.end.x)
			_canvas.draw_dashed_line(Vector2(xs, ly), Vector2(main.end.x, ly),
					_alpha(lcol, 0.9), 1.0, 3.0)
			_canvas.draw_rect(Rect2(main.end.x + 2.0, ly - 8.0, AXIS_W - 4.0, 16.0),
					Color(lcol.r, lcol.g, lcol.b, 0.22))
			_canvas.draw_string(font, Vector2(main.end.x + 6.0, ly + 4.0), _axis_price(live),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, lcol)

	# MA ribbon: EMA and/or SMA families share the color cycle.
	for fam in [_emas, _smas]:
		var periods: Array = fam.keys()
		periods.sort()
		for j in periods.size():
			var series: PackedFloat64Array = fam[periods[j]]
			_draw_series(series, lo, hi, main, main.position.x, slot, _view_start,
					RIBBON_COLORS[j % RIBBON_COLORS.size()], 1.6, 0.95)

	# Stoch RSI sub-pane with a draggable divider.
	if stoch_h > 0.0 and _k_line.size() > 0:
		_canvas.draw_rect(stoch_rect, Color(0.07, 0.09, 0.12, 0.6))
		_canvas.draw_line(Vector2(stoch_rect.position.x, stoch_rect.position.y),
				Vector2(stoch_rect.end.x, stoch_rect.position.y), grid, 1.0)
		var grip_y := main.end.y + stoch_gap * 0.5
		_canvas.draw_line(Vector2(main.position.x + 24, grip_y),
				Vector2(main.end.x - 24, grip_y), _alpha(Utils.BORDER, 0.9), 1.0)
		for level in [80.0, 20.0]:
			var lvl_y := _map_y(level, 0.0, 100.0, stoch_rect)
			_canvas.draw_dashed_line(Vector2(stoch_rect.position.x, lvl_y),
					Vector2(stoch_rect.end.x, lvl_y), _alpha(Utils.MUTED, 0.4), 1.0, 4.0)
			_canvas.draw_string(font, Vector2(stoch_rect.position.x + 4, lvl_y - 3),
					"%.0f" % level, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Utils.MUTED)
		_draw_series(_k_line, 0.0, 100.0, stoch_rect, stoch_rect.position.x, slot,
				_view_start, Utils.ACCENT, 1.4, 1.0)
		_draw_series(_d_line, 0.0, 100.0, stoch_rect, stoch_rect.position.x, slot,
				_view_start, Utils.ORANGE, 1.2, 1.0)
		_canvas.draw_string(font, Vector2(stoch_rect.position.x + 30, stoch_rect.position.y + 12),
				"Stoch RSI (%d, %d, %d, %d)" % [_rsi_len, _stoch_len, _k_smooth, _d_smooth],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Utils.MUTED)

	# Crosshair: dotted guides pointing to the x/y values under the cursor.
	var in_main := _mouse_pos.x >= main.position.x and _mouse_pos.x <= main.end.x \
			and _mouse_pos.y >= main.position.y and _mouse_pos.y <= main.end.y
	var in_stoch := stoch_h > 0.0 and _mouse_pos.x >= stoch_rect.position.x \
			and _mouse_pos.x <= stoch_rect.end.x \
			and _mouse_pos.y >= stoch_rect.position.y and _mouse_pos.y <= stoch_rect.end.y
	if in_main or in_stoch:
		var dash := _alpha(Utils.MUTED, 0.65)
		var chip_bg := Color(0.07, 0.09, 0.12, 0.95)
		# Vertical guide snaps to the nearest candle slot — including
		# extrapolated slots beyond the data on both sides.
		var snap_idx := int(round(
				_view_start + (_mouse_pos.x - main.position.x) / maxf(slot, 0.0001) - 0.5))
		var snap_x := main.position.x + (float(snap_idx) - _view_start + 0.5) * slot
		_canvas.draw_dashed_line(Vector2(snap_x, main.position.y),
				Vector2(snap_x, plot.end.y), dash, 1.0, 3.0)
		if in_main:
			_canvas.draw_dashed_line(Vector2(main.position.x, _mouse_pos.y),
					Vector2(main.end.x, _mouse_pos.y), dash, 1.0, 3.0)
			var price := lo + (hi - lo) * (1.0 - (_mouse_pos.y - main.position.y) / main.size.y)
			_canvas.draw_rect(Rect2(main.end.x + 2.0, _mouse_pos.y - 8.0, AXIS_W - 4.0, 16.0), chip_bg)
			_canvas.draw_string(font, Vector2(main.end.x + 6.0, _mouse_pos.y + 4.0),
					_axis_price(price), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Utils.TEXT)
			var ts := now_ts - int(float(n - 1 - snap_idx) * _seconds_per_bar())
			var xlabel := _fmt_full_time(ts, _seconds_per_bar() * _view_bars / 60.0)
			var xw := maxf(56.0, font.get_string_size(xlabel,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x + 10.0)
			var lx := clampf(_mouse_pos.x - xw * 0.5, main.position.x, main.end.x - xw)
			_canvas.draw_rect(Rect2(lx, plot.end.y + 2.0, xw, 14.0), chip_bg)
			_canvas.draw_string(font, Vector2(lx + 4.0, plot.end.y + 12.0), xlabel,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Utils.TEXT)
		elif in_stoch:
			_canvas.draw_dashed_line(Vector2(stoch_rect.position.x, _mouse_pos.y),
					Vector2(stoch_rect.end.x, _mouse_pos.y), dash, 1.0, 3.0)
			var sval := 100.0 * (1.0 - (_mouse_pos.y - stoch_rect.position.y) / stoch_rect.size.y)
			_canvas.draw_rect(Rect2(main.end.x + 2.0, _mouse_pos.y - 8.0, AXIS_W - 4.0, 16.0), chip_bg)
			_canvas.draw_string(font, Vector2(main.end.x + 6.0, _mouse_pos.y + 4.0),
					"%.1f" % sval, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Utils.TEXT)


func _draw_series(values: PackedFloat64Array, lo: float, hi: float, rect: Rect2,
		x_origin: float, slot: float, view_start: float,
		color: Color, line_w: float, alpha: float) -> void:
	var pts := PackedVector2Array()
	for i in values.size():
		var v := values[i]
		if is_nan(v):
			continue
		pts.append(Vector2(x_origin + (float(i) - view_start + 0.5) * slot,
				_map_y(v, lo, hi, rect)))
	if pts.size() >= 2:
		_canvas.draw_polyline(pts, _alpha(color, alpha), line_w, true)


static func _map_y(v: float, lo: float, hi: float, rect: Rect2) -> float:
	if hi - lo <= 0.0000001:
		return rect.position.y + rect.size.y * 0.5
	return rect.position.y + rect.size.y * (1.0 - (v - lo) / (hi - lo))


func _alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)


func _axis_price(v: float) -> String:
	if absf(v) >= 10000.0:
		return Utils.compact(v)
	return "%.2f" % v


## Axis-marker format based on the visible span: months for multi-week
## views, day stamps for multi-hour views, clock times intraday.
static func _fmt_axis_time(ts: int, span_minutes: float) -> String:
	var stamp := Utils.datetime_str(ts)
	if span_minutes >= 1440.0 * 21.0:
		return stamp.substr(0, 7)      # YYYY-MM
	if span_minutes >= 1440.0:
		return stamp.substr(5, 5)      # MM-DD
	return stamp.substr(11, 5)         # HH:MM


## Crosshair format: full precision for the hovered bar.
static func _fmt_full_time(ts: int, span_minutes: float) -> String:
	var stamp := Utils.datetime_str(ts)
	return stamp if span_minutes < 1440.0 else stamp.substr(0, 10)


## Calendar bucket used for gridline alignment at the current timeframe:
## months on daily/weekly candles, days on hourly, hours on 5m and
## quarter-hours on 1m.
func _boundary_key(ts: int) -> String:
	var s := _seconds_per_bar()
	if s >= 86400.0:
		return Utils.datetime_str(ts).substr(0, 7)      # month start
	if s >= 3600.0:
		return Utils.datetime_str(ts).substr(0, 10)     # day start
	if s >= 300.0:
		return str(int(ts / 3600.0))                    # hour start
	return str(int(ts / 900.0))                          # quarter hour


## Clipped drawing surface: every chart primitive lands here so nothing
## spills outside the graph frame.
class ChartCanvas extends Control:
	func _init() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_IGNORE
