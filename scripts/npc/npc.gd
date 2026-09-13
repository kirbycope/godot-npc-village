class_name NPC
extends CharacterBody3D
## One villager: a body, a voice, and a persona.
##
## The NPC knows nothing about how conversations are written. A [ConversationGroup]
## hands it a [ConversationTurn] and it performs it: it asks [VoiceService] for the
## audio, plays it, shows the subtitle, turns to whoever it is talking to, and moves
## while it speaks. It reports back with [signal finished_speaking] so the group knows
## when to move on, and that signal always fires exactly once per line however the line
## ends, so a group can never deadlock waiting on a villager.
##
## The movement itself belongs to a [SpeakingModifier] on the skeleton. The NPC only
## says how much to move and which gesture to make; see that class for why the posing
## has to happen there rather than here.

## This villager began a line. The subtitle layer listens for this.
signal started_speaking(npc: NPC, turn: ConversationTurn)

## The line finished, was cut off, or never got audio.
signal finished_speaking(npc: NPC)

## Who this villager is. Assign a `.tres` from `resources/personas/`.
@export var persona: NPCPersona

@export_group("Nodes")
@export var animation_player: AnimationPlayer
@export var speaking_modifier: SpeakingModifier
@export var voice_player: AudioStreamPlayer3D
@export var subtitle: Label3D
@export var name_plate: Label3D

@export_group("Behaviour")

## Looping clip played when the villager has nothing to say.
##
## Note the names have no `_Loop` suffix even though the source clips do. Godot's glTF
## importer treats that suffix as an instruction, setting the animation to loop and
## dropping it from the name, so `Idle_Loop` in the pack arrives as `Idle` here.
@export var idle_animation: StringName = &"ual1/Idle"

## Looping clip played while a line is being spoken. When the rig has this clip the
## villager is animated by it and the procedural sway in [SpeakingModifier] is left
## switched off, because two things driving the same bones fight each other. When it is
## missing the procedural sway takes over, so a rig without a talking animation still
## moves while it speaks.
@export var talking_animation: StringName = &"ual1/Idle_Talking"

## Seconds to cross-fade between the idle and talking loops.
@export_range(0.0, 1.0, 0.05) var animation_blend: float = 0.25

## Gestures from the dialogue schema mapped to one-shot clips. Only some gestures have a
## clip in the animation library; anything left unmapped here is posed procedurally by
## [SpeakingModifier] instead, so every gesture the model can ask for is expressed one
## way or the other.
@export var gesture_animations: Dictionary[StringName, StringName] = {
	&"nod": &"ual2/Yes",
	&"shake_head": &"ual2/Idle_No",
}

## Degrees per second the villager turns to face whoever is speaking.
@export_range(30.0, 720.0, 10.0) var turn_speed_degrees: float = 220.0

## How quickly the speaking motion rises and settles.
@export_range(1.0, 20.0, 0.5) var motion_damping: float = 6.0

var _speaking: bool = false
var _current_handle: int = 0
var _current_turn: ConversationTurn
var _look_target: Node3D


func _ready() -> void:
	if persona != null and is_instance_valid(name_plate):
		name_plate.text = persona.display_name
	_select_outfit_parts()
	if is_instance_valid(subtitle):
		subtitle.text = ""
		subtitle.visible = false
	_play_base_animation()
	VoiceService.clip_ready.connect(_on_clip_ready)
	VoiceService.clip_failed.connect(_on_clip_failed)
	if is_instance_valid(voice_player):
		voice_player.finished.connect(_on_voice_finished)


## Hides the parts of the outfit this villager is not wearing.
##
## The meshes are hidden rather than freed so the choice stays reversible at run time,
## and because a hidden MeshInstance3D costs nothing to draw.
func _select_outfit_parts() -> void:
	if persona == null:
		return
	if persona.outfit_prefix.is_empty() and persona.hidden_parts.is_empty():
		return
	var meshes: Array[Node] = find_children("*", "MeshInstance3D", true, false)
	for node: MeshInstance3D in meshes:
		var mesh_name: String = node.name
		var wanted: bool = (
			persona.outfit_prefix.is_empty()
			or mesh_name.begins_with(persona.outfit_prefix)
		)
		if wanted:
			for part: String in persona.hidden_parts:
				if mesh_name.ends_with(part):
					wanted = false
					break
		node.visible = wanted


func _physics_process(delta: float) -> void:
	_face_look_target(delta)
	_drive_speaking_energy(delta)


## Whether the rig has a real talking clip, which decides who animates the speaking:
## the animation player or the procedural modifier.
func _has_talking_animation() -> bool:
	return (
		is_instance_valid(animation_player)
		and animation_player.has_animation(talking_animation)
	)


## Plays whichever loop matches the villager's current state.
func _play_base_animation() -> void:
	if not is_instance_valid(animation_player):
		return
	var wanted: StringName = idle_animation
	if _speaking and _has_talking_animation():
		wanted = talking_animation
	if not animation_player.has_animation(wanted):
		return
	if animation_player.current_animation == String(wanted):
		return
	animation_player.play(wanted, animation_blend)


## The persona's id, or "" when none is assigned.
func persona_id() -> StringName:
	return persona.id if persona != null else &""


## Whether a line is currently being performed.
func is_speaking() -> bool:
	return _speaking


## Perform `turn`. Emits [signal finished_speaking] exactly once, whatever happens.
func speak(turn: ConversationTurn) -> void:
	if _speaking:
		stop_speaking()
	if turn == null or not turn.is_valid():
		finished_speaking.emit(self)
		return

	_speaking = true
	_current_turn = turn
	started_speaking.emit(self, turn)

	if is_instance_valid(subtitle):
		subtitle.text = turn.line
		subtitle.visible = true
	_perform_gesture(turn.gesture)

	_play_base_animation()
	_current_handle = VoiceService.speak(turn.line, persona)
	if _current_handle == 0:
		# No voice available. The line still reads on screen, paced by its length, so
		# a keyless build is a silent film rather than a broken one.
		_finish_after(turn.estimated_duration())


## Plays `gesture` as a one-shot clip when the library has one, and hands it to the
## procedural modifier when it does not.
func _perform_gesture(gesture: StringName) -> void:
	if gesture == &"none":
		return
	var clip: StringName = gesture_animations.get(gesture, &"")
	if (
		clip != &""
		and is_instance_valid(animation_player)
		and animation_player.has_animation(clip)
	):
		animation_player.play(clip, animation_blend)
		# Return to the speaking loop once the gesture has played out.
		var length: float = animation_player.get_animation(clip).length
		var timer: SceneTreeTimer = get_tree().create_timer(minf(length, 1.6))
		timer.timeout.connect(_play_base_animation)
		return
	if is_instance_valid(speaking_modifier):
		speaking_modifier.play_gesture(gesture)


## Cut the current line short. Safe to call when nothing is being said.
func stop_speaking() -> void:
	if not _speaking:
		return
	if is_instance_valid(voice_player) and voice_player.playing:
		voice_player.stop()
	_conclude()


## Turn to face `target` while talking. Pass null to stop tracking.
func look_at_node(target: Node3D) -> void:
	_look_target = target


## The modifier only moves the body while a clip is actually audible, so a villager
## waiting on a slow request stands still rather than miming to silence.
func _drive_speaking_energy(delta: float) -> void:
	if not is_instance_valid(speaking_modifier):
		return
	var wanted: float = 0.0
	if (
		_speaking
		and not _has_talking_animation()
		and is_instance_valid(voice_player)
		and voice_player.playing
	):
		wanted = 1.0
	speaking_modifier.energy = move_toward(
		speaking_modifier.energy, wanted, delta * motion_damping
	)


func _face_look_target(delta: float) -> void:
	if not is_instance_valid(_look_target):
		return
	var to_target: Vector3 = _look_target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.01:
		return
	var wanted: float = atan2(to_target.x, to_target.z)
	rotation.y = rotate_toward(rotation.y, wanted, deg_to_rad(turn_speed_degrees) * delta)


func _on_clip_ready(handle: int, stream: AudioStream, _from_cache: bool) -> void:
	if handle != _current_handle or not _speaking:
		return
	if not is_instance_valid(voice_player):
		_finish_after(_current_turn.estimated_duration())
		return
	voice_player.stream = stream
	voice_player.pitch_scale = persona.voice_pitch if persona != null else 1.0
	voice_player.play()


func _on_clip_failed(handle: int, reason: String) -> void:
	if handle != _current_handle or not _speaking:
		return
	# The line is still worth reading even when it cannot be heard.
	push_warning("[NPC %s] voice failed: %s" % [persona_id(), reason])
	_finish_after(_current_turn.estimated_duration())


func _on_voice_finished() -> void:
	if _speaking:
		_conclude()


## Ends the line after `seconds`, used whenever there is no clip whose end to wait on.
func _finish_after(seconds: float) -> void:
	var timer: SceneTreeTimer = get_tree().create_timer(seconds)
	timer.timeout.connect(_conclude)


func _conclude() -> void:
	if not _speaking:
		return
	_speaking = false
	_current_handle = 0
	_current_turn = null
	if is_instance_valid(subtitle):
		subtitle.visible = false
		subtitle.text = ""
	_play_base_animation()
	finished_speaking.emit(self)
