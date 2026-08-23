class_name TradeMetrics
extends RefCounted
## Pure, side-effect-free computations over trade records.
##
## A trade matches a time range when ANY of its log timestamps falls inside
## [min_ts, max_ts]; a bound of 0 is disabled. Win/loss statistics consider
## only closed trades whose closed_at lies inside the range.

const EPSILON := 0.0000001


static func direction_sign(trade: Dictionary) -> int:
	return -1 if str(trade.get("direction", "long")) == "short" else 1


static func is_entry(action: String) -> bool:
	return action == "open" or action == "add"


static func last_activity(trade: Dictionary) -> int:
	var latest := int(trade.get("opened_at", 0))
	for log in trade.get("logs", []):
		latest = maxi(latest, int(log.get("ts", 0)))
	return latest


static func in_range(trade: Dictionary, min_ts: int, max_ts: int) -> bool:
	for log in trade.get("logs", []):
		var ts := int(log.get("ts", 0))
		if (min_ts <= 0 or ts >= min_ts) and (max_ts <= 0 or ts <= max_ts):
			return true
	return false


static func net_quantity(trade: Dictionary) -> float:
	var net := 0.0
	for log in trade.get("logs", []):
		var qty := float(log.get("qty", 0.0))
		net += qty if is_entry(str(log.get("action", ""))) else -qty
	return net


static func hold_seconds(trade: Dictionary) -> float:
	return maxf(float(int(trade.get("closed_at", 0)) - int(trade.get("opened_at", 0))), 0.0)


## Full P/L decomposition for one trade. price_provider(asset) supplies mark
## prices for open positions; when it is invalid or returns <= 0 the last log
## price is used instead.
static func breakdown(trade: Dictionary, price_provider := Callable()) -> Dictionary:
	var sign := direction_sign(trade)
	var qty_open := 0.0
	var cost_basis := 0.0
	var realized := 0.0
	var fees := 0.0
	var entry_qty := 0.0
	var entry_cost := 0.0
	var exit_qty := 0.0
	var exit_value := 0.0
	for log in trade.get("logs", []):
		var action := str(log.get("action", ""))
		var qty := float(log.get("qty", 0.0))
		var price := float(log.get("price", 0.0))
		fees += float(log.get("fee", 0.0))
		if is_entry(action):
			entry_qty += qty
			entry_cost += qty * price
			qty_open += qty
			cost_basis += qty * price
		else:
			var avg := (cost_basis / qty_open) if qty_open > EPSILON else price
			realized += sign * (price - avg) * qty
			exit_qty += qty
			exit_value += qty * price
			qty_open = maxf(qty_open - qty, 0.0)
			cost_basis = maxf(cost_basis - avg * qty, 0.0)
	var avg_entry := (cost_basis / qty_open) if qty_open > EPSILON else 0.0
	var mark := 0.0
	var unrealized := 0.0
	if qty_open > EPSILON:
		if price_provider.is_valid():
			mark = float(price_provider.call(str(trade.get("asset", ""))))
		if mark <= 0.0:
			var logs: Array = trade.get("logs", [])
			mark = float(logs[-1].get("price", 0.0)) if not logs.is_empty() else 0.0
		unrealized = sign * (mark - avg_entry) * qty_open
	var pnl := realized + unrealized - fees
	var pnl_pct := (pnl / entry_cost * 100.0) if entry_cost > EPSILON else 0.0
	return {
		"pnl": pnl,
		"pnl_pct": pnl_pct,
		"fees": fees,
		"realized": realized,
		"unrealized": unrealized,
		"entry_qty": entry_qty,
		"entry_cost": entry_cost,
		"exit_qty": exit_qty,
		"avg_exit": (exit_value / exit_qty) if exit_qty > EPSILON else 0.0,
		"avg_entry": avg_entry,
		"net_qty": qty_open,
		"mark": mark,
		"is_closed": qty_open <= EPSILON,
	}


## Aggregates every metric shown on the dashboard for the given range.
static func compute(trades: Array, min_ts := 0, max_ts := 0, price_provider := Callable()) -> Dictionary:
	var ranged: Array = []
	for t in trades:
		if in_range(t, min_ts, max_ts):
			ranged.append(t)

	var closed: Array = []
	var open_count := 0
	var per_asset := {}
	var gross_profit := 0.0
	var gross_loss := 0.0
	var wins := 0
	var losses := 0
	var win_hold := 0.0
	var loss_hold := 0.0
	var biggest_win := 0.0
	var biggest_loss := 0.0
	var net_pnl := 0.0
	var total_fees := 0.0

	for t in ranged:
		var bd := breakdown(t, price_provider)
		net_pnl += float(bd.pnl)
		total_fees += float(bd.fees)
		var asset := str(t.get("asset", "?"))
		var slot: Dictionary = per_asset.get_or_add(asset, {"asset": asset, "pnl": 0.0, "cost": 0.0, "count": 0})
		slot.pnl += float(bd.pnl)
		slot.cost += float(bd.entry_cost)
		slot.count += 1
		if bool(bd.is_closed):
			closed.append({"trade": t, "bd": bd})
			if float(bd.pnl) > 0.0:
				wins += 1
				gross_profit += float(bd.pnl)
				win_hold += hold_seconds(t)
				biggest_win = maxf(biggest_win, float(bd.pnl))
			elif float(bd.pnl) < 0.0:
				losses += 1
				gross_loss += -float(bd.pnl)
				loss_hold += hold_seconds(t)
				biggest_loss = minf(biggest_loss, float(bd.pnl))
		else:
			open_count += 1

	closed.sort_custom(func(a, b): return int(a.trade.get("closed_at", 0)) < int(b.trade.get("closed_at", 0)))

	var closed_count := closed.size()
	var decided := wins + losses
	var win_rate := (float(wins) / decided * 100.0) if decided > 0 else 0.0
	var loss_rate := (float(losses) / decided * 100.0) if decided > 0 else 0.0
	var avg_win := (gross_profit / wins) if wins > 0 else 0.0
	var avg_loss := (gross_loss / losses) if losses > 0 else 0.0
	var expectancy := avg_win * (win_rate / 100.0) - avg_loss * (loss_rate / 100.0)
	var profit_factor := 0.0
	if gross_loss > EPSILON:
		profit_factor = gross_profit / gross_loss
	elif gross_profit > EPSILON:
		profit_factor = 999.99

	var streak_cur := 0
	var streak_max := 0
	for entry in closed:
		if float(entry.bd.pnl) > 0.0:
			streak_cur += 1
			streak_max = maxi(streak_max, streak_cur)
		else:
			streak_cur = 0

	var assets: Array = []
	for key in per_asset:
		var slot: Dictionary = per_asset[key]
		slot.pct = (float(slot.pnl) / float(slot.cost) * 100.0) if float(slot.cost) > EPSILON else 0.0
		assets.append(slot)
	assets.sort_custom(func(a, b): return float(a.pnl) > float(b.pnl))

	var best_asset := {}
	for slot in assets:
		if float(slot.cost) > EPSILON:
			best_asset = slot
			break
	if best_asset.is_empty() and not assets.is_empty():
		best_asset = assets[0]

	var recent_pool := closed.duplicate()
	recent_pool.sort_custom(func(a, b): return int(a.trade.get("closed_at", 0)) > int(b.trade.get("closed_at", 0)))
	var recent: Array = []
	for i in mini(6, recent_pool.size()):
		var e: Dictionary = recent_pool[i]
		recent.append({
			"id": str(e.trade.get("id", "")),
			"asset": str(e.trade.get("asset", "?")),
			"pnl": float(e.bd.pnl),
			"closed_at": int(e.trade.get("closed_at", 0)),
		})

	return {
		"total": ranged.size(),
		"open_count": open_count,
		"closed_count": closed_count,
		"wins": wins,
		"losses": losses,
		"win_rate": win_rate,
		"gross_profit": gross_profit,
		"gross_loss": gross_loss,
		"profit_factor": profit_factor,
		"expectancy": expectancy,
		"avg_win_hold": (win_hold / wins) if wins > 0 else 0.0,
		"avg_loss_hold": (loss_hold / losses) if losses > 0 else 0.0,
		"streak_current": streak_cur,
		"streak_max": streak_max,
		"biggest_win": biggest_win,
		"biggest_loss": biggest_loss,
		"net_pnl": net_pnl,
		"total_fees": total_fees,
		"per_asset": assets,
		"best_asset": best_asset,
		"recent_closed": recent,
	}
