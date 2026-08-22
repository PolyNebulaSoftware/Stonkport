extends AcceptDialog
## Settings: price refresh interval, currency display, and demo-data reset.

var _slider: HSlider
var _interval_label: Label


func _ready() -> void:
	title = "Settings"
	min_size = Vector2i(440, 0)
	get_ok_button().hide()

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	content.custom_minimum_size = Vector2(410, 0)
	add_child(content)

	# --- Refresh interval ---
	var interval_box := VBoxContainer.new()
	interval_box.add_theme_constant_override("separation", 6)
	content.add_child(interval_box)

	var interval_head := HBoxContainer.new()
	interval_box.add_child(interval_head)
	var interval_caption := Label.new()
	interval_caption.text = "Price refresh interval"
	interval_head.add_child(interval_caption)
	var head_spacer := Control.new()
	head_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	interval_head.add_child(head_spacer)
	_interval_label = Label.new()
	_interval_label.add_theme_color_override("font_color", Utils.ACCENT)
	interval_head.add_child(_interval_label)

	_slider = HSlider.new()
	_slider.min_value = 1.0
	_slider.max_value = 60.0
	_slider.step = 1.0
	_slider.value = clampf(float(PortfolioManager.settings.get("refresh_interval_s", 5.0)), 1.0, 60.0)
	_slider.custom_minimum_size = Vector2(0, 20)
	_slider.value_changed.connect(_on_interval_changed)
	interval_box.add_child(_slider)
	_interval_label.text = "%ds" % int(_slider.value)

	# --- Currency ---
	var currency_row := HBoxContainer.new()
	content.add_child(currency_row)
	var currency_caption := Label.new()
	currency_caption.text = "Currency"
	currency_row.add_child(currency_caption)
	var currency_spacer := Control.new()
	currency_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	currency_row.add_child(currency_spacer)
	var currency_value := Label.new()
	currency_value.text = "USD"
	currency_value.add_theme_color_override("font_color", Utils.MUTED)
	currency_row.add_child(currency_value)

	content.add_child(HSeparator.new())

	# --- Data ---
	var data_row := HBoxContainer.new()
	data_row.add_theme_constant_override("separation", 10)
	content.add_child(data_row)
	var data_caption := Label.new()
	data_caption.text = "Data"
	data_row.add_child(data_caption)
	var data_spacer := Control.new()
	data_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	data_row.add_child(data_spacer)
	var reset_btn := Button.new()
	reset_btn.text = "Reset to demo data"
	reset_btn.pressed.connect(_on_reset)
	data_row.add_child(reset_btn)

	var note := Label.new()
	note.text = "Resets cash, holdings, transactions, watchlist and prices."
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", Utils.MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(note)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	content.add_child(buttons)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(hide)
	buttons.add_child(close_btn)


func _on_interval_changed(value: float) -> void:
	_interval_label.text = "%ds" % int(value)
	PortfolioManager.set_refresh_interval(value)


func _on_reset() -> void:
	PortfolioManager.reset_demo()
	hide()
