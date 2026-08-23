extends Control
## Dual-grip timeline histogram for the time-range bar.
##
## Bars show how many trade logs fall into each bucket across the full
## journal span; buckets inside the selection are accent-colored. Dragging
## either grip (or clicking to jump the nearest grip) reshapes the selection
## and emits range_changed(min_ts, max_ts).

signal range_changed(min_ts: int, max_ts: int)

const MIN_SPAN := 0.02  # minimum selection width as a fraction of the domain

var _counts := PackedFloat32Array()
var _domain_min := 0
var _domain_max := 0
var _sel_min := 0.0
var _sel_max := 1.0
var _drag := 0  # 0 none | 1 min grip | 2 max grip


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, 54)


func has_domain() -> bool:
	return _domain_max > _domain_min


func set_trades(trades: Array) -> void:
	var stamps: Array = []
	for t in trades:
		for log in t.get("logs", []):
			stamps.append(int(log.get("ts", 0)))
	if stamps.is_empty():
		_counts = PackedFloat32Array()
		_domain_min = 0
		_domain_max = 0
		visible = false
		queue_redraw()
		return
	stamps.sort()
	_domain_min = stamps[0]
	_domain_max = maxi(stamps[stamps.size() - 1], _domain_min + 1)
	var bar_count := clampi(int(size.x / 9.0), 24, 64)
	var counts := PackedFloat32Array()
	counts.resize(bar_count)
	var span := float(_domain_max - _domain_min)
	for ts in stamps:
		var idx := clampi(int(float(ts - _domain_min) / span * bar_count), 0, bar_count - 1)
		counts[idx] += 1.0
	_counts = counts
	visible = true
	queue_redraw()


## Syncs the grips to an absolute timestamp range (preset chips / date fields).
func set_selection(min_ts: int, max_ts: int) -> void:
	if not has_domain():
		return
	var span := float(_domain_max - _domain_min)
	_sel_min = clampf(float(maxi(min_ts, _domain_min) - _domain_min) / span, 0.0, 1.0)
	if max_ts > 0:
		_sel_max = clampf(float(mini(max_ts, _domain_max) - _domain_min) / span, 0.0, 1.0)
	else:
		_sel_max = 1.0
	if _sel_max < _sel_min:
		_sel_max = _sel_min
	queue_redraw()


func clear_selection() -> void:
	_sel_min = 0.0
	_sel_max = 1.0
	queue_redraw()


func _selected_range() -> Array:
	var span := _domain_max - _domain_min
	return [
		_domain_min + int(round(_sel_min * span)),
		_domain_min + int(round(_sel_max * span)),
	]


func _gui_input(event: InputEvent) -> void:
	if not has_domain():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var f := _fraction_at(event.position.x)
			_drag = _nearest_grip(f)
			_apply_fraction(f)
		else:
			_drag = 0
		accept_event()
	elif event is InputEventMouseMotion and _drag != 0:
		_apply_fraction(_fraction_at(event.position.x))
		accept_event()


func _fraction_at(x: float) -> float:
	return clampf(x / maxf(size.x, 1.0), 0.0, 1.0)


func _nearest_grip(f: float) -> int:
	if absf(f - _sel_min) <= absf(f - _sel_max):
		return 1
	return 2


func _apply_fraction(f: float) -> void:
	if _drag == 1:
		_sel_min = clampf(f, 0.0, _sel_max - MIN_SPAN)
	elif _drag == 2:
		_sel_max = clampf(f, _sel_min + MIN_SPAN, 1.0)
	else:
		return
	queue_redraw()
	var r := _selected_range()
	range_changed.emit(r[0], r[1])


func _draw() -> void:
	if not has_domain():
		return
	var base_y := size.y - 10.0
	draw_line(Vector2(0, base_y), Vector2(size.x, base_y), Utils.BORDER, 1.0)
	if _counts.is_empty():
		return
	var n := _counts.size()
	var bw := size.x / n
	var peak := 1.0
	for c in _counts:
		peak = maxf(peak, c)
	for i in n:
		var mid := (float(i) + 0.5) / n
		var inside := mid >= _sel_min and mid <= _sel_max
		var bh := maxf((base_y - 4.0) * (_counts[i] / peak), 2.0)
		var col := Color(Utils.ACCENT, 0.85) if inside else Color(Utils.MUTED, 0.35)
		draw_rect(Rect2(i * bw + 1.0, base_y - bh, maxf(bw - 2.0, 1.0), bh), col)
	for grip in [[_sel_min], [_sel_max]]:
		var gx: float = grip[0] * size.x
		draw_line(Vector2(gx, 2.0), Vector2(gx, base_y), Utils.ACCENT, 2.0)
		draw_rect(Rect2(gx - 4.0, base_y - 7.0, 8.0, 8.0), Utils.ACCENT)
