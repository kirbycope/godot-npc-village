class_name PlayerVoice
extends Node3D
## Push to talk: hold a key, speak, and the nearest villager answers.
##
## Holding the `talk_to_npc` action opens the microphone through [SpeechService]. On
## release the recording is transcribed, the nearest villager within [member speak_range]
## is found, and the line is handed to that villager's [ConversationGroup], which asks
## the dialogue model for a reply.
##
## Whoever you were standing closest to answers first. The others in that group are sent
## along with them and join in only if they have something of their own to add, which is
## the director's judgement rather than this node's: the prompt tells it that a villager
## with nothing to say should stay out of it, and that a beat where only one of them
## speaks is a perfectly good beat.
##
## Only the nearest villager's group is told. A villager from a different group standing
## inside the range would have to be near enough to be in this one anyway, and notifying
## every group in earshot would buy several replies to one question, each costing a
## request and a run of synthesis, for a conversation the player only asked one of.

## The microphone opened.
signal started_listening()

## The microphone closed; the transcript has not arrived yet.
signal stopped_listening()

## The player's line was understood and delivered to `group`.
signal spoke(line: String, addressed: NPC)

## Nothing usable came of it. `reason` is safe to show on screen.
signal failed(reason: String)

## How far a villager can be and still be the one you are talking to. Five yards.
@export_range(1.0, 20.0, 0.1) var speak_range: float = 4.6

## The action to hold. Bound to T in the project's input map.
@export var action: StringName = &"talk_to_npc"

var _player: Node3D
var _pressed: bool = false


func _ready() -> void:
	SpeechService.transcribed.connect(_on_transcribed)
	SpeechService.transcription_failed.connect(_on_failed)
	SpeechService.listening_started.connect(func() -> void: started_listening.emit())
	SpeechService.listening_stopped.connect(func(_s: float) -> void: stopped_listening.emit())
	_find_player.call_deferred()


func _find_player() -> void:
	_player = get_tree().get_first_node_in_group("player")
	if _player == null:
		push_warning("[PlayerVoice] No node in the 'player' group; push to talk is adrift.")


## Held rather than toggled, and read in `_unhandled_input` so a focused text field or a
## menu takes the key first.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action(action):
		return
	if event.is_action_pressed(action) and not _pressed:
		_pressed = true
		SpeechService.start_listening()
		get_viewport().set_input_as_handled()
	elif event.is_action_released(action) and _pressed:
		_pressed = false
		SpeechService.stop_listening()
		get_viewport().set_input_as_handled()


## The villager nearest the player, or null when nobody is close enough.
func nearest_villager() -> NPC:
	if not is_instance_valid(_player):
		return null
	var best: NPC = null
	var best_distance: float = speak_range * speak_range
	for node: Node in get_tree().get_nodes_in_group("villagers"):
		var npc: NPC = node as NPC
		if npc == null or not npc.is_inside_tree():
			continue
		var distance: float = npc.global_position.distance_squared_to(_player.global_position)
		if distance <= best_distance:
			best_distance = distance
			best = npc
	return best


## The conversation group `npc` belongs to, found by walking up from the villager rather
## than by a fixed path, so a villager can be reparented without breaking this.
func _group_of(npc: NPC) -> ConversationGroup:
	var node: Node = npc.get_parent()
	while node != null:
		var group: ConversationGroup = node as ConversationGroup
		if group != null:
			return group
		node = node.get_parent()
	return null


func _on_transcribed(text: String) -> void:
	var villager: NPC = nearest_villager()
	if villager == null:
		failed.emit("nobody close enough to hear you")
		return
	var group: ConversationGroup = _group_of(villager)
	if group == null:
		failed.emit("%s is not part of a conversation" % villager.persona_id())
		return
	group.hear_player(text, villager)
	spoke.emit(text, villager)


func _on_failed(reason: String) -> void:
	failed.emit(reason)
