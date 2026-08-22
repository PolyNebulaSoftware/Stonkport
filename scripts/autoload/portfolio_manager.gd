extends Node
## Autoload: owns portfolio state (cash, holdings, transactions, watchlist,
## settings), computes derived metrics, and persists to user:// (IndexedDB on
## the web) with a localStorage fallback.

signal portfolio_changed
signal settings_changed

const SAVE_PATH := "user://portfolio.json"
const LS_KEY := "localstoport_portfolio_v1"
const SAVE_VERSION := 1
const DEMO_CASH := 5000.0
const MAX_TRANSACTIONS := 500

var cash := 0.0
var holdings: Dictionary = {}  # ticker -> {shares: float, avg_cost: float}
var transactions: Array = []   # newest-first {id, ticker, type, shares, price, timestamp}
var watchlist: Array = []
var settings: Dictionary = {"refresh_interval_s": 5.0, "currency": "USD"}


func _ready() -> void:
	_load_or_seed()
	MarketSimulator.set_refresh_interval(float(settings.get("refresh_interval_s", 5.0)))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save()


# --- Mutations --------------------------------------------------------------


## Returns "" on success or a user-facing error message.
func buy(ticker: String, shares: float, price: float) -> String:
	shares = floorf(shares)
	if shares <= 0.0:
		return "Shares must be a positive number."
	if price <= 0.0:
		return "Price must be a positive number."
	var cost := shares * price
	if cost > cash + 0.005:
		return "Insufficient cash: %s needed, %s available." % [Utils.money(cost), Utils.money(cash)]
	cash -= cost
	var h: Dictionary = holdings.get(ticker, {"shares": 0.0, "avg_cost": 0.0})
	var new_shares: float = float(h["shares"]) + shares
	var new_avg := price
	if new_shares > 0.0:
		new_avg = (float(h["avg_cost"]) * float(h["shares"]) + cost) / new_shares
	holdings[ticker] = {"shares": new_shares, "avg_cost": new_avg}
	_record_transaction(ticker, "buy", shares, price)
	save()
	portfolio_changed.emit()
	return ""


## Returns "" on success or a user-facing error message.
func sell(ticker: String, shares: float, price: float) -> String:
	shares = floorf(shares)
	if shares <= 0.0:
		return "Shares must be a positive number."
	if price <= 0.0:
		return "Price must be a positive number."
	if not holdings.has(ticker):
		return "No position in %s." % ticker
	var held: float = float(holdings[ticker]["shares"])
	if shares > held + 0.0001:
		return "Cannot sell more than held (%d shares)." % int(held)
	cash += shares * price
	var remaining := held - shares
	if remaining <= 0.0001:
		holdings.erase(ticker)
	else:
		holdings[ticker]["shares"] = remaining
	_record_transaction(ticker, "sell", shares, price)
	save()
	portfolio_changed.emit()
	return ""


## Directly sets a position (used by "Edit"); no cash movement.
func adjust_holding(ticker: String, shares: float, avg_cost: float) -> String:
	if shares < 0.0:
		return "Shares cannot be negative."
	if shares > 0.0 and avg_cost <= 0.0:
		return "Average cost must be a positive number."
	if shares <= 0.0:
		holdings.erase(ticker)
	else:
		holdings[ticker] = {"shares": shares, "avg_cost": avg_cost}
	_record_transaction(ticker, "adjust", shares, avg_cost)
	save()
	portfolio_changed.emit()
	return ""


## Sells the whole position at the current market price.
func remove_holding(ticker: String) -> String:
	if not holdings.has(ticker):
		return "No position in %s." % ticker
	var h: Dictionary = holdings[ticker]
	return sell(ticker, float(h["shares"]), MarketSimulator.get_price(ticker))


func add_to_watchlist(ticker: String) -> void:
	if ticker.is_empty() or watchlist.has(ticker):
		return
	watchlist.append(ticker)
	save()
	portfolio_changed.emit()


func remove_from_watchlist(ticker: String) -> void:
	if not watchlist.has(ticker):
		return
	watchlist.erase(ticker)
	save()
	portfolio_changed.emit()


func set_refresh_interval(seconds: float) -> void:
	settings["refresh_interval_s"] = clampf(seconds, 1.0, 3600.0)
	MarketSimulator.set_refresh_interval(seconds)
	save()
	settings_changed.emit()


func reset_demo() -> void:
	_seed_demo()
	MarketSimulator.reset_market()
	save()
	portfolio_changed.emit()


# --- Derived values (computed, never stored) --------------------------------


func get_holding(ticker: String) -> Dictionary:
	return holdings.get(ticker, {})


func get_position_value(ticker: String) -> float:
	var h: Dictionary = holdings.get(ticker, {})
	return float(h.get("shares", 0.0)) * MarketSimulator.get_price(ticker)


func get_position_pnl(ticker: String) -> float:
	var h: Dictionary = holdings.get(ticker, {})
	return (MarketSimulator.get_price(ticker) - float(h.get("avg_cost", 0.0))) * float(h.get("shares", 0.0))


func get_position_pnl_pct(ticker: String) -> float:
	var h: Dictionary = holdings.get(ticker, {})
	var cost := float(h.get("avg_cost", 0.0)) * float(h.get("shares", 0.0))
	return (get_position_pnl(ticker) / cost * 100.0) if cost > 0.0 else 0.0


func get_holdings_value() -> float:
	var total := 0.0
	for ticker in holdings:
		total += get_position_value(ticker)
	return total


func get_total_value() -> float:
	return cash + get_holdings_value()


func get_cost_basis() -> float:
	var basis := 0.0
	for ticker in holdings:
		var h: Dictionary = holdings[ticker]
		basis += float(h["shares"]) * float(h["avg_cost"])
	return basis


func get_total_pnl() -> float:
	return get_holdings_value() - get_cost_basis()


func get_total_pnl_pct() -> float:
	var basis := get_cost_basis()
	return (get_total_pnl() / basis * 100.0) if basis > 0.0 else 0.0


func get_day_change() -> float:
	var change := 0.0
	for ticker in holdings:
		var h: Dictionary = holdings[ticker]
		change += float(h["shares"]) * MarketSimulator.get_day_change(ticker)
	return change


func get_day_change_pct() -> float:
	var base := get_total_value() - get_day_change()
	return (get_day_change() / base * 100.0) if base > 0.0 else 0.0


func get_sector_allocation() -> Dictionary:
	var alloc: Dictionary = {}
	for ticker in holdings:
		var sector := str(MarketSimulator.get_stock_info(ticker).get("sector", "Other"))
		alloc[sector] = float(alloc.get(sector, 0.0)) + get_position_value(ticker)
	return alloc


func get_invested_tickers() -> Array:
	var tickers: Array = holdings.keys()
	tickers.sort()
	return tickers


# --- Persistence ------------------------------------------------------------


func save() -> void:
	var data := {
		"version": SAVE_VERSION,
		"cash": cash,
		"holdings": holdings,
		"transactions": transactions,
		"watchlist": watchlist,
		"settings": settings,
	}
	var text := JSON.stringify(data)
	if _write_file(text):
		return
	if _write_local_storage(text):
		return
	push_warning("PortfolioManager: could not persist portfolio state.")


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


func _read_local_storage() -> String:
	if not OS.has_feature("web"):
		return ""
	var storage: Variant = JavaScriptBridge.get_interface("localStorage")
	if storage == null:
		return ""
	var value: Variant = storage.getItem(LS_KEY)
	return value if typeof(value) == TYPE_STRING else ""


func _load_or_seed() -> void:
	var text := ""
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f != null:
			text = f.get_as_text()
	if text.is_empty():
		text = _read_local_storage()
	var data: Variant = null
	if not text.is_empty():
		data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or int(data.get("version", 0)) != SAVE_VERSION:
		_seed_demo()
		save()
		portfolio_changed.emit()
		return
	cash = float(data.get("cash", 0.0))
	holdings.clear()
	var raw_holdings: Variant = data.get("holdings", {})
	if typeof(raw_holdings) == TYPE_DICTIONARY:
		for ticker in raw_holdings:
			var h: Variant = raw_holdings[ticker]
			if typeof(h) == TYPE_DICTIONARY and float(h.get("shares", 0.0)) > 0.0:
				holdings[str(ticker)] = {
					"shares": float(h.get("shares", 0.0)),
					"avg_cost": float(h.get("avg_cost", 0.0)),
				}
	transactions = []
	var raw_txns: Variant = data.get("transactions", [])
	if typeof(raw_txns) == TYPE_ARRAY:
		transactions = raw_txns
	watchlist = []
	var raw_watchlist: Variant = data.get("watchlist", [])
	if typeof(raw_watchlist) == TYPE_ARRAY:
		for ticker in raw_watchlist:
			watchlist.append(str(ticker))
	settings = {"refresh_interval_s": 5.0, "currency": "USD"}
	var raw_settings: Variant = data.get("settings", {})
	if typeof(raw_settings) == TYPE_DICTIONARY:
		settings.merge(raw_settings, true)
	portfolio_changed.emit()


func _seed_demo() -> void:
	cash = DEMO_CASH
	holdings = {
		"AAPL": {"shares": 10.0, "avg_cost": 176.40},
		"MSFT": {"shares": 4.0, "avg_cost": 402.50},
		"NVDA": {"shares": 25.0, "avg_cost": 121.15},
		"JNJ": {"shares": 12.0, "avg_cost": 155.80},
	}
	watchlist = ["AAPL", "MSFT", "NVDA", "TSLA", "AMZN"]
	settings = {"refresh_interval_s": 5.0, "currency": "USD"}
	transactions = []
	var now := int(Time.get_unix_time_from_system())
	var day_offset := 4
	for ticker in holdings:
		var h: Dictionary = holdings[ticker]
		transactions.append({
			"id": "txn_%d_demo" % now,
			"ticker": ticker,
			"type": "buy",
			"shares": float(h["shares"]),
			"price": float(h["avg_cost"]),
			"timestamp": now - day_offset * 86400,
		})
		day_offset -= 1


func _record_transaction(ticker: String, type: String, shares: float, price: float) -> void:
	transactions.push_front({
		"id": "txn_%d_%06d" % [int(Time.get_unix_time_from_system()), randi() % 1000000],
		"ticker": ticker,
		"type": type,
		"shares": shares,
		"price": price,
		"timestamp": int(Time.get_unix_time_from_system()),
	})
	if transactions.size() > MAX_TRANSACTIONS:
		transactions.resize(MAX_TRANSACTIONS)
