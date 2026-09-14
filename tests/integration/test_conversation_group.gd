extends GutTest
## A [ConversationGroup] performing a beat end to end, with no network anywhere.
##
## The beat is injected by emitting the director's own `beat_ready` signal, which is
## exactly what a real reply would do once parsed. That exercises the whole path the
## game uses, the group orders the turns, each [NPC] performs one, the group waits for
## `finished_speaking` and moves on, without a request being made or a character being
## spent.
##
## The villagers are silent here because the lines are not in the voice cache, so each
## turn falls back to its estimated duration. That is itself worth covering: a keyless
## or offline build has to keep the conversation moving rather than deadlock on a clip
## that never arrives.

## One scene per villager now, because the body is part of the persona rather than a
## shared mannequin recoloured at run time.
const VILLAGER_SCENE: String = "res://scenes/villagers/%s.tscn"

var _group: ConversationGroup
var _smith: NPC
var _baker: NPC


func before_each() -> void:
	_group = ConversationGroup.new()
	_group.group_id = &"test_group"
	_group.location_name = "the test bench"
	_group.autostart = false
	_group.turn_gap = 0.0
	# Keep the group from asking the director for anything of its own accord.
	_group.converse_only_when_player_present = true
	_group.prefetch_at_turns_remaining = 0

	_smith = _make_npc("smith")
	_baker = _make_npc("baker")
	var members: Array[NPC] = []
	members.append(_smith)
	members.append(_baker)
	_group.npcs = members

	add_child_autofree(_group)
	_group.add_child(_smith)
	_group.add_child(_baker)
	await wait_frames(2)


func _make_npc(persona_id: String) -> NPC:
	var scene: PackedScene = load(VILLAGER_SCENE % persona_id)
	assert_not_null(scene, "the %s villager scene should exist" % persona_id)
	var npc: NPC = scene.instantiate()
	assert_not_null(npc.persona, "the %s villager should carry its persona" % persona_id)
	return npc


func _beat() -> Array[ConversationTurn]:
	var turns: Array[ConversationTurn] = []
	turns.append(ConversationTurn.new(&"baker", "Two loaves she bought.", &"amused", &"lean_in"))
	turns.append(ConversationTurn.new(&"smith", "Then she was feeding someone.", &"neutral", &"shrug"))
	turns.append(ConversationTurn.new(&"baker", "That is what I said.", &"weary", &"none"))
	return turns


func test_the_group_wires_itself_to_its_villagers() -> void:
	assert_eq(_group.npcs.size(), 2)
	assert_eq(_smith.persona_id(), &"smith")
	assert_eq(_baker.persona_id(), &"baker")


func test_a_delivered_beat_is_performed_in_order() -> void:
	ConversationDirector.beat_ready.emit(&"test_group", _beat())
	await wait_frames(2)

	assert_true(_group.is_performing(), "the group should be performing the beat")
	var transcript: Array[ConversationTurn] = _group.transcript()
	assert_gt(transcript.size(), 0, "the first turn should be recorded immediately")
	assert_eq(transcript[0].speaker, &"baker", "the beat opens with the baker")
	assert_true(_baker.is_speaking(), "the baker should be the one talking")
	assert_false(_smith.is_speaking(), "only one villager talks at a time")


func test_a_beat_for_another_group_is_ignored() -> void:
	ConversationDirector.beat_ready.emit(&"some_other_group", _beat())
	await wait_frames(2)
	assert_false(_group.is_performing())
	assert_eq(_group.transcript().size(), 0)


func test_turns_naming_an_absent_villager_are_skipped_not_stalled() -> void:
	var turns: Array[ConversationTurn] = []
	turns.append(ConversationTurn.new(&"nobody", "I am not in this scene.", &"neutral", &"none"))
	turns.append(ConversationTurn.new(&"smith", "Never mind him.", &"neutral", &"none"))
	ConversationDirector.beat_ready.emit(&"test_group", turns)
	await wait_frames(2)

	assert_true(_smith.is_speaking(), "the group should skip past the unknown speaker")
	for turn: ConversationTurn in _group.transcript():
		assert_ne(turn.speaker, &"nobody", "an unknown speaker should not be recorded")


func test_interrupting_stops_the_speaker_and_drops_the_rest() -> void:
	ConversationDirector.beat_ready.emit(&"test_group", _beat())
	await wait_frames(2)
	assert_true(_group.is_performing())

	_group.interrupt()
	await wait_frames(2)
	assert_false(_group.is_performing(), "an interrupted group stops performing")
	assert_false(_baker.is_speaking(), "the speaker is cut off")
	assert_gt(_group.transcript().size(), 0, "what was already said is kept")


func test_a_failed_beat_falls_back_to_the_authored_lines() -> void:
	_group.fallback_lines = PackedStringArray([
		"smith: Irons cost what they cost.",
		"baker: And you shall have it.",
	])
	ConversationDirector.beat_failed.emit(&"test_group", "no API key")
	await wait_frames(2)

	assert_true(_group.is_performing(), "the village should not fall silent")
	assert_gt(_group.transcript().size(), 0)


func test_a_failed_beat_with_no_fallback_stays_quiet() -> void:
	_group.fallback_lines = PackedStringArray()
	ConversationDirector.beat_failed.emit(&"test_group", "no API key")
	await wait_frames(2)
	assert_false(_group.is_performing())


## A beat where one villager is given more lines than their allowance.
func _greedy_beat() -> Array[ConversationTurn]:
	var turns: Array[ConversationTurn] = []
	for i: int in 5:
		turns.append(ConversationTurn.new(&"baker", "Line %d." % i, &"neutral", &"none"))
	return turns


func test_a_delivered_beat_is_performed_whole() -> void:
	# The allowance constrains what is asked for, never what is played. Dropping turns
	# out of a finished beat threw away the half it was building towards and left
	# exchanges ending on a line that was obviously waiting for a reply.
	_group.begin_interaction()
	ConversationDirector.beat_ready.emit(&"test_group", _greedy_beat())
	await wait_frames(2)
	await wait_seconds(7.0)

	var spoken: int = 0
	for turn: ConversationTurn in _group.transcript():
		if turn.speaker == &"baker":
			spoken += 1
	assert_eq(spoken, 5, "every turn of a delivered beat should be performed")


func test_the_allowance_is_offered_to_the_director() -> void:
	# How the limit is actually enforced: the model is told the room it has and writes a
	# beat that finishes inside it.
	_group.begin_interaction()
	var situation: Dictionary = _group._situation()
	assert_true(situation.has("allowance"), "the situation should carry the allowance")
	var allowance: Dictionary = situation["allowance"]
	assert_eq(allowance.size(), 2, "both villagers should be listed")
	for who: String in allowance:
		assert_eq(
			int(allowance[who]), _group.max_turns_per_villager,
			"%s should start an interaction with a full allowance" % who,
		)


func test_the_allowance_shrinks_as_they_speak() -> void:
	_group.begin_interaction()
	ConversationDirector.beat_ready.emit(&"test_group", _beat())
	await wait_frames(2)
	await wait_seconds(5.0)

	var allowance: Dictionary = _group._situation()["allowance"]
	assert_lt(
		int(allowance[_baker.persona.display_name]), _group.max_turns_per_villager,
		"the baker has spoken, so she should have less room left",
	)


func test_a_spent_group_asks_for_nothing_more() -> void:
	_group.begin_interaction()
	var spend_everyone: Array[ConversationTurn] = []
	for i: int in _group.max_turns_per_villager:
		spend_everyone.append(ConversationTurn.new(&"baker", "Baker %d." % i))
		spend_everyone.append(ConversationTurn.new(&"smith", "Smith %d." % i))
	ConversationDirector.beat_ready.emit(&"test_group", spend_everyone)
	await wait_frames(2)
	await wait_seconds(7.0)
	assert_false(_group._anyone_may_speak(), "everyone should be spent")

	# The group must go quiet rather than keep buying beats nobody may perform.
	watch_signals(_group)
	_group._request_beat()
	await wait_frames(2)
	assert_signal_not_emitted(_group, "beat_started")


func test_speaking_to_them_gives_the_allowance_back() -> void:
	_group.begin_interaction()
	ConversationDirector.beat_ready.emit(&"test_group", _greedy_beat())
	await wait_frames(2)
	await wait_seconds(6.0)
	var before: int = _group.transcript().size()

	# A direct question always earns an answer, whatever was said a moment ago. Refusing
	# to reply because of an internal budget reads as the game being broken.
	_group.hear_player("Maud, what did she buy?", _baker)
	await wait_frames(2)
	assert_true(
		_group._may_speak(&"baker"),
		"being spoken to should give the villager their lines back",
	)
	assert_gt(_group.transcript().size(), before, "the player's line joins the transcript")


func test_arriving_gives_the_allowance_back() -> void:
	_group.begin_interaction()
	ConversationDirector.beat_ready.emit(&"test_group", _greedy_beat())
	await wait_frames(2)
	await wait_seconds(6.0)
	assert_false(_group._may_speak(&"baker"), "the baker should be spent")

	_group.begin_interaction()
	assert_true(_group._may_speak(&"baker"), "walking up again should reset them")


func test_the_villagers_turn_to_face_whoever_is_speaking() -> void:
	ConversationDirector.beat_ready.emit(&"test_group", _beat())
	await wait_frames(2)
	# The listener tracks the speaker; the speaker tracks nobody.
	assert_true(_baker.is_speaking())
	assert_false(_smith.is_speaking())
