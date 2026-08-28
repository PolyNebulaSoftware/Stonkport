extends Node
## Autoload: per-asset drift/volatility estimates for GBM projections,
## computed from real market history instead of the simulator's synthetic
## candles. Stocks use 1y of daily closes from Yahoo's chart endpoint
## (session + transport shared with YFinance); crypto uses Binance public
## klines. Volatility is a RiskMetrics EWMA (lambda 0.94) over daily log
## returns — more responsive to regime shifts than a flat sample std — with
## the plain sample std kept alongside; drift is the mean daily log return.
## Results are cached per asset with a TTL, refreshed on a timer and when the
## trade journal changes; consumers fall back to candle-derived estimates
## until real stats arrive.

signal stats_updated(asset: String)

const STATS_TTL_SEC := 3600.0        # skip refetch while stats are fresh
const EWMA_LAMBDA := 0.94            # RiskMetrics decay factor
const MIN_RETURNS := 20              # below this the estimates are noise
const REQUEST_TIMEOUT_S := 10.0
const BINANCE_KLINES_URL := "https://data-api.binance.vision/api/v3/klines?symbol=%s&interval=1d&limit=365"

var _stats: Dictionary = {}   # asset -> {mu_daily, sigma_daily, sigma_sample_daily, samples, source, updated}
var _refreshing := false
var _queued := false
var _cycle := 0               # generation counter; stale fetches can't end a newer cycle
var _remaining := 0


func _ready() -> void:
	TradeManager.trades_changed.connect(request_refresh)
	var timer := Timer.new()
	timer.wait_time = 6.0 * 3600.0
	timer.autostart = true
	timer.timeout.connect(request_refresh)
	add_child(timer)
	request_refresh.call_deferred()


## Cached estimates for [param asset]; {} when no real history is available.
func get_stats(asset: String) -> Dictionary:
	return _stats.get(str(asset).to_upper().strip_edges(), {})


## Fetches history and recomputes stats for every tradable journal asset
## whose cached estimates are missing or stale. Overlapping refreshes
## coalesce into one.
func request_refresh() -> void:
	if _refreshing:
		_queued = true
		return
	var now := Time.get_unix_time_from_system()
	var todo: Array = []
	for entry in YFinance.collect_symbols():
		var cached: Dictionary = _stats.get(str(entry[0]), {})
		if not cached.is_empty() \
				and now - float(cached.get("updated", 0.0)) < STATS_TTL_SEC:
			continue
		todo.append(entry)
	if todo.is_empty():
		return
	_refreshing = true
	_queued = false
	_cycle += 1
	_remaining = todo.size()
	for entry in todo:
		_fetch_asset(entry, _cycle)


func _fetch_asset(entry: Array, cycle: int) -> void:
	match str(entry[2]):
		"crypto":
			_fetch_binance_history(str(entry[0]), str(entry[1]), cycle)
		_:
			_fetch_yahoo_history(str(entry[0]), str(entry[1]), cycle)


func _fetch_yahoo_history(asset: String, symbol: String, cycle: int) -> void:
	var hist: Dictionary = await YFinance.fetch_chart_history(symbol, "1y", "1d")
	_absorb(asset, hist, "Yahoo", cycle)


func _fetch_binance_history(asset: String, symbol: String, cycle: int) -> void:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_S
	add_child(http)
	var url: String = await YFinance.proxied_url(BINANCE_KLINES_URL % symbol)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		push_warning("MarketStats: klines request could not start for %s (%d)" % [symbol, err])
		_absorb(asset, {}, "Binance", cycle)
		return
	var res: Array = await http.request_completed
	http.queue_free()
	var hist := {}
	if res[0] == HTTPRequest.RESULT_SUCCESS and int(res[1]) == HTTPClient.RESPONSE_OK:
		hist = _parse_klines(PackedByteArray(res[3]))
	else:
		push_warning("MarketStats: klines request failed for %s (result=%d, http=%d)" % [symbol, res[0], res[1]])
	_absorb(asset, hist, "Binance", cycle)


## Extracts daily closes from a Binance klines payload
## ([[open_time, open, high, low, close, ...], ...]).
func _parse_klines(body: PackedByteArray) -> Dictionary:
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	var closes := PackedFloat64Array()
	if typeof(data) == TYPE_ARRAY:
		for row: Variant in data:
			if typeof(row) == TYPE_ARRAY and row.size() > 4:
				closes.append(str(row[4]).to_float())
	var hist := {}
	if not closes.is_empty():
		hist["close"] = closes
	return hist


func _absorb(asset: String, hist: Dictionary, source: String, cycle: int) -> void:
	if hist.has("close"):
		var stats := _compute_stats(hist["close"], source)
		if not stats.is_empty():
			_stats[asset] = stats
			stats_updated.emit(asset)
	if cycle != _cycle:
		return   # a newer refresh cycle owns the bookkeeping
	_remaining -= 1
	if _remaining <= 0:
		_refreshing = false
		if _queued:
			_queued = false
			request_refresh()


## Drift (mean daily log return) plus EWMA and sample daily volatility,
## computed over close-to-close log returns.
func _compute_stats(closes: PackedFloat64Array, source: String) -> Dictionary:
	var rets := PackedFloat64Array()
	for i in range(1, closes.size()):
		if closes[i - 1] > 0.0 and closes[i] > 0.0:
			rets.append(log(closes[i] / closes[i - 1]))
	if rets.size() < MIN_RETURNS:
		return {}
	var mean := 0.0
	for r in rets:
		mean += r
	mean /= rets.size()
	var acc := 0.0
	for r in rets:
		acc += (r - mean) * (r - mean)
	var sample_var := acc / maxf(rets.size() - 1, 1)
	# RiskMetrics EWMA: iterating forward weights recent returns most.
	var ewma_var := sample_var
	for r in rets:
		ewma_var = EWMA_LAMBDA * ewma_var + (1.0 - EWMA_LAMBDA) * r * r
	return {
		"mu_daily": mean,
		"sigma_daily": sqrt(ewma_var),
		"sigma_sample_daily": sqrt(sample_var),
		"samples": rets.size(),
		"source": source,
		"updated": int(Time.get_unix_time_from_system()),
	}
