class_name DonutChart
extends Control
## Custom-drawn sector-allocation donut with a total value in the center.

const PALETTE: Array[Color] = [
	Color("58a6ff"), Color("3fb950"), Color("f85149"), Color("bc8cff"),
	Color("d29922"), Color("39c5cf"), Color("ff7b72"), Color("7ee787"),
]

var _slices: Array = []  # [{label: String, value: float}]
var _center_text := ""


func set_slices(slices: Array, center_text := "") -> void:
	_slices = slices
	_center_text = center_text
	queue_redraw()


func _draw() -> void:
	var s := get_size()
	if s.x < 40.0 or s.y < 40.0:
		return
	var center := Vector2(s.x * 0.5, s.y * 0.5)
	var radius := minf(s.x, s.y) * 0.5 - 6.0
	if radius <= 10.0:
		return
	var font := ThemeDB.fallback_font

	var total := 0.0
	for slice in _slices:
		total += float(slice["value"])

	if total <= 0.0:
		draw_arc(center, radius - 14.0, 0.0, TAU, 64, Color(Utils.BORDER, 0.6), 14.0, true)
		var msg := "No holdings yet"
		var ms := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		draw_string(font, center + Vector2(-ms.x * 0.5, 4.0), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Utils.MUTED)
		return

	var thickness := radius * 0.38
	var inner := radius - thickness
	var start := -PI * 0.5
	for i in _slices.size():
		var sweep := float(_slices[i]["value"]) / total * TAU
		var color: Color = PALETTE[i % PALETTE.size()]
		draw_arc(
			center, radius - thickness * 0.5, start, start + sweep,
			maxi(int(sweep * 48.0), 2), color, thickness, true
		)
		start += sweep

	draw_circle(center, inner - 2.0, Utils.PANEL)
	if not _center_text.is_empty():
		var ts := font.get_string_size(_center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
		draw_string(font, center + Vector2(-ts.x * 0.5, 5.0), _center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Utils.TEXT)
