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

## Name of the looping clip played underneath everything else.
@export var idle_animation: StringName = &"idle/mixamo_com"

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
	_dress()
	if is_instance_valid(subtitle):
		subtitle.text = ""
		subtitle.visible = false
	if is_instance_valid(animation_player) and animation_player.has_animation(idle_animation):
		animation_player.play(idle_animation)
	VoiceService.clip_ready.connect(_on_clip_ready)
	VoiceService.clip_failed.connect(_on_clip_failed)
	if is_instance_valid(voice_player):
		voice_player.finished.connect(_on_voice_finished)


## Recolours the model's two materials to this persona's clothing. Overrides are set
## per surface on the instance, so every villager shares the one imported mesh and no
## material resource is edited in place. Recolouring the resource would change every
## villager at once, which is the opposite of what is wanted.
func _dress() -> void:
	if persona == null:
		return
	var meshes: Array[Node] = find_children("*", "MeshInstance3D", true, false)
	for node: MeshInstance3D in meshes:
		if node.mesh == null:
			continue
		for surface: int in node.mesh.get_surface_count():
			var source: Material = node.get_active_material(surface)
			if source is not StandardMaterial3D:
				continue
			var material: StandardMaterial3D = (source as StandardMaterial3D).duplicate()
			# Surface 0 is the body, surface 1 the joints, as the mannequin is authored.
			material.albedo_color = persona.tunic_color if surface == 0 else persona.trim_color
			material.roughness = 0.85
			material.metallic = 0.0
			node.set_surface_override_material(surface, material)


func _physics_process(delta: float) -> void:
	_face_look_target(delta)
	_drive_speaking_energy(delta)


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
	if is_instance_valid(speaking_modifier):
		speaking_modifier.play_gesture(turn.gesture)

	_current_handle = VoiceService.speak(turn.line, persona)
	if _current_handle == 0:
		# No voice available. The line still reads on screen, paced by its length, so
		# a keyless build is a silent film rather than a broken one.
		_finish_after(turn.estimated_duration())


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
	if _speaking and is_instance_valid(voice_player) and voice_player.playing:
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
	finished_speaking.emit(self)
