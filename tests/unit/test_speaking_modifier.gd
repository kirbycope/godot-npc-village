extends GutTest
## [SpeakingModifier] gesture lifecycle.
##
## The modifier poses bones, which is awkward to assert on directly, so what is covered
## here is the part that can silently break: a gesture must always finish. A gesture
## that never clears would leave a villager frozen mid-shrug for the rest of the scene.

var _modifier: SpeakingModifier
var _skeleton: Skeleton3D


func before_each() -> void:
	_skeleton = Skeleton3D.new()
	add_child_autofree(_skeleton)
	_modifier = SpeakingModifier.new()
	_skeleton.add_child(_modifier)
	await wait_frames(1)


func test_a_new_modifier_is_not_gesturing() -> void:
	assert_false(_modifier.is_gesturing())


func test_playing_a_gesture_starts_it() -> void:
	_modifier.play_gesture(&"nod")
	assert_true(_modifier.is_gesturing())


func test_playing_none_clears_the_gesture() -> void:
	_modifier.play_gesture(&"shrug")
	assert_true(_modifier.is_gesturing())
	_modifier.play_gesture(&"none")
	assert_false(_modifier.is_gesturing())


func test_a_gesture_finishes_on_its_own() -> void:
	_modifier.gesture_duration = 0.2
	_modifier.play_gesture(&"laugh")
	assert_true(_modifier.is_gesturing())
	# Long enough for the modifier to run past its own duration.
	await wait_seconds(0.6)
	assert_false(_modifier.is_gesturing(), "a gesture must always clear itself")


func test_energy_defaults_to_silent() -> void:
	assert_eq(_modifier.energy, 0.0, "a villager who is not speaking should not move")
