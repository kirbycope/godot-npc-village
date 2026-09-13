extends GutTest
## [ConversationTurn] parsing and pacing.
##
## Turns arrive from the dialogue model's structured output, so the parser has to cope
## with a well formed entry, an entry missing fields, and an entry whose values are not
## strings at all. The schema constrains what the model may return; it does not protect
## the game from a malformed response, a truncated body, or a fixture edited by hand.


func test_from_dictionary_reads_every_field() -> void:
	var turn: ConversationTurn = ConversationTurn.from_dictionary({
		"speaker": "baker",
		"line": "Two loaves she bought.",
		"emotion": "conspiratorial",
		"gesture": "lean_in",
	})
	assert_eq(turn.speaker, &"baker")
	assert_eq(turn.line, "Two loaves she bought.")
	assert_eq(turn.emotion, &"conspiratorial")
	assert_eq(turn.gesture, &"lean_in")
	assert_true(turn.is_valid(), "a fully populated turn should be valid")


func test_from_dictionary_trims_surrounding_whitespace() -> void:
	var turn: ConversationTurn = ConversationTurn.from_dictionary({
		"speaker": "smith",
		"line": "   Six silver, Maud.\n",
	})
	assert_eq(turn.line, "Six silver, Maud.")


func test_missing_fields_fall_back_to_defaults() -> void:
	var turn: ConversationTurn = ConversationTurn.from_dictionary({"speaker": "smith"})
	assert_eq(turn.emotion, &"neutral")
	assert_eq(turn.gesture, &"none")
	assert_eq(turn.line, "")


func test_turn_without_a_line_is_not_valid() -> void:
	# A speaker with nothing to say would otherwise stall a beat waiting on a clip that
	# is never requested, so the group has to be able to reject it.
	assert_false(ConversationTurn.from_dictionary({"speaker": "smith"}).is_valid())


func test_turn_without_a_speaker_is_not_valid() -> void:
	assert_false(ConversationTurn.from_dictionary({"line": "Who said that?"}).is_valid())


func test_estimated_duration_grows_with_the_line() -> void:
	var short_turn: ConversationTurn = ConversationTurn.new(&"smith", "Don't.")
	var long_turn: ConversationTurn = ConversationTurn.new(
		&"baker",
		"And you'll have it, every coin, as soon as I learn what the miller's "
		+ "daughter was doing at your forge past dark.",
	)
	assert_lt(short_turn.estimated_duration(), long_turn.estimated_duration())


func test_estimated_duration_is_bounded() -> void:
	# The estimate only paces a line when there is no clip to wait on, so it must never
	# return zero (turns would race past) or something absurd (the beat would hang).
	var empty: ConversationTurn = ConversationTurn.new(&"smith", "")
	assert_between(empty.estimated_duration(), 1.2, 12.0)

	var rambling: String = ""
	for i: int in 400:
		rambling += "word "
	assert_between(ConversationTurn.new(&"smith", rambling).estimated_duration(), 1.2, 12.0)
