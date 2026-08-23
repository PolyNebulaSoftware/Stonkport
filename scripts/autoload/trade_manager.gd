extends Node
## Autoload: owns the trade journal (trades + settings), recomputes trade
## state from logs, persists to user:// (localStorage on the web) and
## migrates legacy v1 portfolio data on first run.

signal trades_changed
signal settings_changed

const SAVE_PATH := "user://trades.json"
const LS_KEY := "stonkport_trades_v2"
const SAVE_VERSION := 2
const LEGACY_PATH := "user://portfolio.json"
const LEGACY_LS_KEY := "stonkport_portfolio_v1"

const ACTIONS := ["open", "add", "reduce", "close"]
const ENTRY_ACTIONS := ["open", "add"]
const EXIT_ACTIONS := ["reduce", "close"]
const ASSET_TYPES := ["stock", "crypto", "custom", "option"]
const EPSILON := 0.0000001

var trades: Array = []
var settings: Dictionary = {"currency": "USD"}


func _ready() -> void:
	_load_or_migrate()
	_sync_currency_symbol()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save()


# --- Queries -----------------------------------------------------------------


func get_trade(id: String) -> Dictionary:
	for t in trades:
		if str(t.get("id", "")) == id:
			return t
	return {}


## Mark price for an open trade: live simulator price when the asset is
## known, otherwise the last logged price (custom assets).
func get_mark_price(trade: Dictionary) -> float:
	var live := MarketSimulator.get_price(str(trade.get("asset", "")))
	if live > 0.0:
		return live
	var logs: Array = trade.get("logs", [])
	return float(logs[-1].get("price", 0.0)) if not logs.is_empty() else 0.0


func remaining_quantity(trade: Dictionary) -> float:
	var net := 0.0
	for log in trade.get("logs", []):
		var qty := float(log.get("qty", 0.0))
		net += qty if str(log.get("action", "")) in ENTRY_ACTIONS else -qty
	return maxf(net, 0.0)


# --- Mutations ---------------------------------------------------------------
## All return "" on success or a user-facing error message.


func create_trade(asset: String, asset_type: String, direction: String, qty: float, price: float, fee: float, opened_at: int, notes := "") -> String:
	asset = asset.strip_edges().to_upper()
	if asset.is_empty():
		return "Asset identifier is required."
	if not asset_type in ASSET_TYPES:
		return "Unknown asset type."
	if not direction in ["long", "short"]:
		return "Unknown direction."
	if qty <= 0.0:
		return "Quantity must be positive."
	if price <= 0.0:
		return "Price must be positive."
	if fee < 0.0:
		return "Fee cannot be negative."
	if opened_at <= 0:
		return "Opening date is invalid."
	var trade := {
		"id": _new_id(),
		"asset": asset,
		"asset_type": asset_type,
		"direction": direction,
		"state": "open",
		"opened_at": opened_at,
		"closed_at": 0,
		"notes": notes,
		"logs": [{"ts": opened_at, "action": "open", "qty": qty, "price": price, "fee": fee}],
	}
	trades.append(trade)
	save()
	trades_changed.emit()
	return ""


func append_log(id: String, action: String, qty: float, price: float, fee: float, ts: int) -> String:
	if not action in ACTIONS:
		return "Unknown log action."
	if qty <= 0.0:
		return "Quantity must be positive."
	if price <= 0.0:
		return "Price must be positive."
	if fee < 0.0:
		return "Fee cannot be negative."
	if ts <= 0:
		return "Date is invalid."
	var t := get_trade(id)
	if t.is_empty():
		return "Trade not found."
	if str(t.get("state", "")) == "closed" and action in EXIT_ACTIONS:
		return "Trade is already closed."
	if action in EXIT_ACTIONS:
		var remaining := remaining_quantity(t)
		if remaining - qty < -EPSILON:
			return "Quantity exceeds the open size (%s)." % Utils.qty(remaining)
	var logs: Array = t.get("logs", [])
	logs.append({"ts": ts, "action": action, "qty": qty, "price": price, "fee": fee})
	logs.sort_custom(func(a, b): return int(a.get("ts", 0)) < int(b.get("ts", 0)))
	_refresh_state(t)
	save()
	trades_changed.emit()
	return ""


func remove_log(id: String, index: int) -> String:
	var t := get_trade(id)
	if t.is_empty():
		return "Trade not found."
	var logs: Array = t.get("logs", [])
	if index < 0 or index >= logs.size():
		return "Log entry not found."
	if logs.size() == 1:
		return "Cannot remove the only log of a trade."
	logs.remove_at(index)
	_refresh_state(t)
	save()
	trades_changed.emit()
	return ""


func update_meta(id: String, asset: String, asset_type: String, direction: String, notes: String) -> String:
	asset = asset.strip_edges().to_upper()
	if asset.is_empty():
		return "Asset identifier is required."
	if not asset_type in ASSET_TYPES:
		return "Unknown asset type."
	if not direction in ["long", "short"]:
		return "Unknown direction."
	var t := get_trade(id)
	if t.is_empty():
		return "Trade not found."
	t["asset"] = asset
	t["asset_type"] = asset_type
	t["direction"] = direction
	t["notes"] = notes
	save()
	trades_changed.emit()
	return ""


func delete_trade(id: String) -> String:
	var t := get_trade(id)
	if t.is_empty():
		return "Trade not found."
	trades.erase(t)
	save()
	trades_changed.emit()
	return ""


## Appends a close log covering the whole remaining quantity.
func close_remaining(id: String, price: float, fee: float, ts: int) -> String:
	var t := get_trade(id)
	if t.is_empty():
		return "Trade not found."
	var remaining := remaining_quantity(t)
	if remaining <= EPSILON:
		return "Trade is already closed."
	return append_log(id, "close", remaining, price, fee, ts)


## Bulk import used by CSV import. Deduplicates by id when merging.
## Returns {"imported": int, "skipped": int}.
func import_trades(list: Array, replace := false) -> Dictionary:
	var imported := 0
	var skipped := 0
	if replace:
		trades = []
	for t in list:
		# Derive state/dates from logs first so validation sees them.
		_refresh_state(t)
		var id := str(t.get("id", ""))
		if not id.is_empty() and not get_trade(id).is_empty():
			skipped += 1
			continue
		if str(t.get("asset", "")).is_empty() or int(t.get("opened_at", 0)) <= 0:
			skipped += 1
			continue
		if id.is_empty():
			t["id"] = _new_id()
		trades.append(t)
		imported += 1
	if imported > 0:
		save()
		trades_changed.emit()
	return {"imported": imported, "skipped": skipped}


func set_currency(code: String) -> void:
	if not Utils.CURRENCIES.has(code):
		return
	settings["currency"] = code
	_sync_currency_symbol()
	save()
	settings_changed.emit()


func _sync_currency_symbol() -> void:
	Utils.currency_symbol = Utils.CURRENCIES.get(str(settings.get("currency", "USD")), "$")


## Recomputes state/opened_at/closed_at from the log list.
func _refresh_state(t: Dictionary) -> void:
	var logs: Array = t.get("logs", [])
	if logs.is_empty():
		t["state"] = "open"
		t["opened_at"] = 0
		t["closed_at"] = 0
		return
	logs.sort_custom(func(a, b): return int(a.get("ts", 0)) < int(b.get("ts", 0)))
	t["opened_at"] = int(logs[0].get("ts", 0))
	var net := 0.0
	var last_exit := 0
	for log in logs:
		var qty := float(log.get("qty", 0.0))
		if str(log.get("action", "")) in ENTRY_ACTIONS:
			net += qty
		else:
			net -= qty
			last_exit = int(log.get("ts", 0))
	if net <= EPSILON:
		t["state"] = "closed"
		t["closed_at"] = last_exit
	else:
		t["state"] = "open"
		t["closed_at"] = 0


func _new_id() -> String:
	return "trd_%d_%06d" % [int(Time.get_unix_time_from_system()), randi() % 1000000]


# --- Persistence -------------------------------------------------------------


func save() -> void:
	var data := {"version": SAVE_VERSION, "trades": trades, "settings": settings}
	var text := JSON.stringify(data)
	if _write_file(text):
		return
	if _write_local_storage(text):
		return
	push_warning("TradeManager: could not persist journal state.")


func _write_file(text: String) -> bool:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.flush()
	f.close()
	return true


func _write_local_storage(text: String) -> bool:
	if not OS.has_feature("web"):
		return false
	var storage: Variant = JavaScriptBridge.get_interface("localStorage")
	if storage == null:
		return false
	storage.setItem(LS_KEY, text)
	return true


func _read_local_storage(key: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var storage: Variant = JavaScriptBridge.get_interface("localStorage")
	if storage == null:
		return ""
	var value: Variant = storage.getItem(key)
	return value if typeof(value) == TYPE_STRING else ""


func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _load_or_migrate() -> void:
	var text := _read_file(SAVE_PATH)
	if text.is_empty():
		text = _read_local_storage(LS_KEY)
	var data: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if typeof(data) == TYPE_DICTIONARY and int(data.get("version", 0)) == SAVE_VERSION:
		_hydrate(data)
		trades_changed.emit()
		return
	if _migrate_legacy():
		save()
		trades_changed.emit()
		return
	_seed_demo()
	save()
	trades_changed.emit()


func _hydrate(data: Dictionary) -> void:
	trades = []
	var raw: Variant = data.get("trades", [])
	if typeof(raw) == TYPE_ARRAY:
		for t in raw:
			if typeof(t) == TYPE_DICTIONARY and not str(t.get("id", "")).is_empty():
				_refresh_state(t)
				trades.append(t)
	settings = {"currency": "USD"}
	var raw_settings: Variant = data.get("settings", {})
	if typeof(raw_settings) == TYPE_DICTIONARY:
		settings.merge(raw_settings, true)


## One-time conversion of v1 holdings/transactions into trades.
func _migrate_legacy() -> bool:
	var text := _read_file(LEGACY_PATH)
	if text.is_empty():
		text = _read_local_storage(LEGACY_LS_KEY)
	if text.is_empty():
		return false
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return false

	var by_asset := {}
	var raw_txns: Variant = data.get("transactions", [])
	if typeof(raw_txns) == TYPE_ARRAY:
		var txns: Array = raw_txns.duplicate()
		txns.sort_custom(func(a, b): return int(a.get("timestamp", 0)) < int(b.get("timestamp", 0)))
		for txn in txns:
			var asset := str(txn.get("ticker", "")).to_upper()
			if asset.is_empty():
				continue
			var bucket: Array = by_asset.get_or_add(asset, [])
			bucket.append(txn)
	var raw_holdings: Variant = data.get("holdings", {})
	if typeof(raw_holdings) == TYPE_DICTIONARY:
		var now := int(Time.get_unix_time_from_system())
		for ticker in raw_holdings:
			var h: Variant = raw_holdings[ticker]
			if typeof(h) == TYPE_DICTIONARY and float(h.get("shares", 0.0)) > 0.0 \
					and not by_asset.has(str(ticker)):
				by_asset[str(ticker)] = [{
					"type": "buy",
					"shares": float(h.get("shares", 0.0)),
					"price": float(h.get("avg_cost", 0.0)),
					"timestamp": now - 7 * 86400,
				}]
	if by_asset.is_empty():
		return false

	var legacy_settings: Variant = data.get("settings", {})
	var currency := "USD"
	if typeof(legacy_settings) == TYPE_DICTIONARY:
		currency = str(legacy_settings.get("currency", "USD"))
	settings = {"currency": currency if Utils.CURRENCIES.has(currency) else "USD"}

	trades = []
	for asset in by_asset:
		var logs: Array = []
		for txn in by_asset[asset]:
			var is_buy := str(txn.get("type", "")) == "buy"
			if logs.is_empty() and not is_buy:
				continue
			var action := "add" if is_buy else "close"
			if is_buy and logs.is_empty():
				action = "open"
			logs.append({
				"ts": int(txn.get("timestamp", 0)),
				"action": action,
				"qty": absf(float(txn.get("shares", 0.0))),
				"price": float(txn.get("price", 0.0)),
				"fee": 0.0,
			})
		if logs.is_empty():
			continue
		var trade := {
			"id": _new_id(),
			"asset": str(asset),
			"asset_type": _guess_asset_type(str(asset)),
			"direction": "long",
			"state": "open",
			"opened_at": 0,
			"closed_at": 0,
			"notes": "Migrated from v1 portfolio.",
			"logs": logs,
		}
		_refresh_state(trade)
		trades.append(trade)
	return not trades.is_empty()


func _guess_asset_type(asset: String) -> String:
	var crypto := ["BTC", "ETH", "SOL", "XRP", "DOGE", "ADA", "LTC", "BCH", "DOT", "AVAX"]
	if asset in crypto:
		return "crypto"
	return "stock"


func _seed_demo() -> void:
	trades = []
	settings = {"currency": "USD"}
	var now := int(Time.get_unix_time_from_system())
	var d := func(days: int) -> int: return now - days * 86400
	var demo := [
		["AAPL", "stock", "long", [
			[d.call(92), "open", 10.0, 168.50, 1.0],
			[d.call(84), "add", 5.0, 172.30, 1.0],
			[d.call(61), "close", 15.0, 189.75, 1.5],
		], "Swing trade on earnings momentum."],
		["MSFT", "stock", "long", [
			[d.call(78), "open", 4.0, 412.20, 1.0],
			[d.call(57), "close", 4.0, 397.10, 1.0],
		], "Stopped out."],
		["NVDA", "stock", "long", [
			[d.call(41), "open", 20.0, 118.40, 1.0],
			[d.call(29), "add", 10.0, 124.10, 1.0],
		], "Core position, adding on dips."],
		["BTC", "crypto", "long", [
			[d.call(71), "open", 0.5, 58200.0, 8.0],
			[d.call(21), "close", 0.5, 63450.0, 8.0],
		], ""],
		["ETH", "crypto", "short", [
			[d.call(66), "open", 4.0, 3115.0, 6.0],
			[d.call(44), "close", 4.0, 3248.0, 6.0],
		], "Short into resistance."],
		["TSLA", "stock", "long", [
			[d.call(33), "open", 12.0, 243.80, 1.0],
			[d.call(9), "close", 12.0, 261.40, 1.0],
		], ""],
		["AMD", "stock", "long", [
			[d.call(27), "open", 15.0, 157.90, 1.0],
			[d.call(4), "close", 15.0, 150.25, 1.0],
		], "Failed breakout."],
		["GLD", "custom", "long", [
			[d.call(16), "open", 3.0, 2312.50, 0.0],
		], "Manual price tracking."],
		["AMZN", "stock", "long", [
			[d.call(52), "open", 8.0, 182.90, 1.0],
			[d.call(2), "close", 8.0, 197.35, 1.0],
		], ""],
	]
	for row in demo:
		trades.append(_make_trade(row[0], row[1], row[2], row[3], row[4]))


func _make_trade(asset: String, asset_type: String, direction: String, rows: Array, notes := "") -> Dictionary:
	var logs: Array = []
	for r in rows:
		logs.append({"ts": int(r[0]), "action": str(r[1]), "qty": float(r[2]), "price": float(r[3]), "fee": float(r[4])})
	logs.sort_custom(func(a, b): return int(a.get("ts", 0)) < int(b.get("ts", 0)))
	var trade := {
		"id": _new_id(),
		"asset": asset,
		"asset_type": asset_type,
		"direction": direction,
		"state": "open",
		"opened_at": int(logs[0].get("ts", 0)),
		"closed_at": 0,
		"notes": notes,
		"logs": logs,
	}
	_refresh_state(trade)
	return trade
