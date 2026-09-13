class_name SpeakingModifier
extends SkeletonModifier3D
## Poses a villager's head, chest and shoulders on top of whatever clip is playing.
##
## This is a [SkeletonModifier3D] rather than code in the NPC's `_physics_process` for
## one reason that matters: the skeleton applies its animation every frame, and
## anything that writes bone poses before that runs is simply overwritten. A modifier
## is invoked by the skeleton *after* the animation has been applied, so the speaking
## motion layers onto the idle clip instead of fighting it.
##
## Two things are layered here. Speaking motion is a continuous wobble of the head and
## chest, driven while [member energy] is above zero, which the [NPC] raises only while
## a voice clip is actually playing. Gestures are one-shot poses that rise and fall
## over [member gesture_duration]. Both are composed from the skeleton's current pose,
## so an interrupted gesture cannot leave a villager permanently crooked.
##
## Every bone is looked up by its name in Godot's humanoid retargeting profile, and a
## missing bone is skipped rather than being an error. A rig with no shoulders still
## nods; it just does not shrug.

const BONE_HEAD: StringName = &"Head"
const BONE_CHEST: StringName = &"Chest"
const BONE_UPPER_CHEST: StringName = &"UpperChest"
const BONE_SPINE: StringName = &"Spine"
const BONE_SHOULDER_LEFT: StringName = &"LeftShoulder"
const BONE_SHOULDER_RIGHT: StringName = &"RightShoulder"

## How much the villager is speaking, 0 to 1. The NPC drives this.
@export_range(0.0, 1.0, 0.01) var energy: float = 0.0

## Degrees the head swings at full energy.
@export_range(0.0, 25.0, 0.5) var head_motion_degrees: float = 7.0

## Degrees the chest swings. Kept well under the head so the two do not fight.
@export_range(0.0, 15.0, 0.5) var chest_motion_degrees: float = 2.5

## Seconds a gesture takes to play out.
@export_range(0.3, 4.0, 0.1) var gesture_duration: float = 1.1

var _phase: float = 0.0
var _gesture: StringName = &"none"
var _gesture_time: float = 0.0
var _bones: Dictionary[StringName, int] = {}
var _resolved: bool = false


## Start one of the gestures in `ConversationDirector.TURN_SCHEMA`. `&"none"` and any
## unrecognised name clear whatever was playing.
func play_gesture(gesture: StringName) -> void:
	_gesture = gesture
	_gesture_time = 0.0


## Whether a gesture is still playing out.
func is_gesturing() -> bool:
	return _gesture != &"none"


func _process_modification() -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	if not _resolved:
		_resolve_bones(skeleton)

	var delta: float = get_physics_process_delta_time()
	if energy > 0.0:
		_phase += delta
	if _gesture != &"none":
		_gesture_time += delta
		if _gesture_time >= gesture_duration:
			_gesture = &"none"
			_gesture_time = 0.0

	var offsets: Dictionary[StringName, Quaternion] = {}
	_add_speaking_motion(offsets)
	_add_gesture(offsets)

	for bone: StringName in offsets:
		var index: int = _bones[bone]
		# Compose onto the pose the animation just wrote, rather than replacing it.
		skeleton.set_bone_pose_rotation(
			index, skeleton.get_bone_pose_rotation(index) * offsets[bone]
		)


func _resolve_bones(skeleton: Skeleton3D) -> void:
	_resolved = true
	_bones.clear()
	for bone: StringName in [
		BONE_HEAD, BONE_CHEST, BONE_UPPER_CHEST, BONE_SPINE,
		BONE_SHOULDER_LEFT, BONE_SHOULDER_RIGHT,
	]:
		var index: int = skeleton.find_bone(bone)
		if index != -1:
			_bones[bone] = index


## Head and chest movement while a line plays. Three frequencies with no common period,
## so the motion never settles into a loop the eye can pick out.
func _add_speaking_motion(offsets: Dictionary[StringName, Quaternion]) -> void:
	if is_zero_approx(energy):
		return
	var nod: float = sin(_phase * 7.3) * 0.6 + sin(_phase * 3.1) * 0.4
	var sway: float = sin(_phase * 4.7 + 1.2)
	var tilt: float = sin(_phase * 2.3 + 0.5)

	var head_amount: float = deg_to_rad(head_motion_degrees) * energy
	_accumulate(offsets, BONE_HEAD,
		Quaternion(Vector3.RIGHT, nod * head_amount)
		* Quaternion(Vector3.UP, sway * head_amount * 0.7)
		* Quaternion(Vector3.FORWARD, tilt * head_amount * 0.4))

	var chest_amount: float = deg_to_rad(chest_motion_degrees) * energy
	var chest: StringName = BONE_CHEST if _bones.has(BONE_CHEST) else BONE_UPPER_CHEST
	_accumulate(offsets, chest,
		Quaternion(Vector3.RIGHT, nod * chest_amount * 0.5)
		* Quaternion(Vector3.UP, sway * chest_amount))


## Poses the current gesture. `shape` rises from 0 to 1 and back, so every gesture
## blends out of and back into whatever the body was already doing.
func _add_gesture(offsets: Dictionary[StringName, Quaternion]) -> void:
	if _gesture == &"none":
		return
	var t: float = clampf(_gesture_time / gesture_duration, 0.0, 1.0)
	var shape: float = sin(t * PI)

	match _gesture:
		&"nod":
			# Two dips rather than one, which reads as agreement instead of a flinch.
			var dip: float = sin(t * TAU * 2.0) * shape
			_accumulate(offsets, BONE_HEAD, Quaternion(Vector3.RIGHT, deg_to_rad(14.0) * dip))
		&"shake_head":
			var turn: float = sin(t * TAU * 1.5) * shape
			_accumulate(offsets, BONE_HEAD, Quaternion(Vector3.UP, deg_to_rad(18.0) * turn))
		&"shrug":
			var lift: float = deg_to_rad(16.0) * shape
			_accumulate(offsets, BONE_SHOULDER_LEFT, Quaternion(Vector3.FORWARD, -lift))
			_accumulate(offsets, BONE_SHOULDER_RIGHT, Quaternion(Vector3.FORWARD, lift))
			_accumulate(offsets, BONE_HEAD, Quaternion(Vector3.RIGHT, -deg_to_rad(5.0) * shape))
		&"lean_in":
			_accumulate(offsets, BONE_SPINE, Quaternion(Vector3.RIGHT, deg_to_rad(9.0) * shape))
			_accumulate(offsets, BONE_HEAD, Quaternion(Vector3.RIGHT, deg_to_rad(4.0) * shape))
		&"turn_away":
			_accumulate(offsets, BONE_SPINE, Quaternion(Vector3.UP, deg_to_rad(12.0) * shape))
			_accumulate(offsets, BONE_HEAD, Quaternion(Vector3.UP, deg_to_rad(22.0) * shape))
		&"laugh":
			# Head back, with a faster bob riding on top of it.
			var bob: float = sin(t * TAU * 4.0) * shape
			_accumulate(offsets, BONE_HEAD, Quaternion(
				Vector3.RIGHT, -deg_to_rad(12.0) * shape + deg_to_rad(5.0) * bob
			))
			_accumulate(offsets, BONE_CHEST, Quaternion(Vector3.RIGHT, -deg_to_rad(5.0) * shape))
		&"point":
			# Without an arm clip this is a lean and a look rather than a raised hand,
			# which still directs attention without the arm snapping to a pose.
			_accumulate(offsets, BONE_SPINE, Quaternion(Vector3.UP, -deg_to_rad(8.0) * shape))
			_accumulate(offsets, BONE_HEAD, Quaternion(Vector3.UP, -deg_to_rad(14.0) * shape))


## Composes `rotation_offset` onto whatever `bone` already has, skipping absent bones.
func _accumulate(
	offsets: Dictionary[StringName, Quaternion],
	bone: StringName,
	rotation_offset: Quaternion,
) -> void:
	if not _bones.has(bone):
		return
	offsets[bone] = offsets.get(bone, Quaternion.IDENTITY) * rotation_offset
