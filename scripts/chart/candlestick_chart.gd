class_name CandlestickChart
extends Control
## Custom-drawn candlestick chart: grid, candles, volume bars, crosshair,
## tooltip, and a live last-price marker. All rendering happens in _draw().

const UP_COLOR := Color("3fb950")
const DOWN_COLOR := Color("f85149")
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.06)
const AXIS_TEXT_COLOR := Color("8b949e")
const CROSSHAIR_COLOR := Color(1.0, 1.0, 1.0, 0.35)
const LAST_PRICE_COLOR := Color("58a6ff")
const TOOLTIP_BG := Color(0.0509804, 0.0666667, 0.0901961, 0.95)
const TOOLTIP_BORDER := Color("30363d")

const PAD_LEFT := 10.0
const PAD_RIGHT := 68.0
const PAD_TOP := 12.0
const PAD_BOTTOM := 26.0
const VOLUME_GAP := 16.0
const VOLUME_FRACTION := 0.18
const GRID_ROWS := 5

var ticker := ""
var timeframe := "1D"
var bars: Array = []

var _mouse_inside := false
var _mouse_pos := Vector2.ZERO

# Layout cached during _draw() and used by coordinate helpers.
var _lo := 0.0
var _hi := 1.0
var _plot_top := 0.0
var _price_h := 1.0
var _plot_left := 0.0
var _slot := 1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(320, 240)


func set_series(p_ticker: String, p_timeframe: String, p_bars: Array) -> void:
	ticker = p_ticker
	timeframe = p_timeframe
	bars = p_bars
	queue_redraw()


## Cheap per-tick update: same series, only the last bar changed.
func refresh_live(p_bars: Array) -> void:
	bars = p_bars
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_mouse_inside = false
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_pos = event.position
		_mouse_inside = true
		queue_redraw()


func _draw() -> void:
	var s := get_size()
	if s.x < 60.0 or s.y < 60.0:
		return
	draw_rect(Rect2(Vector2.ZERO, s), Utils.BG)
	var font := ThemeDB.fallback_font
	if bars.is_empty():
		var msg := "No data for %s" % ticker if not ticker.is_empty() else "No data"
		draw_string(font, Vector2(16, 32), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, AXIS_TEXT_COLOR)
		return

	_plot_left = PAD_LEFT
	var plot_right := s.x - PAD_RIGHT
	_plot_top = PAD_TOP
	var chart_bottom := s.y - PAD_BOTTOM
	var vol_h := (chart_bottom - _plot_top) * VOLUME_FRACTION
	var price_bottom := chart_bottom - vol_h - VOLUME_GAP
	_price_h = maxf(price_bottom - _plot_top, 10.0)

	var hi := -INF
	var lo := INF
	var vmax := 0.0
	for bar in bars:
		hi = maxf(hi, float(bar["high"]))
		lo = minf(lo, float(bar["low"]))
		vmax = maxf(vmax, float(bar["volume"]))
	if hi <= lo:
		hi = lo + 1.0
	var pad := (hi - lo) * 0.08
	_hi = hi + pad
	_lo = maxf(lo - pad, 0.0)

	_slot = maxf((plot_right - _plot_left) / bars.size(), 0.5)
	var body_w := maxf(_slot * 0.62, 1.5)
	var vol_top := price_bottom + VOLUME_GAP

	# Horizontal grid + right-axis price labels.
	for i in GRID_ROWS + 1:
		var frac := float(i) / float(GRID_ROWS)
		var y := _plot_top + _price_h * (1.0 - frac)
		draw_line(Vector2(_plot_left, y), Vector2(plot_right, y), GRID_COLOR, 1.0)
		draw_string(
			font, Vector2(plot_right + 8.0, y + 4.0), "%.2f" % _price_at(frac),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AXIS_TEXT_COLOR
		)

	# Vertical grid + time labels.
	var step := maxi(1, int(floor(bars.size() / 8.0)))
	for i in range(0, bars.size(), step):
		var x := _plot_left + _slot * (float(i) + 0.5)
		draw_line(Vector2(x, _plot_top), Vector2(x, chart_bottom), GRID_COLOR, 1.0)
		draw_string(font, Vector2(x + 3.0, s.y - 8.0), _time_label(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, AXIS_TEXT_COLOR)

	# Candles + volume bars.
	for i in bars.size():
		var bar: Dictionary = bars[i]
		var cx := _plot_left + _slot * (float(i) + 0.5)
		var o := float(bar["open"])
		var c := float(bar["close"])
		var up := c >= o
		var col := UP_COLOR if up else DOWN_COLOR
		draw_line(Vector2(cx, _py(float(bar["high"]))), Vector2(cx, _py(float(bar["low"]))), col, 1.0)
		var y_top := minf(_py(o), _py(c))
		var body_h := maxf(absf(_py(c) - _py(o)), 1.0)
		draw_rect(Rect2(cx - body_w * 0.5, y_top, body_w, body_h), col, true)
		var vh := (float(bar["volume"]) / vmax) * vol_h if vmax > 0.0 else 0.0
		draw_rect(Rect2(cx - body_w * 0.5, chart_bottom - vh, body_w, vh), Color(col, 0.4), true)

	_draw_last_price_line(plot_right, font)
	if _mouse_inside:
		_draw_crosshair(plot_right, chart_bottom, font)


func _py(price: float) -> float:
	return _plot_top + _price_h * (1.0 - (price - _lo) / (_hi - _lo))


func _price_at(frac: float) -> float:
	return _lo + (_hi - _lo) * clampf(frac, 0.0, 1.0)


func _draw_last_price_line(plot_right: float, font: Font) -> void:
	var last := float(bars[bars.size() - 1]["close"])
	var y := clampf(_py(last), _plot_top, _plot_top + _price_h)
	draw_dashed_line(Vector2(_plot_left, y), Vector2(plot_right, y), Color(LAST_PRICE_COLOR, 0.55), 1.0, 5.0)
	var tag_rect := Rect2(plot_right + 4.0, y - 9.0, PAD_RIGHT - 8.0, 18.0)
	draw_rect(tag_rect, LAST_PRICE_COLOR, true)
	draw_string(font, Vector2(tag_rect.position.x + 6.0, y + 4.0), "%.2f" % last, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Utils.BG)


func _draw_crosshair(plot_right: float, chart_bottom: float, font: Font) -> void:
	var mx := clampf(_mouse_pos.x, _plot_left, plot_right)
	var idx := clampi(int((mx - _plot_left) / _slot), 0, bars.size() - 1)
	var cx := _plot_left + _slot * (float(idx) + 0.5)
	draw_dashed_line(Vector2(cx, _plot_top), Vector2(cx, chart_bottom), CROSSHAIR_COLOR, 1.0, 4.0)
	var my := clampf(_mouse_pos.y, _plot_top, chart_bottom)
	draw_dashed_line(Vector2(_plot_left, my), Vector2(plot_right, my), CROSSHAIR_COLOR, 1.0, 4.0)

	# Price tag on the axis under the cursor.
	var frac := clampf(1.0 - (my - _plot_top) / _price_h, 0.0, 1.0)
	draw_rect(Rect2(plot_right + 4.0, my - 9.0, PAD_RIGHT - 8.0, 18.0), Color("21262d"), true)
	draw_string(font, Vector2(plot_right + 10.0, my + 4.0), "%.2f" % _price_at(frac), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AXIS_TEXT_COLOR)

	_draw_tooltip(bars[idx], idx, font)


func _draw_tooltip(bar: Dictionary, index: int, font: Font) -> void:
	var o := float(bar["open"])
	var h := float(bar["high"])
	var l := float(bar["low"])
	var c := float(bar["close"])
	var chg := c - o
	var chg_pct := (chg / o * 100.0) if o > 0.0 else 0.0
	var lines := [
		"%s  |  %s  |  Bar %d" % [ticker, timeframe, index + 1],
		"O %.2f    H %.2f" % [o, h],
		"L %.2f    C %.2f" % [l, c],
		"Chg %s (%s)" % [Utils.money(chg, true), Utils.pct(chg_pct)],
		"Vol %s" % Utils.compact(float(bar["volume"])),
	]
	var line_h := 17.0
	var pad := 8.0
	var w := 0.0
	for line in lines:
		w = maxf(w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
	var box := Rect2(Vector2.ZERO, Vector2(w + pad * 2.0, line_h * lines.size() + pad * 2.0 - 4.0))
	var pos := _mouse_pos + Vector2(16.0, 16.0)
	if pos.x + box.size.x > get_size().x - 4.0:
		pos.x = _mouse_pos.x - box.size.x - 16.0
	if pos.y + box.size.y > get_size().y - 4.0:
		pos.y = _mouse_pos.y - box.size.y - 16.0
	box.position = pos.max(Vector2(4.0, 4.0))
	draw_rect(box, TOOLTIP_BG, true)
	draw_rect(box, TOOLTIP_BORDER, false, 1.0)
	for i in lines.size():
		var color := Utils.TEXT if i == 0 else Utils.MUTED
		if i == 3:
			color = Utils.change_color(chg)
		draw_string(
			font, box.position + Vector2(pad, pad + 11.0 + float(i) * line_h),
			lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color
		)


func _time_label(index: int) -> String:
	var minutes := 5
	if MarketSimulator.TIMEFRAME_SPECS.has(timeframe):
		minutes = int(MarketSimulator.TIMEFRAME_SPECS[timeframe]["minutes"])
	var now := int(Time.get_unix_time_from_system())
	var ts := now - (bars.size() - 1 - index) * minutes * 60
	var d := Time.get_datetime_dict_from_unix_time(ts)
	if timeframe == "1D":
		return "%02d:%02d" % [d["hour"], d["minute"]]
	if timeframe == "1W":
		return "%02d/%02d %02dh" % [d["month"], d["day"], d["hour"]]
	return "%02d/%02d" % [d["month"], d["day"]]
