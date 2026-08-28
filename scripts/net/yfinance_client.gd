extends Node
## Autoload: fetches live quotes and re-anchors MarketSimulator prices.
## Stocks come from Yahoo Finance's chart endpoint (the same public API the
## yfinance library wraps; cookies + crumb session bootstrapped like
## yfinance does, with one session-rebuild retry per refused cycle).
## Crypto comes from Binance's public data API (data-api.binance.vision).
## Web builds cannot reach Yahoo directly (no CORS headers, no cookie
## access), so there requests are relayed: first through the tray launcher's
## same-origin /__proxy endpoint when it serves this build, else through
## public CORS proxies against Yahoo's batched "spark" endpoint, rotating
## transports whenever a whole cycle is refused.
## Fetches happen once on load and whenever TradeManager emits a save;
## overlapping refreshes coalesce into one.

const WebServerScript := preload("res://scripts/tray/local_web_server.gd")

const CHART_URL := "https://query1.finance.yahoo.com/v8/finance/chart/%s?interval=1d&range=1d"
const CRUMB_URL := "https://query1.finance.yahoo.com/v1/test/getcrumb"
const COOKIE_SEED_URL := "https://finance.yahoo.com/"
const BINANCE_TICKER_URL := "https://data-api.binance.vision/api/v3/ticker/24hr?symbol=%s"
# Web-only plumbing: browsers block query1.finance.yahoo.com (no CORS
# headers) and hide Set-Cookie, so requests are relayed instead of hitting
# the chart API per symbol. The tray launcher's same-origin relay is probed
# first; public CORS proxies are the fallback, rotating whenever an entire
# cycle comes back refused.
const WEB_SPARK_URL := "https://query1.finance.yahoo.com/v8/finance/spark?symbols=%s&range=1d&interval=1d"
const CORS_PROXIES := [
	"https://api.allorigins.win/raw?url=%s",
	"https://api.codetabs.com/v1/proxy/?quest=%s",
	"https://corsproxy.io/?url=%s",
]
const WEB_SYMBOLS_PER_BATCH := 10
const WEB_STAGGER_SEC := 0.4
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

var _is_web := OS.has_feature("web")
var _proxy_index := 0     # active transport entry (web builds only)
var _web_proxies: Array = []      # transport templates: launcher relay first, then CORS_PROXIES
var _web_proxies_ready := false
var _web_proxies_busy := false


func _ready() -> void:
	TradeManager.trades_changed.connect(request_refresh)
	TradeManager.settings_changed.connect(_apply_fx)
	if _is_web:
		_init_web_proxies()   # async: probes the launcher relay, then fills the list
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
		_refreshing = false
		return
	_current_symbols = stocks
	if _is_web:
		await _ensure_web_proxies()
	if not _session_ready:
		await _bootstrap_session()
	_fetch_stocks(stocks)


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


# --- Web stock batches (CORS-proxied spark) ----------------------------------


## Fires quote requests for stock entries: batched spark calls relayed
## through the active CORS proxy on the web, one chart request per symbol
## elsewhere.
func _fetch_stocks(stocks: Array) -> void:
	if not _is_web:
		for entry in stocks:
			_fetch_quote(str(entry[0]), str(entry[1]))
		return
	var batch: Array = []
	for entry in stocks:
		batch.append(entry)
		if batch.size() < WEB_SYMBOLS_PER_BATCH:
			continue
		_fetch_spark_batch(batch)
		batch = []
		await get_tree().create_timer(WEB_STAGGER_SEC).timeout
	if not batch.is_empty():
		_fetch_spark_batch(batch)


## Requests one spark payload covering every symbol in [param batch].
func _fetch_spark_batch(batch: Array) -> void:
	var symbols := PackedStringArray()
	for entry in batch:
		_pending[str(entry[0])] = true
		if not symbols.has(str(entry[1])):
			symbols.append(str(entry[1]))
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_S
	add_child(http)
	http.request_completed.connect(_on_spark_batch_response.bind(batch.duplicate(), http))
	var err := http.request(_proxied(WEB_SPARK_URL % ",".join(symbols)))
	if err != OK:
		push_warning("YFinance: could not start spark request (%d)" % err)
		for entry in batch:
			_release_request(str(entry[0]), http)


func _on_spark_batch_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, batch: Array, http: HTTPRequest) -> void:
	var quotes := {}
	if result == HTTPRequest.RESULT_SUCCESS and code == HTTPClient.RESPONSE_OK:
		quotes = _parse_spark(body)
	else:
		push_warning("YFinance: spark request failed (result=%d, http=%d)" % [result, code])
	var missing: Array = []
	for entry in batch:
		var asset := str(entry[0])
		var quote: Dictionary = quotes.get(str(entry[1]), {})
		if float(quote.get("price", 0.0)) > 0.0:
			_succeeded += 1
			MarketSimulator.apply_live_quote(asset, float(quote["price"]),
					float(quote.get("prev_close", 0.0)))
		else:
			missing.append(str(entry[1]))
		_release_request(asset, http)
	if not missing.is_empty():
		push_warning("YFinance: no price in response for %s" % ", ".join(missing))


## Extracts {symbol: {"price", "prev_close"}} from a spark payload, which is
## a flat {SYMBOL: {...}} map whose entries end in a "close" series.
func _parse_spark(body: PackedByteArray) -> Dictionary:
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	var quotes := {}
	for symbol in data:
		var entry: Variant = data[symbol]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var closes: Variant = entry.get("close")
		if typeof(closes) != TYPE_ARRAY or closes.is_empty():
			continue
		var last: Variant = closes[closes.size() - 1]
		if typeof(last) != TYPE_FLOAT and typeof(last) != TYPE_INT:
			continue
		var prev: Variant = entry.get("chartPreviousClose",
				entry.get("previousClose", 0.0))
		quotes[str(symbol)] = {"price": float(last), "prev_close": float(prev)}
	return quotes


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
	if _is_web:
		await _ensure_web_proxies()
	if not _session_ready:
		await _bootstrap_session()
	for i in codes.size():
		_fetch_fx(str(codes[i]))
		if _is_web and i < codes.size() - 1:
			await get_tree().create_timer(WEB_STAGGER_SEC).timeout


func _fetch_fx(code: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_S
	add_child(http)
	http.request_completed.connect(_on_fx_response.bind(code, http))
	var url := CHART_URL % ("%sUSD=X" % code)
	if not _crumb.is_empty():
		url += "&crumb=" + _crumb.uri_encode()
	var err := http.request(_proxied(url), _cookie_headers())
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


# --- Transport helpers -------------------------------------------------------


## Returns [param url] unchanged off-web; on web relays it through the
## currently active transport (launcher relay or public CORS proxy).
func _proxied(url: String) -> String:
	if not _is_web:
		return url
	if not _web_proxies_ready:
		return CORS_PROXIES[0] % url.uri_encode()
	return str(_web_proxies[_proxy_index % _web_proxies.size()]) % url.uri_encode()


## Shared transport entry for other Yahoo consumers (the Analyze screen's
## ticker search): routes [param url] through the web relay/proxy chain,
## unchanged off-web. Awaitable so first use waits for the relay probe.
func proxied_url(url: String) -> String:
	if _is_web:
		await _ensure_web_proxies()
	return _proxied(url)


## Builds the web transport list once: the tray launcher's same-origin relay
## first when this build is really served by it (ping check), then the public
## CORS proxies as fallback for remotely hosted builds.
func _init_web_proxies() -> void:
	if _web_proxies_ready or _web_proxies_busy:
		return
	_web_proxies_busy = true
	var origin := str(JavaScriptBridge.eval("window.location.origin", true))
	if origin.begins_with("http") and await _probe_relay(origin):
		_web_proxies.append("%s/%s?url=%%s" % [origin, WebServerScript.RELAY_PATH])
	_web_proxies.append_array(CORS_PROXIES)
	_web_proxies_busy = false
	_web_proxies_ready = true


## True only when [param origin] answers the launcher ping, i.e. this build is
## served by our own tray launcher and its /__proxy relay is next door.
func _probe_relay(origin: String) -> bool:
	var http := HTTPRequest.new()
	http.timeout = 2.0
	add_child(http)
	var err := http.request("%s/%s" % [origin, WebServerScript.LAUNCHER_PING_PATH])
	if err != OK:
		http.queue_free()
		return false
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS:
		return false
	return PackedByteArray(res[3]).get_string_from_ascii() == WebServerScript.LAUNCHER_PING_BODY


## Blocks until _init_web_proxies() has finished (a few frames at most).
func _ensure_web_proxies() -> void:
	while not _web_proxies_ready:
		await get_tree().process_frame


# --- Cycle bookkeeping -------------------------------------------------------


func _release_request(asset: String, http: HTTPRequest) -> void:
	_pending.erase(asset)
	http.queue_free()
	if not _pending.is_empty():
		return
	_refreshing = false
	# Every Yahoo symbol of the cycle was refused: rebuild the session once
	# (desktop) or rotate to the next transport (web), then retry the cycle.
	if _succeeded == 0 and not _cycle_retried and not _current_symbols.is_empty():
		_cycle_retried = true
		if _is_web:
			_proxy_index += 1
		else:
			_reset_session()
		_retry_cycle()
		return
	if _queued:
		_queued = false
		request_refresh()


func _retry_cycle() -> void:
	await _bootstrap_session()
	_refreshing = true
	_fetch_stocks(_current_symbols)


# --- Yahoo session (cookies + crumb) -----------------------------------------


func _reset_session() -> void:
	_cookie_pairs.clear()
	_crumb = ""
	_session_ready = false


func _cookie_headers() -> PackedStringArray:
	# Browsers forbid setting Cookie on cross-origin requests.
	if _is_web or _cookie_pairs.is_empty():
		return PackedStringArray()
	var parts: Array = []
	for key in _cookie_pairs:
		parts.append(_cookie_pairs[key])
	return PackedStringArray(["Cookie: " + "; ".join(parts)])


## Grabs Yahoo cookies off the homepage, then exchanges them for a crumb.
func _bootstrap_session() -> void:
	if _is_web:
		_session_ready = true   # cookies/crumbs are unreachable from a browser
		return
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
	return _quote_from_meta(meta)


## Builds {"price", "prev_close"} from a chart/spark meta object.
func _quote_from_meta(meta: Dictionary) -> Dictionary:
	var prev := float(meta.get("chartPreviousClose",
			float(meta.get("previousClose", 0.0))))
	return {"price": float(meta.get("regularMarketPrice", 0.0)), "prev_close": prev}
