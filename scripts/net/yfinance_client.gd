extends Node
## Autoload: fetches live quotes and re-anchors MarketSimulator prices.
## Stocks come from Yahoo Finance's chart endpoint (the same public API the
## yfinance library wraps; cookies + crumb session bootstrapped like
## yfinance does, with one session-rebuild retry per refused cycle).
## Crypto comes from Binance's public data API (data-api.binance.vision).
## Fetches happen once on load and whenever TradeManager emits a save;
## overlapping refreshes coalesce into one.

const CHART_URL := "https://query1.finance.yahoo.com/v8/finance/chart/%s?interval=1d&range=1d"
const CRUMB_URL := "https://query1.finance.yahoo.com/v1/test/getcrumb"
const COOKIE_SEED_URL := "https://finance.yahoo.com/"
const BINANCE_TICKER_URL := "https://data-api.binance.vision/api/v3/ticker/24hr?symbol=%s"
const REQUEST_TIMEOUT_S := 8.0
const MAX_SYMBOLS_PER_REFRESH := 24
const FX_REFRESH_SEC := 3600.0

var _pending := {}          # asset -> in-flight request flag
var _refreshing := false
var _queued := false

# Live FX (fetched hourly from Yahoo "XXXUSD=X" pairs, USD per 1 unit).
var _fx_pairs := {}
var _fx_busy := false
var _fx_remaining := 0

# Yahoo session state (cookies + crumb), mirroring what yfinance does.
var _cookie_pairs := {}     # cookie name -> "name=value"
var _crumb := ""
var _session_ready := false
var _bootstrapping := false

# Per-cycle bookkeeping for the session-retry pass (Yahoo side only).
var _current_symbols: Array = []
var _succeeded := 0
var _cycle_retried := false


func _ready() -> void:
	TradeManager.trades_changed.connect(request_refresh)
	TradeManager.settings_changed.connect(_apply_fx)
	# Single fetch on load, once TradeManager has hydrated the journal.
	request_refresh.call_deferred()

	# Hourly FX refresh keeps USD_RATES conversions real-world accurate;
	# the static table in Utils only serves as the offline fallback.
	var fx_timer := Timer.new()
	fx_timer.wait_time = FX_REFRESH_SEC
	fx_timer.autostart = true
	fx_timer.timeout.connect(_refresh_fx)
	add_child(fx_timer)
	_refresh_fx.call_deferred()


## Collects tradable symbols from the journal and fires one request each.
func request_refresh() -> void:
	if _refreshing:
		_queued = true
		return
	var symbols := _collect_symbols()
	if symbols.is_empty():
		return
	_refreshing = true
	_succeeded = 0
	_cycle_retried = false
	# Crypto needs no session — fire those right away.
	var stocks: Array = []
	for entry in symbols:
		if str(entry[2]) == "crypto":
			_fetch_binance(str(entry[0]), str(entry[1]))
		else:
			stocks.append(entry)
	if stocks.is_empty():
		return
	_current_symbols = stocks
	if not _session_ready:
		await _bootstrap_session()
	for entry in stocks:
		_fetch_quote(str(entry[0]), str(entry[1]))


## Returns [[asset, symbol, kind], ...] sorted by symbol. Only asset types
## with a reliable remote source are included (options/custom are skipped).
func _collect_symbols() -> Array:
	var seen := {}
	for t in TradeManager.trades:
		var asset := str(t.get("asset", "")).to_upper().strip_edges()
		if asset.is_empty() or seen.has(asset):
			continue
		var symbol := ""
		var kind := "stock"
		match str(t.get("asset_type", "stock")):
			"crypto":
				symbol = "%sUSDT" % asset
				kind = "crypto"
			"stock":
				symbol = asset
		if not symbol.is_empty():
			seen[asset] = [asset, symbol, kind]
	var entries: Array = []
	for asset in seen:
		entries.append(seen[asset])
	entries.sort_custom(func(a, b): return str(a[1]) < str(b[1]))
	entries.resize(mini(entries.size(), MAX_SYMBOLS_PER_REFRESH))
	return entries


# --- Yahoo (stocks) ----------------------------------------------------------


func _fetch_quote(asset: String, symbol: String) -> void:
	if _pending.has(asset):
		return
	_pending[asset] = true
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_S
	add_child(http)
	http.request_completed.connect(_on_quote_response.bind(asset, http))
	var url := CHART_URL % symbol
	if not _crumb.is_empty():
		url += "&crumb=" + _crumb.uri_encode()
	var err := http.request(url, _cookie_headers())
	if err != OK:
		push_warning("YFinance: could not start request for %s (%d)" % [symbol, err])
		_release_request(asset, http)


func _on_quote_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, asset: String, http: HTTPRequest) -> void:
	var quote := {}
	if result == HTTPRequest.RESULT_SUCCESS and code == HTTPClient.RESPONSE_OK:
		quote = _parse_quote(body)
		if float(quote.get("price", 0.0)) <= 0.0:
			push_warning("YFinance: no price in response for %s" % asset)
		else:
			_succeeded += 1
	else:
		push_warning("YFinance: request failed for %s (result=%d, http=%d)" % [asset, result, code])
	if not quote.is_empty():
		MarketSimulator.apply_live_quote(asset, float(quote["price"]),
				float(quote.get("prev_close", 0.0)))
	_release_request(asset, http)


# --- Binance (crypto) --------------------------------------------------------


func _fetch_binance(asset: String, symbol: String) -> void:
	if _pending.has(asset):
		return
	_pending[asset] = true
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_S
	add_child(http)
	http.request_completed.connect(_on_binance_response.bind(asset, http))
	var err := http.request(BINANCE_TICKER_URL % symbol)
	if err != OK:
		push_warning("Binance: could not start request for %s (%d)" % [symbol, err])
		_release_request(asset, http)


func _on_binance_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, asset: String, http: HTTPRequest) -> void:
	var quote := {}
	if result == HTTPRequest.RESULT_SUCCESS and code == HTTPClient.RESPONSE_OK:
		var data: Variant = JSON.parse_string(body.get_string_from_utf8())
		if typeof(data) == TYPE_DICTIONARY:
			var price := str(data.get("lastPrice", "")).to_float()
			var prev := str(data.get("prevClosePrice", "")).to_float()
			if price > 0.0:
				quote = {"price": price, "prev_close": prev}
				_succeeded += 1
	if not quote.is_empty():
		MarketSimulator.apply_live_quote(asset, float(quote["price"]),
				float(quote.get("prev_close", 0.0)))
	else:
		push_warning("Binance: request failed for %s (result=%d, http=%d)" % [asset, result, code])
	_release_request(asset, http)


# --- Live FX rates (hourly) --------------------------------------------------


## Refreshes USD→currency factors from Yahoo "XXXUSD=X" pairs and reapplies
## the active conversion. Falls back to Utils.USD_RATES until data arrives.
func _refresh_fx() -> void:
	if _fx_busy:
		return
	var codes: Array = []
	for code in Utils.CURRENCIES.keys():
		if str(code) != "USD":
			codes.append(str(code))
	if codes.is_empty():
		return
	codes.sort()
	_fx_busy = true
	_fx_remaining = codes.size()
	if not _session_ready:
		await _bootstrap_session()
	for code in codes:
		_fetch_fx(str(code))


func _fetch_fx(code: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_S
	add_child(http)
	http.request_completed.connect(_on_fx_response.bind(code, http))
	var url := CHART_URL % ("%sUSD=X" % code)
	if not _crumb.is_empty():
		url += "&crumb=" + _crumb.uri_encode()
	var err := http.request(url, _cookie_headers())
	if err != OK:
		push_warning("YFinance: FX request could not start for %s (%d)" % [code, err])
		_finish_fx()


func _on_fx_response(result: int, code_http: int, _headers: PackedStringArray,
		body: PackedByteArray, code: String, http: HTTPRequest) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code_http == HTTPClient.RESPONSE_OK:
		var quote := _parse_quote(body)
		var usd_per := float(quote.get("price", 0.0))
		if usd_per > 0.0:
			_fx_pairs[code] = usd_per
			_apply_fx()
		else:
			push_warning("YFinance: no FX price in response for %s" % code)
	else:
		push_warning("YFinance: FX request failed for %s (result=%d, http=%d)" % [code, result, code_http])
	http.queue_free()
	_finish_fx()


func _finish_fx() -> void:
	_fx_remaining -= 1
	if _fx_remaining <= 0:
		_fx_busy = false


## Recomputes the active conversion factor from the freshest cached pairs.
func _apply_fx() -> void:
	var code := str(TradeManager.settings.get("currency", "USD"))
	if code == "USD":
		Utils.currency_rate = 1.0
	elif _fx_pairs.has(code) and float(_fx_pairs[code]) > 0.0:
		Utils.currency_rate = 1.0 / float(_fx_pairs[code])


# --- Cycle bookkeeping -------------------------------------------------------


func _release_request(asset: String, http: HTTPRequest) -> void:
	_pending.erase(asset)
	http.queue_free()
	if not _pending.is_empty():
		return
	_refreshing = false
	# Every Yahoo symbol of the cycle was refused: rebuild session once, retry.
	if _succeeded == 0 and not _cycle_retried and not _current_symbols.is_empty():
		_cycle_retried = true
		_reset_session()
		_retry_cycle()
		return
	if _queued:
		_queued = false
		request_refresh()


func _retry_cycle() -> void:
	await _bootstrap_session()
	_refreshing = true
	for entry in _current_symbols:
		_fetch_quote(str(entry[0]), str(entry[1]))


# --- Yahoo session (cookies + crumb) -----------------------------------------


func _reset_session() -> void:
	_cookie_pairs.clear()
	_crumb = ""
	_session_ready = false


func _cookie_headers() -> PackedStringArray:
	if _cookie_pairs.is_empty():
		return PackedStringArray()
	var parts: Array = []
	for key in _cookie_pairs:
		parts.append(_cookie_pairs[key])
	return PackedStringArray(["Cookie: " + "; ".join(parts)])


## Grabs Yahoo cookies off the homepage, then exchanges them for a crumb.
func _bootstrap_session() -> void:
	if _session_ready or _bootstrapping:
		return
	_bootstrapping = true

	var seed := HTTPRequest.new()
	seed.timeout = REQUEST_TIMEOUT_S
	add_child(seed)
	var err0 := seed.request(COOKIE_SEED_URL)
	if err0 != OK:
		seed.queue_free()
		push_warning("YFinance: cookie seed request could not start (%d)" % err0)
	else:
		var res: Array = await seed.request_completed
		seed.queue_free()
		if res[0] == HTTPRequest.RESULT_SUCCESS:
			_absorb_cookies(res[2])

	var crumb_req := HTTPRequest.new()
	crumb_req.timeout = REQUEST_TIMEOUT_S
	add_child(crumb_req)
	var err := crumb_req.request(CRUMB_URL, _cookie_headers())
	if err != OK:
		crumb_req.queue_free()
		_bootstrapping = false
		_session_ready = true   # proceed cookie-less rather than stalling
		push_warning("YFinance: crumb request could not start (%d)" % err)
		return
	var res2: Array = await crumb_req.request_completed
	crumb_req.queue_free()
	if res2[0] == HTTPRequest.RESULT_SUCCESS and int(res2[1]) == HTTPClient.RESPONSE_OK:
		var crumb := PackedByteArray(res2[3]).get_string_from_utf8().strip_edges()
		if not crumb.is_empty() and crumb.length() <= 48 and not crumb.contains(" "):
			_crumb = crumb
	_session_ready = true
	_bootstrapping = false


func _absorb_cookies(headers: PackedStringArray) -> void:
	for header in headers:
		if not header.to_lower().begins_with("set-cookie:"):
			continue
		var pair := header.substr(11).strip_edges().split(";")[0].strip_edges()
		if pair.is_empty() or not pair.contains("="):
			continue
		_cookie_pairs[pair.split("=")[0]] = pair


## Extracts {"price": float, "prev_close": float} from a chart payload.
func _parse_quote(body: PackedByteArray) -> Dictionary:
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	var chart: Variant = data.get("chart")
	if typeof(chart) != TYPE_DICTIONARY:
		return {}
	var results: Variant = chart.get("result")
	if typeof(results) != TYPE_ARRAY or results.is_empty() \
			or typeof(results[0]) != TYPE_DICTIONARY:
		return {}
	var meta: Variant = results[0].get("meta")
	if typeof(meta) != TYPE_DICTIONARY:
		return {}
	var prev := float(meta.get("chartPreviousClose",
			float(meta.get("previousClose", 0.0))))
	return {"price": float(meta.get("regularMarketPrice", 0.0)), "prev_close": prev}
