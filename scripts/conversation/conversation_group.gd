class_name ConversationGroup
extends Node3D
## A place in the village where villagers stand and talk to each other.
##
## The group owns the loop: ask [ConversationDirector] for a beat, perform it turn by
## turn through the [NPC] nodes, pause, ask for the next one. It holds the transcript
## so each beat continues from what was actually said rather than starting over.
##
## The player is part of the situation, not an interruption to it. Walking into the
## group's [Area3D] cuts the remaining turns of the current beat and asks for a fresh
## one that knows someone is listening, so the villagers change the subject, lower
## their voices, or greet you as their characters would. Walking away does the same in
## reverse. Cutting a beat mid-way is deliberate: a beat is a guess about a moment, and
## once the moment changes the rest of the guess is wrong.

## The group started performing a beat.
signal beat_started(group: ConversationGroup)

## The group ran out of turns and is waiting before asking for more.
signal beat_ended(group: ConversationGroup)

## A villager began a line. Mirrored from the NPC so a HUD can listen to the group.
signal turn_started(npc: NPC, turn: ConversationTurn)

## Identifies this group to the director and in the rate limiter.
@export var group_id: StringName = &"group"

## Where this is, in words, for the prompt. "the market fountain", "outside the smithy".
@export var location_name: String = "the village"

## Optional nudge for what these villagers are chewing over. Leave empty to let them
## find their own subject from their personas.
@export_multiline var topic: String = ""

@export_group("Nodes")

## The villagers in this group. They speak in whatever order the model chooses.
@export var npcs: Array[NPC] = []

## Detects the player. Its `body_entered` and `body_exited` are wired in the scene.
@export var player_area: Area3D

@export_group("Pacing")

## Seconds between one villager finishing and the next starting.
@export_range(0.0, 4.0, 0.1) var turn_gap: float = 0.55

## Seconds to wait after a beat before asking for another.
@export_range(0.0, 120.0, 1.0) var beat_cooldown: float = 8.0

## Ask for the next beat once this many turns of the current one are left. A beat takes
## the model six or seven seconds to write, which is long enough to hear as a gap if
## the request only starts when the villagers run out of things to say. Starting it
## with a couple of turns still to perform hides the whole round trip behind dialogue
## that is already playing. Set to 0 to request only after a beat ends.
@export_range(0, 5, 1) var prefetch_at_turns_remaining: int = 2

## Only hold a conversation while the player is inside `player_area`.
##
## On by default, and it is the single most important setting in this project. Every
## beat costs Claude tokens to write and ElevenLabs characters to speak, and both are
## metered. A village of three groups left chattering to an empty square spent 12.6% of
## a month's voice quota in one idle test run, which buys nothing: there was nobody
## there to hear a word of it. With this on, the village is quiet until you walk into
## it and the whole budget goes on conversations that actually reach the player.
##
## Turn it off for a group that must be audible from a distance, and raise
## `unattended_cooldown` well up if you do.
@export var converse_only_when_player_present: bool = true

## Seconds added to the cooldown when the player is nowhere near. Only reached when
## `converse_only_when_player_present` is off.
@export_range(0.0, 900.0, 5.0) var unattended_cooldown: float = 240.0

## How many lines each villager may speak in one interaction.
##
## An interaction starts when the player walks up and again every time they speak, and
## when every villager present has used their allowance the group falls quiet until one
## of those happens. Without it a group left standing next to the player talks
## indefinitely, and every line is a request to write it and characters to speak it: one
## unattended run spent a session's whole voice budget on conversation nobody asked for.
##
## Two is enough for an exchange to land and short enough that the village stays a place
## you visit rather than a radio left on.
@export_range(1, 10, 1) var max_turns_per_villager: int = 3

## Start talking as soon as the scene loads. Ignored while
## `converse_only_when_player_present` is on, since arrival is what starts a beat then.
@export var autostart: bool = true

var _transcript: Array[ConversationTurn] = []
var _pending: Array[ConversationTurn] = []
## A beat that arrived while the previous one was still being performed.
var _prefetched: Array[ConversationTurn] = []
var _speaker: NPC
var _player_present: bool = false
var _running: bool = false
var _waiting_for_beat: bool = false
var _cooldown_timer: Timer

## What the player said that this group has not yet answered.
var _player_line: String = ""

## The villager the player was nearest to when they said it.
var _addressed: StringName = &""

## Lines spoken by each villager since this interaction began.
var _turns_taken: Dictionary[StringName, int] = {}

## Whether the authored opening has been performed yet.
var _opening_spent: bool = false

## Whether the one closing line allowed past the cap has been used this interaction.
var _wrap_up_used: bool = false

## True while the authored opening is playing. Its turns do not count against anyone's
## allowance: they are written by hand and already paid for in the voice bank, so
## charging them to the budget would use the whole interaction up before the model got
## a word in, which is the opposite of what an opening is for.
var _performing_opening: bool = false


func _ready() -> void:
	_cooldown_timer = Timer.new()
	_cooldown_timer.one_shot = true
	_cooldown_timer.timeout.connect(_request_beat)
	add_child(_cooldown_timer)

	ConversationDirector.beat_ready.connect(_on_beat_ready)
	ConversationDirector.beat_failed.connect(_on_beat_failed)

	for npc: NPC in npcs:
		if is_instance_valid(npc):
			npc.finished_speaking.connect(_on_npc_finished)
			npc.engaged.connect(_on_npc_engaged)

	if autostart and not converse_only_when_player_present:
		# A short stagger keeps every group in the village from requesting at once.
		_cooldown_timer.start(randf_range(0.5, 3.0))


## Whether a beat is currently being performed.
func is_performing() -> bool:
	return _running


## Everything said in this group so far.
func transcript() -> Array[ConversationTurn]:
	return _transcript.duplicate()


## Stop talking and drop the remaining turns. The transcript is kept.
func interrupt() -> void:
	_pending.clear()
	_prefetched.clear()
	_performing_opening = false
	_show_thinking(false)
	if is_instance_valid(_speaker):
		_speaker.stop_speaking()
	_speaker = null
	if _running:
		_running = false
		beat_ended.emit(self)


## Called from the scene when a body enters `player_area`.
func _on_player_area_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player") or _player_present:
		return
	_player_present = true
	_face_player(body)
	begin_interaction()
	_restart_for_changed_situation()


## Called from the scene when a body leaves `player_area`.
func _on_player_area_body_exited(body: Node3D) -> void:
	if not body.is_in_group("player") or not _player_present:
		return
	_player_present = false
	if converse_only_when_player_present:
		# Let the current line finish so the conversation fades out behind you rather
		# than being cut off the instant you step away. Walking off also ends the
		# interaction: coming back starts a new one, with its allowance and its voice
		# budget restored.
		_pending.clear()
		_prefetched.clear()
		_opening_spent = _opening_spent and _transcript.size() > _opening_beat().size()
		return
	_restart_for_changed_situation()


## The situation changed under the current beat, so the rest of it no longer fits.
func _restart_for_changed_situation() -> void:
	if _waiting_for_beat:
		return
	interrupt()
	_cooldown_timer.stop()
	_cooldown_timer.start(randf_range(0.4, 1.2))


func _request_beat() -> void:
	if _waiting_for_beat or npcs.size() < 2 or not _prefetched.is_empty():
		return

	# The seed. Each villager's hand-written opening line, in the order they stand, said
	# once before the model is asked for anything. It goes into the transcript, so the
	# model continues from it.
	if not _opening_spent and _player_line.is_empty():
		_opening_spent = true
		_pending = _opening_beat()
		if not _pending.is_empty():
			_performing_opening = true
			_running = true
			beat_started.emit(self)
			_advance()
			return
	if converse_only_when_player_present and not _player_present and _player_line.is_empty():
		return
	if not _anyone_may_speak():
		# Everyone here has said their piece. Nothing more is written or spoken until the
		# player says something or walks away and comes back.
		return
	var personas: Array[NPCPersona] = []
	for npc: NPC in npcs:
		if is_instance_valid(npc) and npc.persona != null:
			personas.append(npc.persona)
	if personas.size() < 2:
		return
	_waiting_for_beat = true
	_show_thinking(true)
	ConversationDirector.request_beat(group_id, personas, _situation(), _transcript)


## The player spoke aloud near `addressed`, who belongs to this group.
##
## The line joins the transcript as a turn like any other, so the villagers remember it
## and can refer back to it later in the conversation. Whatever they were saying is cut
## off: being talked to is exactly the kind of change that makes the rest of a planned
## beat wrong, and a villager who finishes their sentence before acknowledging you reads
## as deaf rather than as busy.
func hear_player(line: String, addressed: NPC) -> void:
	var spoken: String = line.strip_edges()
	if spoken.is_empty():
		return
	_transcript.append(ConversationTurn.new(&"player", spoken))
	# Being spoken to always earns a fresh hearing, even from a villager who had used
	# up their allowance a moment ago. Refusing to answer a direct question because of
	# an internal budget reads as the game being broken.
	begin_interaction()
	_player_line = spoken
	_addressed = addressed.persona_id() if is_instance_valid(addressed) else &""
	interrupt()
	_cooldown_timer.stop()
	_cooldown_timer.start(0.15)


## The player engaged a villager of this group by hand. Everyone gets their lines back
## and the conversation picks up again.
func _on_npc_engaged(_npc: NPC) -> void:
	begin_interaction()
	if not _running:
		_cooldown_timer.stop()
		_cooldown_timer.start(0.15)


## Gives every villager here their lines back. Called when the player arrives, when they
## speak, and when they engage a villager directly.
func begin_interaction() -> void:
	_turns_taken.clear()
	_wrap_up_used = false
	# The voice budget resets with the conversation. Walking away and coming back is the
	# player saying they want more of this, and the villagers being mute for the rest of
	# the evening because of a counter that never resets is not a decision anybody made.
	VoiceService.begin_interaction()


## Raises or lowers the "..." over everyone in the group.
##
## Only while a beat is actually being written. A prefetch happens behind dialogue that
## is already playing, so putting the bubble up for that would show it over a villager in
## the middle of a sentence.
func _show_thinking(thinking: bool) -> void:
	var wanted: bool = thinking and not _running
	for npc: NPC in npcs:
		if is_instance_valid(npc):
			npc.set_group_thinking(wanted)


## Whether `id` has anything left to say in this interaction.
func _may_speak(id: StringName) -> bool:
	return _turns_taken.get(id, 0) < max_turns_per_villager


## Whether anyone here still has a line left.
func _anyone_may_speak() -> bool:
	for npc: NPC in npcs:
		if is_instance_valid(npc) and _may_speak(npc.persona_id()):
			return true
	return false


## Whether anyone would still have a line left once the beat in hand has finished.
##
## Prefetching asks the model for the next beat while the current one is still playing,
## which hides the round trip. Asking on the strength of the allowance as it stands now
## buys a beat that the allowance will have run out for by the time it could be played,
## so it is written, paid for, and thrown away: one wasted request per interaction.
func _anyone_may_speak_after_pending() -> bool:
	var projected: Dictionary[StringName, int] = _turns_taken.duplicate()
	for turn: ConversationTurn in _pending:
		projected[turn.speaker] = projected.get(turn.speaker, 0) + 1
	for npc: NPC in npcs:
		if not is_instance_valid(npc):
			continue
		if projected.get(npc.persona_id(), 0) < max_turns_per_villager:
			return true
	return false


## What the director needs to know about this moment. Time and weather are read from
## the addons when they are present, so the villagers comment on real conditions.
func _situation() -> Dictionary:
	var situation: Dictionary = {
		"location": location_name,
		"player_present": _player_present,
		"topic": topic,
	}
	# How many lines each villager has left. The director writes a beat that fits inside
	# this rather than the group cutting one short afterwards: a beat is a whole thought,
	# and dropping its last turns throws away the half where it lands. An exchange that
	# ended on "his money was good" instead of the reply it was setting up was what made
	# the dialogue read as nonsense.
	var allowance: Dictionary = {}
	for npc: NPC in npcs:
		if is_instance_valid(npc) and npc.persona != null:
			allowance[npc.persona.display_name] = maxi(
				0, max_turns_per_villager - _turns_taken.get(npc.persona_id(), 0)
			)
	situation["allowance"] = allowance

	if not _player_line.is_empty():
		situation["player_line"] = _player_line
		var speaker: NPC = _find_npc(_addressed)
		if speaker != null and speaker.persona != null:
			situation["addressed"] = speaker.persona.display_name
		# Consumed here: the next beat after this one is ordinary conversation again.
		_player_line = ""
		_addressed = &""
	var clock: Node = get_tree().get_first_node_in_group("date_and_time")
	if clock != null and clock.has_method("get_hour"):
		situation["time_of_day"] = _describe_hour(int(clock.call("get_hour")))
	var weather: Node = get_tree().get_first_node_in_group("weather_fx")
	if weather != null:
		# The addon calls it `active_weather`; `current_weather` is only a signal argument.
		var kind: Variant = weather.get("active_weather")
		if kind != null:
			situation["weather"] = _describe_weather(int(kind))
	if weather != null:
		var temperature: Variant = weather.get("current_temperature")
		if temperature != null:
			situation["temperature"] = "%d degrees" % int(temperature)
	return situation


## Turns a clock hour into the words a villager would actually use. Nobody in a medieval
## village says "fourteen hundred hours", and the dialogue model writes better lines from
## "mid-afternoon" than from a number.
func _describe_hour(hour: int) -> String:
	if hour < 5:
		return "the small hours, long before dawn"
	if hour < 7:
		return "first light"
	if hour < 11:
		return "morning"
	if hour < 13:
		return "midday"
	if hour < 16:
		return "mid-afternoon"
	if hour < 19:
		return "late afternoon, the light going"
	if hour < 21:
		return "dusk"
	return "after dark"


## The WeatherFX weather enum in words. Kept as a local table rather than calling the
## addon's own helper so a project without WeatherFX still compiles.
func _describe_weather(kind: int) -> String:
	match kind:
		0:
			return "clear skies"
		1:
			return "overcast"
		2:
			return "raining"
		3:
			return "heavy rain"
		4:
			return "a thunderstorm"
		5:
			return "snowing"
		6:
			return "heavy snow"
	return "unsettled"


func _on_beat_ready(group_id_in: StringName, turns: Array[ConversationTurn]) -> void:
	if group_id_in != group_id:
		return
	_waiting_for_beat = false
	_show_thinking(false)
	if _running:
		# Prefetched. It waits its turn rather than interrupting what is being said.
		_prefetched = turns.duplicate()
		return
	_pending = turns.duplicate()
	if _pending.is_empty():
		_schedule_next()
		return
	_running = true
	beat_started.emit(self)
	_advance()


## Nothing more is said. The villagers have already spoken their authored opening lines
## by this point, which is what a build with no model or no key has to offer; inventing a
## murmur to fill the gap would only be a worse version of what they already said.
func _on_beat_failed(group_id_in: StringName, reason: String) -> void:
	if group_id_in != group_id:
		return
	_waiting_for_beat = false
	_show_thinking(false)
	push_warning("[ConversationGroup %s] %s" % [group_id, reason])
	if _running:
		return
	_schedule_next()


## The villagers' authored opening lines, taken from the committed voice bank.
##
## The bank's manifest is where the authored dialogue lives, so a line that has been
## baked is both the text and the clip: the opening is spoken aloud without a key, a
## request or a character of quota. A villager with nothing baked simply does not open.
##
## Ordered by each line's `opening_order` so a written exchange plays as written, rather
## than in whatever order the villagers happen to stand.
func _opening_beat() -> Array[ConversationTurn]:
	var ordered: Array[Dictionary] = []
	for npc: NPC in npcs:
		if not is_instance_valid(npc) or npc.persona == null:
			continue
		var index: int = 0
		for line: String in VoiceService.opening_lines_for(npc.persona_id()):
			ordered.append({"speaker": npc.persona_id(), "line": line, "order": index})
			index += 1
	ordered.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return int(a["order"]) < int(b["order"])
	)
	var turns: Array[ConversationTurn] = []
	for entry: Dictionary in ordered:
		turns.append(ConversationTurn.new(entry["speaker"], str(entry["line"])))
	return turns


## Turns "persona_id: line" entries into a beat, in the order they were written.
func _parse_lines(lines: PackedStringArray) -> Array[ConversationTurn]:
	var turns: Array[ConversationTurn] = []
	for entry: String in lines:
		var split: int = entry.find(":")
		if split <= 0:
			continue
		turns.append(ConversationTurn.new(
			StringName(entry.substr(0, split).strip_edges()),
			entry.substr(split + 1).strip_edges(),
		))
	return turns


func _advance() -> void:
	# The cap is checked here, at the moment of speaking, and not only when a beat is
	# asked for. A beat that arrived while the last one was still playing would otherwise
	# be taken up and performed whole however much had been said since, which is how the
	# villagers talked on indefinitely.
	if not _anyone_may_speak() and not _pending.is_empty():
		if _wrap_up_used:
			_pending.clear()
			_prefetched.clear()
		else:
			# One line past the cap, so the exchange closes on a reply rather than
			# stopping dead in the middle of one.
			_wrap_up_used = true
			_pending = _pending.slice(0, 1)
			_prefetched.clear()

	if _pending.is_empty():
		# Whatever comes next is not the opening any more. Clearing this only when a beat
		# ended with nothing queued was the bug behind the villagers never stopping: a
		# beat prefetched while the opening was still playing left the flag set for good,
		# and every line after it was counted as part of the opening, which is to say not
		# counted at all. The allowance never fell, so they always had something left to
		# say.
		_performing_opening = false
		if not _prefetched.is_empty() and _anyone_may_speak():
			# The next beat is already written, so the conversation carries straight on.
			_pending = _prefetched
			_prefetched = []
		else:
			_prefetched.clear()
			_running = false
			_speaker = null
			beat_ended.emit(self)
			_schedule_next()
			return

	var turn: ConversationTurn = _pending.pop_front()
	var npc: NPC = _find_npc(turn.speaker)
	if npc == null:
		# The model named someone who is not here. Skip the turn rather than stall.
		push_warning("[ConversationGroup %s] no villager with id '%s'" % [group_id, turn.speaker])
		_advance()
		return

	if (
		prefetch_at_turns_remaining > 0
		and _pending.size() <= prefetch_at_turns_remaining
		and _prefetched.is_empty()
		and _anyone_may_speak_after_pending()
	):
		_request_beat()

	_transcript.append(turn)
	if not _performing_opening:
		_turns_taken[turn.speaker] = _turns_taken.get(turn.speaker, 0) + 1
	_speaker = npc
	_point_listeners_at(npc)
	turn_started.emit(npc, turn)
	npc.speak(turn)


func _on_npc_finished(_npc: NPC) -> void:
	if not _running:
		return
	if turn_gap <= 0.0:
		_advance()
		return
	var timer: SceneTreeTimer = get_tree().create_timer(turn_gap)
	timer.timeout.connect(_advance)


func _schedule_next() -> void:
	var wait: float = beat_cooldown
	if not _player_present:
		wait += unattended_cooldown
	_cooldown_timer.start(wait)


func _find_npc(id: StringName) -> NPC:
	for npc: NPC in npcs:
		if is_instance_valid(npc) and npc.persona_id() == id:
			return npc
	return null


## Everyone who is not speaking turns to watch whoever is.
func _point_listeners_at(speaker: NPC) -> void:
	for npc: NPC in npcs:
		if not is_instance_valid(npc):
			continue
		npc.look_at_node(null if npc == speaker else speaker)


## When the player joins, the nearest villager acknowledges them by turning first.
func _face_player(player: Node3D) -> void:
	var nearest: NPC = null
	var best: float = INF
	for npc: NPC in npcs:
		if not is_instance_valid(npc):
			continue
		var distance: float = npc.global_position.distance_squared_to(player.global_position)
		if distance < best:
			best = distance
			nearest = npc
	if nearest != null:
		nearest.look_at_node(player)
