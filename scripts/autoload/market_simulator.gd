extends Node
## Autoload: mock market data engine.
## Loads the stock universe, simulates prices with a geometric random walk,
## generates synthetic OHLCV history, and broadcasts updates.

signal price_updated(ticker: String, price: float)
signal market_ticked

const UNIVERSE_PATH := "res://data/stocks.json"
const DEFAULT_INTERVAL_S := 5.0
const TRADING_MINUTES_PER_DAY := 390.0

const TIMEFRAME_SPECS := {
	"1m": {"bars": 390, "minutes": 1, "seconds": 60},
	"5m": {"bars": 288, "minutes": 5, "seconds": 300},
	"1h": {"bars": 240, "minutes": 60, "seconds": 3600},
	"1d": {"bars": 390, "minutes": 390, "seconds": 86400},
	"1w": {"bars": 156, "minutes": 1950, "seconds": 604800},
}

var universe: Dictionary = {}
var current_prices: Dictionary = {}
var prev_close: Dictionary = {}
var live_quotes: Dictionary = {}
var tick_count := 0

var _rng := RandomNumberGenerator.new()
var _timer: Timer
var _interval_s := DEFAULT_INTERVAL_S
var _history_cache: Dictionary = {}


func _ready() -> void:
	_load_universe()
	_rng.randomize()
	_reset_prices()
	_timer = Timer.new()
	_timer.wait_time = _interval_s
	_timer.timeout.connect(tick)
	add_child(_timer)
	_timer.start()


func set_refresh_interval(seconds: float) -> void:
	_interval_s = clampf(seconds, 1.0, 3600.0)
	_timer.wait_time = _interval_s
	if not _timer.is_stopped():
		_timer.start()


func get_refresh_interval() -> float:
	return _interval_s


func reset_market() -> void:
	_rng.randomize()
	_reset_prices()
	market_ticked.emit()


func tick() -> void:
	if universe.is_empty():
		return
	var day_fraction := (_interval_s / 60.0) / TRADING_MINUTES_PER_DAY
	for ticker in universe.keys():
		var sigma: float = float(universe[ticker].get("volatility", 0.02))
		var shock := (
			-0.5 * sigma * sigma * day_fraction
			+ sigma * sqrt(day_fraction) * _rng.randfn(0.0, 1.0)
		)
		var price := maxf(float(current_prices[ticker]) * exp(shock), 0.01)
		current_prices[ticker] = price
		price_updated.emit(ticker, price)
	tick_count += 1
	market_ticked.emit()


func get_price(ticker: String) -> float:
	if current_prices.has(ticker):
		return float(current_prices[ticker])
	return float(live_quotes.get(ticker, 0.0))


## Re-anchors a ticker to a live external quote (Yahoo Finance). Universe
## tickers continue their random walk from the quoted price; unknown
## tickers (e.g. imported ones) are served from [member live_quotes] only.
func apply_live_quote(ticker: String, price: float, prev_px := 0.0) -> void:
	if price <= 0.0:
		return
	live_quotes[ticker] = price
	if current_prices.has(ticker):
		current_prices[ticker] = price
	if prev_px > 0.0:
		prev_close[ticker] = prev_px
	for key in _history_cache.keys():
		if str(key).begins_with("%s|" % ticker):
			_history_cache.erase(key)
	price_updated.emit(ticker, price)


func get_prev_close(ticker: String) -> float:
	return float(prev_close.get(ticker, 0.0))


func get_day_change(ticker: String) -> float:
	return get_price(ticker) - get_prev_close(ticker)


func get_day_change_pct(ticker: String) -> float:
	var pc := get_prev_close(ticker)
	return (get_day_change(ticker) / pc * 100.0) if pc > 0.0 else 0.0


func get_stock_info(ticker: String) -> Dictionary:
	return universe.get(ticker, {})


func get_tickers_sorted() -> Array:
	var tickers: Array = universe.keys()
	tickers.sort()
	return tickers


func get_top_movers(count: int) -> Array:
	var rows: Array = []
	for ticker in universe.keys():
		rows.append({
			"ticker": ticker,
			"price": get_price(ticker),
			"change": get_day_change(ticker),
			"change_pct": get_day_change_pct(ticker),
		})
	rows.sort_custom(func(a, b): return absf(a["change_pct"]) > absf(b["change_pct"]))
	rows.resize(mini(count, rows.size()))
	return rows


## Returns cached OHLCV bars for a ticker/timeframe; the last bar tracks the
## live price. Bars are generated deterministically per (ticker, timeframe)
## and anchored so the final close equals the current simulated price.
## Unknown tickers (imported/custom assets) get a deterministic walk anchored
## on their live quote so they still chart.
func get_history(ticker: String, timeframe: String) -> Array:
	var spec: Dictionary = TIMEFRAME_SPECS.get(timeframe, TIMEFRAME_SPECS["5m"])
	var key := "%s|%s" % [ticker, timeframe]
	if not _history_cache.has(key):
		if universe.has(ticker):
			var info: Dictionary = universe[ticker]
			var anchor := get_price(ticker)
			if anchor <= 0.0:
				anchor = float(info.get("base_price", 100.0))
			_history_cache[key] = _synth_bars(hash("sim|%s" % ticker), anchor,
					float(info.get("volatility", 0.02)),
					int(spec["bars"]), float(spec["minutes"]))
		else:
			var custom_anchor := get_price(ticker)
			if custom_anchor <= 0.0:
				custom_anchor = 100.0
			_history_cache[key] = _synth_bars(hash("custom|%s" % ticker),
					custom_anchor, 0.035, int(spec["bars"]), float(spec["minutes"]))
	var bars: Array = _history_cache[key]
	if not bars.is_empty():
		var live := get_price(ticker)
		if live > 0.0:
			var last: Dictionary = bars[bars.size() - 1]
			last["close"] = live
			last["high"] = maxf(float(last["high"]), live)
			last["low"] = minf(float(last["low"]), live)
	return bars


## Deterministic OHLCV random walk ending exactly on [param target].
func _synth_bars(seed_key: int, target: float, sigma_daily: float,
		bar_count: int, minutes_per_bar: float) -> Array:
	var bar_sigma := sigma_daily * sqrt(minutes_per_bar / TRADING_MINUTES_PER_DAY)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|%d|%f" % [seed_key, bar_count, minutes_per_bar])

	# Cumulative log-returns; anchoring subtracts the total so the final
	# close lands exactly on the target price.
	var cum := PackedFloat64Array()
	cum.resize(bar_count + 1)
	cum[0] = 0.0
	for i in bar_count:
		cum[i + 1] = cum[i] + rng.randfn(0.0, bar_sigma)
	var total := cum[bar_count]

	var base_volume := maxf(target * 25000.0, 100000.0)
	var bars: Array = []
	for i in bar_count:
		var open := target * exp(cum[i] - total)
		var close := target * exp(cum[i + 1] - total)
		var high := maxf(open, close) * (1.0 + absf(rng.randfn(0.0, bar_sigma * 0.6)))
		var low := maxf(minf(open, close) * (1.0 - absf(rng.randfn(0.0, bar_sigma * 0.6))), 0.01)
		var volume := int(
			base_volume * rng.randf_range(0.35, 1.65)
			* (1.0 + 6.0 * absf(close - open) / maxf(open, 0.01))
		)
		bars.append({"open": open, "high": high, "low": low, "close": close, "volume": volume})
	return bars


func _load_universe() -> void:
	if not FileAccess.file_exists(UNIVERSE_PATH):
		push_error("MarketSimulator: missing stock universe at %s" % UNIVERSE_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(UNIVERSE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY or parsed.is_empty():
		push_error("MarketSimulator: invalid stock universe JSON")
		return
	universe = parsed


func _reset_prices() -> void:
	current_prices.clear()
	prev_close.clear()
	_history_cache.clear()
	for ticker in universe.keys():
		var base: float = float(universe[ticker].get("base_price", 100.0))
		current_prices[ticker] = snappedf(maxf(base * (1.0 + _rng.randf_range(-0.03, 0.03)), 0.01), 0.01)
		prev_close[ticker] = snappedf(maxf(base * (1.0 + _rng.randf_range(-0.02, 0.02)), 0.01), 0.01)
