extends Control
## Root shell: header bar (title, live totals, refresh/settings) + TabContainer
## with Dashboard / Holdings / Chart / Watchlist screens.

var _value_label: Label
var _day_label: Label
var _tabs: TabContainer
var _chart_screen: Control
var _settings_dialog: AcceptDialog


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	vbox.add_child(_build_header())

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tabs)

	var dashboard := preload("res://scenes/dashboard.tscn").instantiate()
	_tabs.add_child(dashboard)
	_tabs.set_tab_title(0, "Dashboard")

	var holdings := preload("res://scenes/holdings.tscn").instantiate()
	_tabs.add_child(holdings)
	_tabs.set_tab_title(1, "Holdings")

	_chart_screen = preload("res://scenes/chart.tscn").instantiate()
	_tabs.add_child(_chart_screen)
	_tabs.set_tab_title(2, "Chart")

	var watchlist := preload("res://scenes/watchlist.tscn").instantiate()
	_tabs.add_child(watchlist)
	_tabs.set_tab_title(3, "Watchlist")
	watchlist.chart_requested.connect(_on_chart_requested)

	_settings_dialog = preload("res://scenes/dialogs/settings_dialog.tscn").instantiate()
	add_child(_settings_dialog)

	MarketSimulator.market_ticked.connect(_refresh_header)
	PortfolioManager.portfolio_changed.connect(_refresh_header)
	_refresh_header()


func _build_header() -> Control:
	var header := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	header.add_child(hbox)

	var title := Label.new()
	title.text = "LocalStoport"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Utils.ACCENT)
	hbox.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	_value_label = Label.new()
	_value_label.add_theme_font_size_override("font_size", 18)
	hbox.add_child(_value_label)

	_day_label = Label.new()
	hbox.add_child(_day_label)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(func() -> void: MarketSimulator.tick())
	hbox.add_child(refresh_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.pressed.connect(func() -> void: _settings_dialog.popup_centered())
	hbox.add_child(settings_btn)
	return header


func _refresh_header() -> void:
	_value_label.text = Utils.money(PortfolioManager.get_total_value())
	var day := PortfolioManager.get_day_change()
	var day_pct := PortfolioManager.get_day_change_pct()
	_day_label.text = "%s (%s) today" % [Utils.money(day, true), Utils.pct(day_pct)]
	_day_label.add_theme_color_override("font_color", Utils.change_color(day))


func _on_chart_requested(ticker: String) -> void:
	_tabs.current_tab = 2
	_chart_screen.set_ticker(ticker)
