extends Control
## Dashboard: summary cards (Total Value / Cash / Day Change / Total P&L),
## sector allocation donut with legend, and a top movers list.

const DonutChartScript := preload("res://scripts/chart/donut_chart.gd")

var _cards: Dictionary = {}
var _donut: Control
var _legend: VBoxContainer
var _movers: VBoxContainer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 4)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 12)
	vbox.add_child(cards)
	for spec in [["Total Value", "total"], ["Cash", "cash"], ["Day Change", "day"], ["Total P&L", "pnl"]]:
		cards.add_child(_make_card(spec[0], spec[1]))

	var lower := HBoxContainer.new()
	lower.add_theme_constant_override("separation", 12)
	lower.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(lower)

	lower.add_child(_make_panel("Sector Allocation", _build_allocation()))
	lower.add_child(_make_panel("Top Movers Today", _build_movers()))

	MarketSimulator.market_ticked.connect(_refresh)
	PortfolioManager.portfolio_changed.connect(_refresh)
	_refresh()


func _make_card(title_text: String, key: String) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Utils.MUTED)
	vbox.add_child(title)

	var value := Label.new()
	value.text = "-"
	value.add_theme_font_size_override("font_size", 21)
	vbox.add_child(value)

	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Utils.MUTED)
	vbox.add_child(sub)

	_cards[key] = {"value": value, "sub": sub}
	return panel


func _make_panel(title_text: String, content: Control) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(title)
	vbox.add_child(content)
	return panel


func _build_allocation() -> Control:
	var vbox := VBoxContainer.new()
	_donut = DonutChartScript.new()
	_donut.custom_minimum_size = Vector2(230, 230)
	_donut.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(_donut)
	_legend = VBoxContainer.new()
	_legend.add_theme_constant_override("separation", 4)
	vbox.add_child(_legend)
	return vbox


func _build_movers() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_movers = VBoxContainer.new()
	_movers.add_theme_constant_override("separation", 6)
	_movers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_movers)
	return scroll


func _refresh() -> void:
	var pm := PortfolioManager

	_cards["total"]["value"].text = Utils.money(pm.get_total_value())
	_cards["total"]["sub"].text = "Cash + positions"

	_cards["cash"]["value"].text = Utils.money(pm.cash)
	_cards["cash"]["sub"].text = "Buying power"

	var day := pm.get_day_change()
	var day_value: Label = _cards["day"]["value"]
	day_value.text = Utils.money(day, true)
	day_value.add_theme_color_override("font_color", Utils.change_color(day))
	_cards["day"]["sub"].text = "%s today" % Utils.pct(pm.get_day_change_pct())

	var pnl := pm.get_total_pnl()
	var pnl_value: Label = _cards["pnl"]["value"]
	pnl_value.text = Utils.money(pnl, true)
	pnl_value.add_theme_color_override("font_color", Utils.change_color(pnl))
	_cards["pnl"]["sub"].text = "%s vs cost" % Utils.pct(pm.get_total_pnl_pct())

	_update_donut()
	_update_movers()


func _update_donut() -> void:
	var alloc := PortfolioManager.get_sector_allocation()
	var slices: Array = []
	var keys: Array = alloc.keys()
	keys.sort()
	for key in keys:
		slices.append({"label": key, "value": alloc[key]})
	var total := PortfolioManager.get_holdings_value()
	_donut.set_slices(slices, Utils.money(total) if total > 0.0 else "")

	for child in _legend.get_children():
		child.queue_free()
	if slices.is_empty():
		var empty := Label.new()
		empty.text = "Add positions to see your allocation."
		empty.add_theme_color_override("font_color", Utils.MUTED)
		_legend.add_child(empty)
		return
	for i in slices.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(10, 10)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		swatch.color = DonutChartScript.PALETTE[i % DonutChartScript.PALETTE.size()]
		row.add_child(swatch)
		var label := Label.new()
		var share := float(slices[i]["value"]) / total * 100.0
		label.text = "%s   %s (%s)" % [slices[i]["label"], Utils.money(slices[i]["value"]), Utils.pct(share, false)]
		label.add_theme_color_override("font_color", Utils.TEXT)
		row.add_child(label)
		_legend.add_child(row)


func _update_movers() -> void:
	for child in _movers.get_children():
		child.queue_free()
	for mover in MarketSimulator.get_top_movers(6):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var ticker_label := Label.new()
		ticker_label.text = mover["ticker"]
		ticker_label.custom_minimum_size = Vector2(64, 0)
		row.add_child(ticker_label)

		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(spacer)

		var price_label := Label.new()
		price_label.text = Utils.money(mover["price"])
		price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		price_label.custom_minimum_size = Vector2(84, 0)
		row.add_child(price_label)

		var chg_label := Label.new()
		chg_label.text = Utils.pct(mover["change_pct"])
		chg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		chg_label.custom_minimum_size = Vector2(76, 0)
		chg_label.add_theme_color_override("font_color", Utils.change_color(mover["change"]))
		row.add_child(chg_label)

		_movers.add_child(row)
