class_name ThinkingBubble
extends Label3D
## The "..." over a villager's head while something is being worked out for them.
##
## A beat takes the dialogue model six or seven seconds to write and a clip takes another
## fraction of a second to come back, and for all of that the villager is standing there
## saying nothing. Without a sign that anything is happening the pause reads as the game
## having stopped, which is the worst reading available: the player walks off precisely
## when the answer is about to arrive.
##
## The dots animate rather than sitting still, because a static "..." looks like a label
## somebody forgot to hide. They cycle one to three so the thing is visibly alive, and the
## whole bubble breathes gently in and out so it reads at a glance from across the square.

## Seconds per dot. Three of these is one full cycle.
@export_range(0.1, 1.0, 0.05) var dot_seconds: float = 0.35

## How far the bubble drifts up and down, in metres.
@export_range(0.0, 0.2, 0.01) var bob_metres: float = 0.04

## Seconds to fade in and out.
@export_range(0.0, 1.0, 0.05) var fade_seconds: float = 0.18

var _showing: bool = false
var _elapsed: float = 0.0
var _base_y: float = 0.0
var _tween: Tween


func _ready() -> void:
	_base_y = position.y
	text = "."
	modulate.a = 0.0
	visible = false
	set_process(false)


func _process(delta: float) -> void:
	_elapsed += delta
	var dots: int = 1 + int(_elapsed / dot_seconds) % 3
	var wanted: String = ".".repeat(dots)
	if text != wanted:
		text = wanted
	position.y = _base_y + sin(_elapsed * 2.4) * bob_metres


## Shows or hides the bubble. Safe to call every frame with the same value.
func set_thinking(thinking: bool) -> void:
	if thinking == _showing:
		return
	_showing = thinking
	if _tween != null and _tween.is_valid():
		_tween.kill()

	if thinking:
		_elapsed = 0.0
		visible = true
		set_process(true)
		_tween = create_tween()
		_tween.tween_property(self, "modulate:a", 1.0, fade_seconds)
		return

	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, fade_seconds)
	_tween.tween_callback(func() -> void:
		visible = false
		set_process(false)
		position.y = _base_y
	)


## Whether the bubble is currently up.
func is_thinking() -> bool:
	return _showing
