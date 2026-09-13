extends GutTest
## [ConversationDirector] request shape and response parsing, entirely offline.
##
## Nothing here calls the Claude API. The request body is inspected as a dictionary
## before it would ever be sent, and the response side is driven from
## `tests/fixtures/beat_response.json`, which is a real recorded reply kept verbatim.
##
## The request assertions are not incidental. Prompt caching only pays when the cached
## prefix is byte identical between calls, `low` effort is what keeps a beat inside the
## few seconds a player will tolerate, and the strict schema is the only reason the
## game can parse a reply without defending against prose. A change to any of those is
## a change in cost or in feel, and should have to be made deliberately.

const FIXTURE: String = "res://tests/fixtures/beat_response.json"

var _smith: NPCPersona
var _baker: NPCPersona


func before_each() -> void:
	_smith = NPCPersona.new()
	_smith.id = &"smith"
	_smith.display_name = "Aldric"
	_smith.occupation = "blacksmith"
	_smith.biography = "Keeps the forge."
	_smith.traits = PackedStringArray(["gruff"])
	_smith.knowledge = PackedStringArray(["Maud owes him for the irons."])

	_baker = NPCPersona.new()
	_baker.id = &"baker"
	_baker.display_name = "Maud"
	_baker.occupation = "baker"
	_baker.biography = "Runs the bakery."
	_baker.traits = PackedStringArray(["nosy"])


func _personas() -> Array[NPCPersona]:
	var list: Array[NPCPersona] = []
	list.append(_smith)
	list.append(_baker)
	return list


func _situation() -> Dictionary:
	return {
		"location": "the market fountain",
		"time_of_day": "mid-morning",
		"player_present": false,
		"topic": "the missing girl",
	}


func _body() -> Dictionary:
	var history: Array[ConversationTurn] = []
	return ConversationDirector._build_body(_personas(), _situation(), history)


# --- the request -----------------------------------------------------------------

func test_the_director_stays_offline_during_tests() -> void:
	# The backstop that makes this whole suite free to run.
	assert_true(RuntimeMode.is_offline(), "a GUT run must be offline")
	assert_false(ConversationDirector.is_available(), "the director must not be armed")


func test_request_names_the_expected_model_and_effort() -> void:
	var body: Dictionary = _body()
	assert_eq(body["model"], "claude-opus-5")
	assert_eq(body["output_config"]["effort"], "low")
	assert_true(body["max_tokens"] > 0)


func test_request_asks_for_the_strict_turn_schema() -> void:
	var format: Dictionary = _body()["output_config"]["format"]
	assert_eq(format["type"], "json_schema")
	var schema: Dictionary = format["schema"]
	assert_false(schema["additionalProperties"], "the schema must be closed")
	var item: Dictionary = schema["properties"]["turns"]["items"]
	assert_eq(item["required"], ["speaker", "line", "emotion", "gesture"])
	assert_false(item["additionalProperties"], "each turn must be closed")


func test_cache_breakpoint_sits_on_the_last_stable_system_block() -> void:
	# Everything above the breakpoint is re-read from cache instead of re-billed, so
	# the breakpoint belongs on the final block that never varies between requests.
	var system: Array = _body()["system"]
	assert_eq(system.size(), 2, "lore and direction should be separate blocks")
	assert_false(system[0].has("cache_control"), "the first block is not the breakpoint")
	assert_eq(system[1]["cache_control"], {"type": "ephemeral"})


func test_the_cached_prefix_does_not_change_with_the_situation() -> void:
	# If the varying part of the prompt leaked above the breakpoint, every request
	# would miss the cache and be billed in full.
	var first: Array = _body()["system"]
	var evening: Dictionary = _situation()
	evening["time_of_day"] = "after dark"
	evening["player_present"] = true
	var history: Array[ConversationTurn] = []
	var second: Array = ConversationDirector._build_body(_personas(), evening, history)["system"]
	assert_eq(first[0]["text"], second[0]["text"])
	assert_eq(first[1]["text"], second[1]["text"])


func test_the_situation_reaches_the_user_message() -> void:
	var content: String = str(_body()["messages"][-1]["content"])
	assert_string_contains(content, "the market fountain")
	assert_string_contains(content, "mid-morning")
	assert_string_contains(content, "the missing girl")
	assert_string_contains(content, "not within earshot")


func test_the_player_being_present_changes_the_user_message() -> void:
	var watched: Dictionary = _situation()
	watched["player_present"] = true
	var history: Array[ConversationTurn] = []
	var content: String = str(
		ConversationDirector._build_body(_personas(), watched, history)["messages"][-1]["content"]
	)
	assert_string_contains(content, "close enough to hear")


func test_every_persona_appears_in_the_prompt() -> void:
	var system: String = str(_body()["system"][1]["text"])
	assert_string_contains(system, "smith")
	assert_string_contains(system, "baker")
	assert_string_contains(system, "Maud owes him for the irons.")


func test_history_is_replayed_and_capped() -> void:
	var history: Array[ConversationTurn] = []
	for i: int in ConversationDirector.HISTORY_LIMIT + 8:
		history.append(ConversationTurn.new(&"smith", "line %d" % i))
	var messages: Array = ConversationDirector._build_body(
		_personas(), _situation(), history
	)["messages"]
	var transcript: String = str(messages[0]["content"])
	assert_string_contains(transcript, "line %d" % (history.size() - 1))
	assert_false(
		transcript.contains("line 0\n"),
		"the oldest turns should fall outside the history limit",
	)


func test_server_side_fallback_is_requested() -> void:
	assert_eq(_body()["fallbacks"], "default")


# --- the response ----------------------------------------------------------------

func _fixture() -> Dictionary:
	var file: FileAccess = FileAccess.open(FIXTURE, FileAccess.READ)
	assert_not_null(file, "the recorded beat fixture should exist")
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	assert_eq(typeof(parsed), TYPE_DICTIONARY, "the fixture should be a JSON object")
	return parsed


func test_the_recorded_reply_parses_into_turns() -> void:
	var turns: Array[ConversationTurn] = ConversationDirector._parse_turns(_fixture())
	assert_gt(turns.size(), 0, "the recorded beat should yield turns")
	for turn: ConversationTurn in turns:
		assert_true(turn.is_valid(), "every recorded turn should be valid")
		assert_true(
			turn.speaker in [&"smith", &"baker"],
			"the model should only name villagers that were offered to it",
		)


func test_parsed_turns_stay_inside_the_schema_enums() -> void:
	var item: Dictionary = ConversationDirector.TURN_SCHEMA["properties"]["turns"]["items"]
	var emotions: Array = item["properties"]["emotion"]["enum"]
	var gestures: Array = item["properties"]["gesture"]["enum"]
	for turn: ConversationTurn in ConversationDirector._parse_turns(_fixture()):
		assert_true(String(turn.emotion) in emotions, "unexpected emotion %s" % turn.emotion)
		assert_true(String(turn.gesture) in gestures, "unexpected gesture %s" % turn.gesture)


func test_a_reply_with_no_content_yields_no_turns() -> void:
	assert_eq(ConversationDirector._parse_turns({"content": []}).size(), 0)


func test_a_reply_whose_text_is_not_json_yields_no_turns() -> void:
	var malformed: Dictionary = {
		"content": [{"type": "text", "text": "I'm afraid I can't do that."}],
	}
	assert_eq(ConversationDirector._parse_turns(malformed).size(), 0)
