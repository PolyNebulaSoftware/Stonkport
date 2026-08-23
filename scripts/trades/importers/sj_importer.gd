extends RefCounted
## "SJ" stock-journal CSV importer — self-contained, removable module.
##
## Recognizes headers like:
## Date,Time,Symbol,Market,Status,Side,Qty,Entry,Exit,Target,Ent Tot,
## Ext Tot,Pos,Hold,Return,Return %,Tags,Notes
##
## Mapping rules:
##   - Symbol -> asset; Market -> asset_type (stock/crypto/custom/option)
##   - Side SHORT -> short direction, otherwise long
##   - "-" Return marks an open position; any value marks it closed
##   - expired-worthless rows (Exit "-") close at price 0
##   - Qty falls back to Pos when blank; dates are DD/MM/YYYY HH:MM
##
## To remove this format: delete this file and drop its entry from
## SettingsScreen.IMPORTERS.

const FORMAT_NAME := "SJ"


static func can_parse(header_line: String) -> bool:
	var h := header_line.to_lower()
	return h.contains("symbol") and h.contains("ent tot")


## valid_types: allowed asset_type values, passed in so this module stays
## decoupled from TradeManager.
static func parse(lines: Array, header_idx: int, valid_types: Array) -> Array:
	var out: Array = []
	var headers := Utils.csv_split(str(lines[header_idx]))
	for i in range(header_idx + 1, lines.size()):
		if str(lines[i]).strip_edges().is_empty():
			continue
		var cells := Utils.csv_split(str(lines[i]))
		var row := {}
		for h in headers.size():
			if h < cells.size():
				row[str(headers[h]).strip_edges().to_lower()] = str(cells[h])
		var trade := _trade_from_row(row, valid_types)
		if not trade.is_empty():
			out.append(trade)
	return out


static func _trade_from_row(row: Dictionary, valid_types: Array) -> Dictionary:
	var asset := str(row.get("symbol", "")).strip_edges().to_upper()
	if asset.is_empty():
		return {}
	var opened := Utils.parse_date_sj(str(row.get("date", "")), str(row.get("time", "")))
	if opened <= 0:
		return {}
	var qty := Utils.parse_money(str(row.get("qty", "")))
	if qty <= 0.0:
		qty = Utils.parse_money(str(row.get("pos", "")))
	if qty <= 0.0:
		return {}
	var entry := Utils.parse_money(str(row.get("entry", "")))
	if entry <= 0.0:
		return {}
	var exit_price := Utils.parse_money(str(row.get("exit", "")))
	var return_cell := str(row.get("return", "")).strip_edges()
	var closed := return_cell != "" and return_cell != "-"
	var side := str(row.get("side", "")).strip_edges().to_upper()
	var market := str(row.get("market", "")).strip_edges().to_lower()
	var logs: Array = [{"ts": opened, "action": "open", "qty": qty, "price": entry, "fee": 0.0}]
	if closed:
		# Honor the exported Hold column so durations survive the round-trip;
		# the file only carries one timestamp per row.
		var close_ts := opened + int(_parse_hold_seconds(str(row.get("hold", ""))))
		logs.append({"ts": close_ts, "action": "close", "qty": qty, "price": maxf(exit_price, 0.0), "fee": 0.0})
	var notes := str(row.get("notes", "")).strip_edges()
	var tags := str(row.get("tags", "")).strip_edges()
	if tags != "":
		notes = tags + (" - " + notes if notes != "" else "")
	return {
		"id": "",
		"asset": asset,
		"asset_type": market if valid_types.has(market) else "stock",
		"direction": "short" if side == "SHORT" else "long",
		"state": "open",
		"opened_at": 0,
		"closed_at": 0,
		"notes": notes,
		"logs": logs,
	}


## Converts Hold values like "21 DAYS" / "3 MIN" / "1 DAY" into seconds.
static func _parse_hold_seconds(text: String) -> float:
	var t := text.strip_edges().to_upper()
	if t.is_empty() or t == "-":
		return 0.0
	var parts := t.split(" ", false)
	if parts.size() < 2:
		return 0.0
	var value := Utils.parse_money(str(parts[0]))
	if value <= 0.0:
		return 0.0
	var unit := str(parts[1])
	if unit.begins_with("MIN"):
		return value * 60.0
	if unit.begins_with("HOUR"):
		return value * 3600.0
	if unit.begins_with("DAY"):
		return value * 86400.0
	if unit.begins_with("WEEK"):
		return value * 604800.0
	return 0.0
