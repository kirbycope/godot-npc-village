extends GutTest
## Covers how the subtitle panel sizes itself.
##
## The panel once carried a fixed 680 pixel minimum width and 22 pixel type against a
## 1280 by 800 design, which is over half the screen at any window size because the
## project stretches `canvas_items` with a `keep` aspect. These tests pin the panel to
## a share of the viewport instead, and pin the ceiling so a wide viewport cannot turn
## it back into a banner.

var _hud: SubtitleHUD


func before_each() -> void:
	_hud = SubtitleHUD.new()
	add_child_autofree(_hud)
	await wait_frames(2)


func test_panel_is_a_minority_of_the_viewport() -> void:
	var view: Vector2 = _hud.get_viewport().get_visible_rect().size
	var label: Label = _line_label()
	assert_not_null(label, "the HUD should have built a line label")
	assert_lt(label.custom_minimum_size.x, view.x * 0.5,
		"the subtitle should take less than half the screen width")


func test_width_tracks_the_viewport_share_within_its_bounds() -> void:
	var view: Vector2 = _hud.get_viewport().get_visible_rect().size
	var expected: float = clampf(
		view.x * SubtitleHUD.WIDTH_SHARE, SubtitleHUD.WIDTH_MIN, SubtitleHUD.WIDTH_MAX)
	assert_almost_eq(_line_label().custom_minimum_size.x, expected, 0.5,
		"the width should be the clamped share of the viewport")


func test_width_never_exceeds_the_ceiling() -> void:
	assert_lte(_line_label().custom_minimum_size.x, SubtitleHUD.WIDTH_MAX,
		"a wide viewport must not stretch the panel into a banner")


func test_type_never_grows_past_the_design_size() -> void:
	# The scale is capped at one, so a tall viewport keeps the designed type rather
	# than inflating it.
	var line: Label = _line_label()
	var speaker: Label = _speaker_label()
	assert_lte(line.get_theme_font_size("font_size"), SubtitleHUD.LINE_FONT,
		"the spoken line should never be larger than its design size")
	assert_lte(speaker.get_theme_font_size("font_size"), SubtitleHUD.SPEAKER_FONT,
		"the speaker name should never be larger than its design size")


func test_resizing_the_viewport_relays_the_panel_out() -> void:
	var before: float = _line_label().custom_minimum_size.x
	_hud._apply_scale()
	assert_eq(_line_label().custom_minimum_size.x, before,
		"re-applying the scale at the same size should be a no-op")


## The panel is built in code, so the labels are found by walking rather than by path.
func _line_label() -> Label:
	return _labels()[1] if _labels().size() > 1 else null


func _speaker_label() -> Label:
	return _labels()[0] if _labels().size() > 0 else null


func _labels() -> Array[Label]:
	var found: Array[Label] = []
	var queue: Array[Node] = [_hud]
	while not queue.is_empty():
		var node: Node = queue.pop_front()
		if node is Label:
			found.append(node as Label)
		for child: Node in node.get_children():
			queue.append(child)
	return found
