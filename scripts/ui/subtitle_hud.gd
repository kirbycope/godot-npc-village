class_name SubtitleHUD
extends CanvasLayer
## Shows whatever the villagers are saying, at the bottom of the screen.
##
## Subtitles were first tried as a [Label3D] floating over each villager's head, which
## does not work: a world space label is sized in metres, so it is unreadable from
## across the square and fills the screen when you stand next to it. There is no
## setting that is right at both distances. A screen space subtitle is the same size
## wherever the player is standing, which is the whole point of a subtitle.
##
## The name plate over each villager stays in world space, because that genuinely
## should shrink with distance: it labels a body in the world, it is not being read.
##
## The HUD finds every [NPC] in the scene and listens, so a village that gains another
## conversation needs no change here.

## Seconds a line lingers after the villager stops speaking.
const LINGER: float = 0.7

## Seconds the panel takes to fade in and out.
const FADE: float = 0.18

## How wide the panel may grow, as a share of the viewport.
##
## The stretch mode is `canvas_items` with a `keep` aspect, so the logical viewport
## stays 1280 by 800 whatever the window does and the panel holds the same share of
## the picture on a phone, a laptop and a browser filling a large display. That is why
## a size that looked reasonable while the game ran in a small editor window read as
## enormous in the web build on a big screen: it was never scaling wrongly, it was
## simply taking half the width everywhere. Sizing from the viewport rather than from
## a fixed pixel count keeps it honest if the aspect ever changes.
const WIDTH_SHARE: float = 0.40

## Bounds on that width, so the panel neither stretches into a banner on a wide
## viewport nor squeezes a line into a column on a narrow one.
const WIDTH_MIN: float = 300.0
const WIDTH_MAX: float = 520.0

## Type sizes at the 800 pixel design height, scaled with the viewport and capped so
## they never grow past what was designed.
const SPEAKER_FONT: int = 13
const LINE_FONT: int = 18
const DESIGN_HEIGHT: float = 800.0

var _panel: PanelContainer
var _speaker_label: Label
var _line_label: Label
var _current: NPC
var _tween: Tween


func _ready() -> void:
	layer = 10
	_build()
	# Deferred so every NPC has run its own `_ready` and is discoverable.
	_connect_villagers.call_deferred()
	_connect_player_voice.call_deferred()


## Wires up every villager currently in the scene.
func _connect_villagers() -> void:
	# Deferred, so by the time this runs the HUD may have left the tree, and a scene
	# built in code may have no `current_scene` at all.
	if not is_inside_tree():
		return
	for node: Node in get_tree().get_nodes_in_group("villagers"):
		_connect_one(node)
	# The group is the reliable path, but fall back to a type sweep so a villager that
	# was never added to it still gets subtitled.
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	for node: Node in scene.find_children("*", "CharacterBody3D", true, false):
		if node is NPC:
			_connect_one(node)


## Listens for the player's own microphone, so holding the key shows on screen and the
## line that was understood is played back to them. Without that the player cannot tell
## whether they were heard, whether they were misheard, or whether nothing happened.
func _connect_player_voice() -> void:
	if not is_inside_tree():
		return
	var voice: Node = get_tree().get_first_node_in_group("player_voice")
	if voice == null:
		return
	voice.connect("started_listening", _on_listening)
	voice.connect("spoke", _on_player_spoke)
	voice.connect("failed", _on_player_failed)


func _on_listening() -> void:
	_current = null
	_speaker_label.text = "You"
	_line_label.text = "listening..."
	_fade_to(1.0)


func _on_player_spoke(line: String, _addressed: NPC) -> void:
	_current = null
	_speaker_label.text = "You"
	_line_label.text = line
	_fade_to(1.0)
	# Held until a villager answers, so the player can read back what was understood.


func _on_player_failed(reason: String) -> void:
	_current = null
	_speaker_label.text = "You"
	_line_label.text = "(%s)" % reason
	_fade_to(1.0)
	var timer: SceneTreeTimer = get_tree().create_timer(1.6)
	timer.timeout.connect(_clear_if_idle)


func _connect_one(node: Node) -> void:
	var npc: NPC = node as NPC
	if npc == null:
		return
	if not npc.started_speaking.is_connected(_on_started):
		npc.started_speaking.connect(_on_started)
	if not npc.finished_speaking.is_connected(_on_finished):
		npc.finished_speaking.connect(_on_finished)


func _build() -> void:
	# The container has to cover the whole screen and push its content to the bottom.
	# Anchoring it to the bottom edge instead gives a strip of zero height, and the
	# panel then lays out just below the viewport where nothing is ever drawn.
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_bottom", 40)
	margin.add_theme_constant_override("margin_left", 56)
	margin.add_theme_constant_override("margin_right", 56)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var column_outer: VBoxContainer = VBoxContainer.new()
	column_outer.alignment = BoxContainer.ALIGNMENT_END
	column_outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column_outer)

	var centre: CenterContainer = CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column_outer.add_child(centre)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.modulate = Color(1.0, 1.0, 1.0, 0.0)
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.05, 0.72)
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 9.0
	style.content_margin_bottom = 10.0
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	_panel.add_theme_stylebox_override("panel", style)
	centre.add_child(_panel)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(column)

	_speaker_label = Label.new()
	_speaker_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speaker_label.add_theme_color_override("font_color", Color(0.80, 0.72, 0.52))
	column.add_child(_speaker_label)

	_line_label = Label.new()
	_line_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_line_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_line_label.add_theme_color_override("font_color", Color(0.97, 0.96, 0.93))
	column.add_child(_line_label)

	_apply_scale()
	var viewport: Viewport = get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(_apply_scale):
		viewport.size_changed.connect(_apply_scale)


## Sizes the panel and its type from the viewport.
##
## Wired to the viewport's `size_changed` as well as being called once while building,
## so a resized window re-lays the panel out instead of keeping whatever the size was
## when the scene loaded.
func _apply_scale() -> void:
	if _line_label == null or _speaker_label == null:
		return
	var view: Vector2 = get_viewport().get_visible_rect().size
	if view.x <= 0.0 or view.y <= 0.0:
		return
	var width: float = clampf(view.x * WIDTH_SHARE, WIDTH_MIN, WIDTH_MAX)
	_line_label.custom_minimum_size = Vector2(width, 0.0)
	var scale: float = minf(view.y / DESIGN_HEIGHT, 1.0)
	_speaker_label.add_theme_font_size_override(
		"font_size", maxi(10, roundi(float(SPEAKER_FONT) * scale)))
	_line_label.add_theme_font_size_override(
		"font_size", maxi(12, roundi(float(LINE_FONT) * scale)))


func _on_started(npc: NPC, turn: ConversationTurn) -> void:
	_current = npc
	_speaker_label.text = npc.persona.display_name if npc.persona != null else String(turn.speaker)
	_line_label.text = turn.line
	_fade_to(1.0)


func _on_finished(npc: NPC) -> void:
	# A later villager may already have taken the panel over, so only the villager who
	# still owns it may clear it.
	if npc != _current:
		return
	_current = null
	var timer: SceneTreeTimer = get_tree().create_timer(LINGER)
	timer.timeout.connect(_clear_if_idle)


func _clear_if_idle() -> void:
	if _current == null:
		_fade_to(0.0)


func _fade_to(alpha: float) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", alpha, FADE)
