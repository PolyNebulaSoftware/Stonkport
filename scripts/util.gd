class_name Utils
## Static formatting and color helpers shared across the UI.

const BG := Color("0d1117")
const PANEL := Color("161b22")
const BORDER := Color("30363d")
const ACCENT := Color("58a6ff")
const GREEN := Color("3fb950")
const RED := Color("f85149")
const ORANGE := Color("d29922")
const PURPLE := Color("a371f7")
const TEXT := Color("e6edf3")
const MUTED := Color("8b949e")

## Currency codes and their display symbols. TradeManager keeps
## [member currency_symbol] in sync with the saved setting.
const CURRENCIES := {
	"USD": "$",
	"EUR": "€",
	"GBP": "£",
	"JPY": "¥",
	"CNY": "¥",
	"CAD": "CA$",
	"AUD": "A$",
	"CHF": "CHF ",
}

static var currency_symbol := "$"

## USD→currency factors kept beside the display symbols above. Live feeds
## (Yahoo/Binance) are USD-denominated; charts rescale through these.
const USD_RATES := {
	"USD": 1.0, "EUR": 0.92, "GBP": 0.79, "JPY": 149.5,
	"CNY": 7.15, "CAD": 1.36, "AUD": 1.51, "CHF": 0.88,
}

static var currency_rate := 1.0


## Converts a USD-denominated amount into the active display currency.
static func from_usd(value: float) -> float:
	return value * currency_rate


## Formats a value with the active currency symbol, e.g. "$1,234.56";
## with signed=true → "+$1,234.56" / "-$1,234.56".
static func money(value: float, signed := false) -> String:
	var sign_prefix := ""
	if signed:
		sign_prefix = "+" if value >= 0.0 else "-"
	elif value < 0.0:
		sign_prefix = "-"
	return "%s%s%s" % [sign_prefix, currency_symbol, _with_commas("%.2f" % absf(value))]


static func pct(value: float, signed := true) -> String:
	return ("%+.2f%%" if signed else "%.2f%%") % value


## Compact human-readable volume/magnitude: 1.2K / 3.4M / 1.1B.
static func compact(value: float) -> String:
	var v := absf(value)
	if v >= 1000000000.0:
		return "%.1fB" % (v / 1000000000.0)
	if v >= 1000000.0:
		return "%.1fM" % (v / 1000000.0)
	if v >= 1000.0:
		return "%.1fK" % (v / 1000.0)
	return "%.0f" % v


## Green for gains, red for losses, muted for flat.
static func change_color(value: float) -> Color:
	if value > 0.0001:
		return GREEN
	if value < -0.0001:
		return RED
	return MUTED


## Trims trailing zeros for quantity display (up to 8 decimals, e.g. BTC):
## 15.0 → "15", 0.50 → "0.5", 0.0001 → "0.0001".
static func qty(value: float) -> String:
	var text := "%.8f" % value
	while text.ends_with("0"):
		text = text.substr(0, text.length() - 1)
	return text.rstrip(".")


## Human-readable span: "3d 4h", "2h 15m" or "45m".
static func duration(seconds: float) -> String:
	var total := int(maxf(seconds, 0.0))
	var days := floori(total / 86400.0)
	var hours := floori((total % 86400) / 3600.0)
	var minutes := floori((total % 3600) / 60.0)
	if days > 0:
		return "%dd %dh" % [days, hours]
	if hours > 0:
		return "%dh %dm" % [hours, minutes]
	return "%dm" % minutes


## UTC calendar date of a unix timestamp: "2026-08-23".
static func date_str(ts: int) -> String:
	return Time.get_datetime_string_from_unix_time(ts).substr(0, 10)


## UTC "YYYY-MM-DD HH:MM" of a unix timestamp.
static func datetime_str(ts: int) -> String:
	return Time.get_datetime_string_from_unix_time(ts).substr(0, 16)


## Parses "YYYY-MM-DD" (optionally "YYYY-MM-DD HH:MM[:SS]") into unix seconds.
## A bare date maps to 23:59:59 when end_of_day is set. Returns -1 on invalid
## input.
static func parse_date(text: String, end_of_day := false) -> int:
	var t := text.strip_edges().replace("T", " ")
	if t.is_empty():
		return -1
	var parts := t.split(" ")
	var day := parts[0].split("-")
	if day.size() != 3:
		return -1
	var y := int(day[0])
	var m := int(day[1])
	var d := int(day[2])
	if y < 1970 or m < 1 or m > 12 or d < 1 or d > 31:
		return -1
	var hh := 0
	var mm := 0
	var ss := 0
	if end_of_day:
		hh = 23
		mm = 59
		ss = 59
	elif parts.size() > 1:
		var clock := parts[1].split(":")
		hh = clampi(int(clock[0]) if clock.size() > 0 else 0, 0, 23)
		mm = clampi(int(clock[1]) if clock.size() > 1 else 0, 0, 59)
		ss = clampi(int(clock[2]) if clock.size() > 2 else 0, 0, 59)
	var dt := {"year": y, "month": m, "day": d, "hour": hh, "minute": mm, "second": ss}
	var ts := int(Time.get_unix_time_from_datetime_dict(dt))
	var back := Time.get_datetime_dict_from_unix_time(ts)
	if int(back.year) != y or int(back.month) != m or int(back.day) != d \
			or int(back.hour) != hh or int(back.minute) != mm:
		return -1
	return ts


## Parses "DD/MM/YYYY" plus optional "HH:MM" (24h) into unix seconds.
## Two-digit years are treated as 2000+. Returns -1 on invalid input.
static func parse_date_sj(date_text: String, time_text := "") -> int:
	var parts := date_text.strip_edges().split("/")
	if parts.size() != 3:
		return -1
	var day := int(parts[0])
	var month := int(parts[1])
	var year := int(parts[2])
	if year < 100:
		year += 2000
	if year < 1970 or month < 1 or month > 12 or day < 1 or day > 31:
		return -1
	var hh := 0
	var mm := 0
	var clock := time_text.strip_edges().split(":")
	if clock.size() >= 1 and not clock[0].is_empty():
		hh = clampi(int(clock[0]), 0, 23)
		mm = clampi(int(clock[1]) if clock.size() > 1 else 0, 0, 59)
	var dt := {"year": year, "month": month, "day": day, "hour": hh, "minute": mm, "second": 0}
	var ts := int(Time.get_unix_time_from_datetime_dict(dt))
	var back := Time.get_datetime_dict_from_unix_time(ts)
	if int(back.year) != year or int(back.month) != month or int(back.day) != day:
		return -1
	return ts


## Parses currency-flavored numbers: "$1,234.56", "-$15.47", "2,305.95%".
## "-", "" and other blanks yield 0.0.
static func parse_money(text: String) -> float:
	var t := text.strip_edges().replace("$", "").replace(",", "").replace("%", "").replace(" ", "")
	if t.is_empty() or t == "-":
		return 0.0
	return t.to_float()


## Escapes a single field for RFC-4180 CSV output.
static func csv_field(value: String) -> String:
	if value.contains(",") or value.contains("\"") or value.contains("\n") or value.contains("\r"):
		return "\"%s\"" % value.replace("\"", "\"\"")
	return value


## Splits one CSV line into fields, honoring double-quoted escapes.
static func csv_split(line: String) -> Array:
	var fields: Array = []
	var current := ""
	var in_quotes := false
	var i := 0
	while i < line.length():
		var ch := line[i]
		if in_quotes:
			if ch == "\"":
				if i + 1 < line.length() and line[i + 1] == "\"":
					current += "\""
					i += 1
				else:
					in_quotes = false
			else:
				current += ch
		elif ch == "\"":
			in_quotes = true
		elif ch == ",":
			fields.append(current)
			current = ""
		else:
			current += ch
		i += 1
	fields.append(current)
	return fields


## Convenience StyleBoxFlat for badges, chips and panels.
static func flat_style(bg: Color, border := Color.TRANSPARENT, radius := 6, margin_h := 8.0, margin_v := 3.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if border.a > 0.0:
		sb.set_border_width_all(1)
		sb.border_color = border
	sb.content_margin_left = margin_h
	sb.content_margin_right = margin_h
	sb.content_margin_top = margin_v
	sb.content_margin_bottom = margin_v
	return sb


## Default compact panel background for cards and section panels.
static func panel_style() -> StyleBoxFlat:
	return flat_style(PANEL, BORDER, 8, 10.0, 8.0)


static func _with_commas(number_text: String) -> String:
	var parts := number_text.split(".")
	var whole := parts[0]
	var out := ""
	var count := 0
	for i in range(whole.length() - 1, -1, -1):
		out = whole[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	if parts.size() > 1:
		out += "." + parts[1]
	return out
