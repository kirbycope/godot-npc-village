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


func test_a_failed_beat_leaves_them_quiet() -> void:
	# There is nothing to fall back to by design. The villagers have already said their
	# authored opening lines, and inventing filler would only be a worse version of them.
	ConversationDirector.beat_failed.emit(&"test_group", "no API key")
	await wait_frames(2)
	assert_false(_group.is_performing())


func test_the_villagers_turn_to_face_whoever_is_speaking() -> void:
	ConversationDirector.beat_ready.emit(&"test_group", _beat())
	await wait_frames(2)
	# The listener tracks the speaker; the speaker tracks nobody.
	assert_true(_baker.is_speaking())
	assert_false(_smith.is_speaking())


## A beat far longer than anyone's allowance, to prove the cap holds however it arrives.
func _overlong_beat() -> Array[ConversationTurn]:
	var turns: Array[ConversationTurn] = []
	for i: int in 12:
		turns.append(ConversationTurn.new(
			&"baker" if i % 2 == 0 else &"smith", "Line %d." % i
		))
	return turns


func test_they_stop_at_the_cap_however_long_the_beat_is() -> void:
	# The villagers talking on and on was a beat being taken up and performed whole
	# regardless of what had already been said, so the limit is checked at the moment of
	# speaking rather than only when a beat is asked for.
	_group.begin_interaction()
	ConversationDirector.beat_ready.emit(&"test_group", _overlong_beat())
	await wait_frames(2)
	await wait_seconds(14.0)

	var spoken: Dictionary = {}
	for turn: ConversationTurn in _group.transcript():
		spoken[turn.speaker] = spoken.get(turn.speaker, 0) + 1
	var total: int = 0
	for who: StringName in spoken:
		total += int(spoken[who])
	# Everyone's allowance, plus the single line allowed to close the exchange.
	var ceiling: int = _group.max_turns_per_villager * 2 + 1
	assert_lte(total, ceiling, "they should stop at the cap, not run on")
	assert_false(_group.is_performing(), "and the beat should be over")


func test_one_line_is_allowed_to_close_the_exchange() -> void:
	# Stopping dead on the cap cuts somebody off mid-reply, so exactly one line past it
	# is permitted to round the exchange off.
	_group.begin_interaction()
	ConversationDirector.beat_ready.emit(&"test_group", _overlong_beat())
	await wait_frames(2)
	await wait_seconds(14.0)

	var total: int = _group.transcript().size()
	assert_gt(total, _group.max_turns_per_villager * 2, "the closing line should be spoken")


func test_engaging_a_villager_gives_everyone_their_lines_back() -> void:
	_group.begin_interaction()
	ConversationDirector.beat_ready.emit(&"test_group", _overlong_beat())
	await wait_frames(2)
	await wait_seconds(14.0)
	assert_false(_group._anyone_may_speak(), "everyone should be spent")

	# Looking at a villager and pressing the action button is the other way in, besides
	# speaking to them.
	_baker.equip(null)
	await wait_frames(2)
	assert_true(_group._anyone_may_speak(), "engaging one of them should reopen the group")


func test_lines_after_the_opening_are_counted() -> void:
	# The opening is deliberately free, but the flag marking it was only cleared when a
	# beat ended with nothing queued. A beat prefetched while the opening was still
	# playing was then taken up with the flag still set, so every line of it counted as
	# part of the opening, which is to say not counted at all, and the villagers never
	# ran out of allowance.
	_group.begin_interaction()
	_group._performing_opening = true
	var opening: Array[ConversationTurn] = []
	opening.append(ConversationTurn.new(&"smith", "An opening line."))
	_group._pending = opening
	# A generated beat arrives while the opening is still going, exactly as prefetch does.
	_group._prefetched = _beat()
	_group._running = true
	_group._advance()
	await wait_frames(2)
	await wait_seconds(9.0)

	assert_false(_group._performing_opening, "the opening flag must not stick")
	var counted: int = 0
	for who: StringName in _group._turns_taken:
		counted += int(_group._turns_taken[who])
	assert_gt(counted, 0, "the beat after the opening has to count against the allowance")
