extends Control
## Dashboard: performance statistics over the journal, filtered by the global
## time range. Stat cards + best-asset / P/L-by-asset / recent-closes panels.

var _min_ts := 0
var _max_ts := 0
var _cards := {}
var _rows := {}
var _empty: Label
var _content: VBoxContainer
var _best_box: VBoxContainer
var _bars_box: VBoxContainer
var _recent_box: VBoxContainer
var _panels_row: GridContainer

var _price_provider := func(asset: String) -> float: return MarketSimulator.get_price(asset)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 4)
	add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	margin.add_child(outer)

	_empty = Label.new()
	_empty.text = "No trades in this range."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.add_theme_color_override("font_color", Utils.MUTED)
	outer.add_child(_empty)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 8)
	outer.add_child(_content)

	var row1 := HFlowContainer.new()
	row1.add_theme_constant_override("h_separation", 8)
	row1.add_theme_constant_override("v_separation", 6)
	_content.add_child(row1)
	for spec in [["Net P/L", "net"], ["Win Rate", "win_rate"], ["Profit Factor", "pf"], ["Expectancy", "expectancy"]]:
		row1.add_child(_make_card(spec[0], spec[1]))

	var row2 := HFlowContainer.new()
	row2.add_theme_constant_override("h_separation", 8)
	row2.add_theme_constant_override("v_separation", 6)
	_content.add_child(row2)
	for spec in [["Avg Win Hold", "hold_win"], ["Avg Loss Hold", "hold_loss"], ["Win Streak", "streak"], ["Biggest Win", "big_win"], ["Biggest Loss", "big_loss"]]:
		row2.add_child(_make_card(spec[0], spec[1]))

	# Stat panels reflow between 3 / 2 / 1 columns with the window width.
	var row3 := GridContainer.new()
	row3.columns = 3
	row3.add_theme_constant_override("h_separation", 8)
	row3.add_theme_constant_override("v_separation", 8)
	row3.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(row3)
	row3.add_child(_make_panel("Best Performing Asset", _build_best()))
	row3.add_child(_make_panel("P/L by Asset", _build_bars()))
	row3.add_child(_make_panel("Recent Closed Trades", _build_recent()))
	_panels_row = row3
	_apply_responsive()

	TradeManager.trades_changed.connect(_refresh)
	TradeManager.settings_changed.connect(_refresh)
	MarketSimulator.market_ticked.connect(_refresh)
	get_viewport().size_changed.connect(_apply_responsive)
	_refresh()


## Reflows the bottom stat panels for the current window width.
func _apply_responsive() -> void:
	if _panels_row == null:
		return
	var w := get_viewport().get_visible_rect().size.x
	if w < 760.0:
		_panels_row.columns = 1
	elif w < 1120.0:
		_panels_row.columns = 2
	else:
		_panels_row.columns = 3


func set_range(min_ts: int, max_ts: int) -> void:
	_min_ts = min_ts
	_max_ts = max_ts
	_refresh()


func _refresh() -> void:
	if _content == null:
		return
	var stats := TradeMetrics.compute(TradeManager.trades, _min_ts, _max_ts, _price_provider)
	_empty.visible = int(stats.total) == 0
	_content.visible = int(stats.total) > 0
	if int(stats.total) == 0:
		return

	var net := float(stats.net_pnl)
	_set_card("net", Utils.money(net, true), "%d trades - %d open - fees %s" % [int(stats.total), int(stats.open_count), Utils.money(float(stats.total_fees))], Utils.change_color(net))
	_set_card("win_rate", Utils.pct(float(stats.win_rate), false), "%dW / %dL" % [int(stats.wins), int(stats.losses)])
	_set_card("pf", "%.2f" % float(stats.profit_factor), "gross %s / %s" % [Utils.compact(float(stats.gross_profit)), Utils.compact(float(stats.gross_loss))])
	_set_card("expectancy", Utils.money(float(stats.expectancy), true), "per closed trade", Utils.change_color(float(stats.expectancy)))

	_set_card("hold_win", Utils.duration(float(stats.avg_win_hold)), "%d winning trades" % int(stats.wins))
	_set_card("hold_loss", Utils.duration(float(stats.avg_loss_hold)), "%d losing trades" % int(stats.losses))
	_set_card("streak", "%d / %d" % [int(stats.streak_current), int(stats.streak_max)], "current / max")
	_set_card("big_win", Utils.money(float(stats.biggest_win), true), "best single exit", Utils.GREEN)
	_set_card("big_loss", Utils.money(float(stats.biggest_loss), true), "worst single exit", Utils.RED)

	_reload_best(stats)
	_reload_bars(stats)
	_reload_recent(stats)


# --- Cards / panels ----------------------------------------------------------


func _make_card(title_text: String, key: String) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Utils.panel_style())
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Utils.MUTED)
	vbox.add_child(title)

	var value := Label.new()
	value.text = "-"
	value.add_theme_font_size_override("font_size", 17)
	vbox.add_child(value)

	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", 10)
	sub.add_theme_color_override("font_color", Utils.MUTED)
	vbox.add_child(sub)

	_cards[key] = {"value": value, "sub": sub}
	return panel


func _set_card(key: String, value_text: String, sub_text: String, color := Utils.TEXT) -> void:
	var card: Dictionary = _cards[key]
	var value: Label = card.value
	value.text = value_text
	value.add_theme_color_override("font_color", color)
	var sub: Label = card.sub
	sub.text = sub_text


func _make_panel(title_text: String, content: Control) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Utils.panel_style())
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(title)
	vbox.add_child(content)
	return panel


func _build_best() -> Control:
	_best_box = VBoxContainer.new()
	_best_box.add_theme_constant_override("separation", 4)
	_best_box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	return _best_box


func _reload_best(stats: Dictionary) -> void:
	for child in _best_box.get_children():
		child.queue_free()
	var best: Dictionary = stats.best_asset
	if best.is_empty():
		_best_box.add_child(_muted_label("No closed trades yet."))
		return
	var head := Label.new()
	head.text = str(best.asset)
	head.add_theme_font_size_override("font_size", 19)
	_best_box.add_child(head)
	var detail := Label.new()
	detail.text = "%s (%s) over %d trades" % [Utils.money(float(best.pnl), true), Utils.pct(float(best.pct)), int(best.count)]
	detail.add_theme_font_size_override("font_size", 12)
	detail.add_theme_color_override("font_color", Utils.change_color(float(best.pnl)))
	_best_box.add_child(detail)


func _build_bars() -> Control:
	_bars_box = VBoxContainer.new()
	_bars_box.add_theme_constant_override("separation", 4)
	return _bars_box


func _reload_bars(stats: Dictionary) -> void:
	for child in _bars_box.get_children():
		child.queue_free()
	var assets: Array = stats.per_asset
	if assets.is_empty():
		_bars_box.add_child(_muted_label("Nothing to compare yet."))
		return
	var max_abs := 0.0001
	for slot in assets:
		max_abs = maxf(max_abs, absf(float(slot.pnl)))
	for i in mini(6, assets.size()):
		var slot: Dictionary = assets[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_label := Label.new()
		name_label.text = str(slot.asset)
		name_label.custom_minimum_size = Vector2(52, 0)
		name_label.add_theme_font_size_override("font_size", 11)
		row.add_child(name_label)
		var bar := PnlBar.new()
		bar.ratio = clampf(float(slot.pnl) / max_abs, -1.0, 1.0)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.custom_minimum_size = Vector2(60, 10)
		row.add_child(bar)
		var value := Label.new()
		value.text = Utils.money(float(slot.pnl), true)
		value.add_theme_font_size_override("font_size", 11)
		value.add_theme_color_override("font_color", Utils.change_color(float(slot.pnl)))
		row.add_child(value)
		_bars_box.add_child(row)


func _build_recent() -> Control:
	_recent_box = VBoxContainer.new()
	_recent_box.add_theme_constant_override("separation", 4)
	return _recent_box


func _reload_recent(stats: Dictionary) -> void:
	for child in _recent_box.get_children():
		child.queue_free()
	var recent: Array = stats.recent_closed
	if recent.is_empty():
		_recent_box.add_child(_muted_label("No closed trades in range."))
		return
	for entry in recent:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_label := Label.new()
		name_label.text = str(entry.asset)
		name_label.custom_minimum_size = Vector2(52, 0)
		name_label.add_theme_font_size_override("font_size", 11)
		row.add_child(name_label)
		var pnl := Label.new()
		pnl.text = Utils.money(float(entry.pnl), true)
		pnl.add_theme_font_size_override("font_size", 11)
		pnl.add_theme_color_override("font_color", Utils.change_color(float(entry.pnl)))
		row.add_child(pnl)
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(spacer)
		var date := Label.new()
		date.text = Utils.date_str(int(entry.closed_at))
		date.add_theme_font_size_override("font_size", 10)
		date.add_theme_color_override("font_color", Utils.MUTED)
		row.add_child(date)
		_recent_box.add_child(row)


func _muted_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Utils.MUTED)
	label.add_theme_font_size_override("font_size", 12)
	return label


## Horizontal signed bar drawn behind the P/L-by-asset values.
class PnlBar extends Control:
	var ratio := 0.0

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.114, 0.129, 0.161)
		bg.set_corner_radius_all(4)
		bg.draw(get_canvas_item(), rect)
		var width := absf(ratio) * (rect.size.x - 4.0)
		if width <= 0.0:
			return
		var fill := StyleBoxFlat.new()
		fill.bg_color = Utils.GREEN if ratio > 0.0 else Utils.RED
		fill.set_corner_radius_all(4)
		fill.draw(get_canvas_item(), Rect2(2.0, 2.0, width, rect.size.y - 4.0))
