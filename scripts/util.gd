class_name Utils
## Static formatting and color helpers shared across the UI.

const BG := Color("0d1117")
const PANEL := Color("161b22")
const BORDER := Color("30363d")
const ACCENT := Color("58a6ff")
const GREEN := Color("3fb950")
const RED := Color("f85149")
const TEXT := Color("e6edf3")
const MUTED := Color("8b949e")


## Formats a value as "$1,234.56"; with signed=true → "+$1,234.56" / "-$1,234.56".
static func money(value: float, signed := false) -> String:
	var sign_prefix := ""
	if signed:
		sign_prefix = "+" if value >= 0.0 else "-"
	elif value < 0.0:
		sign_prefix = "-"
	return "%s$%s" % [sign_prefix, _with_commas("%.2f" % absf(value))]


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
