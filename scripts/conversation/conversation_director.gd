extends Node
## Writes the villagers' conversations with the Claude API.
##
## Autoloaded as `ConversationDirector`. A [ConversationGroup] asks for a "beat", a
## short run of turns between the villagers standing in it, and the director returns
## the whole beat in one API call. Generating several turns at once rather than one
## per request is what makes the conversations feel live: a single round trip costs
## seconds, and paying that once per beat instead of once per line keeps the pauses
## between villagers down to the time the voice service needs.
##
## A beat can be cut short at any time. When the player walks up, or the hour turns,
## the group abandons what is left and asks for a new beat with the changed situation
## in the context, so the villagers react instead of finishing a stale script.
##
## The director never blocks. When there is no API key, or the request fails, it emits
## [signal beat_failed] and the group falls back to its authored idle lines.

## A finished beat is ready to perform. `turns` is an array of [ConversationTurn].
signal beat_ready(group_id: StringName, turns: Array[ConversationTurn])

## No beat could be produced. `reason` is safe to show in a debug overlay.
signal beat_failed(group_id: StringName, reason: String)

## Emitted after every completed request with the tokens it cost.
signal usage_reported(input_tokens: int, output_tokens: int, cached_tokens: int)

const ENDPOINT: String = "https://api.anthropic.com/v1/messages"
const API_VERSION: String = "2023-06-01"

## Opus 5 is the default. Dialogue is short, so the cost per beat is dominated by the
## cached system prompt rather than the output.
const MODEL: String = "claude-opus-5"

## Server-side fallback keeps a beat from simply stopping if a safety classifier
## declines it. The scalar `"default"` form routes by category, so there is no model
## list to maintain. Its beta header and the array form's header are not
## interchangeable; pairing one with the other is a 400.
const FALLBACK_BETA: String = "server-side-fallback-2026-07-01"

## `low` effort is the point of this whole design: village small talk does not need
## deep reasoning, and the latency saved is latency the player would otherwise spend
## watching two villagers stand in silence.
const EFFORT: String = "low"

const MAX_TOKENS: int = 2000

## Wall-clock seconds before a request is abandoned.
const TIMEOUT_SECONDS: float = 30.0

## Beats requested per group before the director insists on a cooldown, so a bug in a
## group cannot spend the account's tokens in a loop.
const MAX_BEATS_PER_MINUTE: int = 20

## How many previously spoken turns are replayed to the model as conversation history.
const HISTORY_LIMIT: int = 12

## The village bible. Stable across every request so it caches; anything that varies
## belongs in the user message instead.
const VILLAGE_LORE: String = """You write dialogue for villagers in Ashmoor, a small medieval village \
built where the mill road crosses the river. It has a market square with a fountain, a smithy, a \
bakery, a tavern called the Crooked Hart, a watermill, and a chapel with a graveyard behind it. The \
lord's tax collector is expected before the harvest. The miller's youngest daughter has not been \
seen for six days.

You are writing overheard conversation, not quest dialogue. The villagers are talking to each other \
because they have things to say to each other, and the player may or may not be listening."""

## The rules that shape every beat. Also stable, also cached.
const DIRECTION: String = """Write the next beat of conversation between the villagers listed below.

Rules:
- Every turn is one villager speaking, in character, in their own voice.
- Keep each line short. One or two sentences. These are spoken aloud, not read.
- No stage directions, no narration, no asterisks, no quotation marks around the line.
- Villagers do not explain things they both already know just to inform the player.
- They interrupt, disagree, change the subject, and leave things unsaid.
- Never invent a villager who is not listed. Use the exact `id` values given.
- Avoid modern idiom, but do not write in mock-archaic English either.
- If the player is standing with them, they may acknowledge the player or pointedly \
not acknowledge them, as their character would.
- A beat is 3 to 6 turns. End it somewhere that could be picked up again."""

## The shape every beat must come back in. `strict` schema, so the response is
## guaranteed to parse and the game never has to defend against prose.
const TURN_SCHEMA: Dictionary = {
	"type": "object",
	"properties": {
		"turns": {
			"type": "array",
			"items": {
				"type": "object",
				"properties": {
					"speaker": {
						"type": "string",
						"description": "The exact id of the villager speaking.",
					},
					"line": {
						"type": "string",
						"description": "What they say aloud. One or two sentences.",
					},
					"emotion": {
						"type": "string",
						"enum": [
							"neutral", "warm", "amused", "angry", "afraid",
							"sad", "conspiratorial", "weary", "surprised",
						],
					},
					"gesture": {
						"type": "string",
						"enum": [
							"none", "nod", "shake_head", "point",
							"shrug", "laugh", "lean_in", "turn_away",
						],
					},
				},
				"required": ["speaker", "line", "emotion", "gesture"],
				"additionalProperties": false,
			},
		},
	},
	"required": ["turns"],
	"additionalProperties": false,
}

## Requests in flight, keyed by the HTTPRequest node driving each one.
var _pending: Dictionary[HTTPRequest, StringName] = {}

## Unix timestamps of recent requests per group, for the rate guard.
var _recent: Dictionary[StringName, Array] = {}

var _enabled: bool = false


func _ready() -> void:
	if RuntimeMode.is_offline():
		# Beats come from recorded fixtures during a test run; nothing is requested.
		_enabled = false
		return
	_enabled = Secrets.has_key("anthropic")
	if not _enabled:
		push_warning(
			"[ConversationDirector] No Anthropic key. "
			+ "Villagers will fall back to their authored idle lines."
		)


## Whether the director can actually reach the API.
func is_available() -> bool:
	return _enabled


## Ask for the next beat for `group_id`.
##
## `personas` are the villagers present, `situation` describes where and when this is
## happening, and `history` is what has already been said in this group.
func request_beat(
	group_id: StringName,
	personas: Array[NPCPersona],
	situation: Dictionary,
	history: Array[ConversationTurn],
) -> void:
	if not _enabled:
		beat_failed.emit(group_id, "no API key")
		return
	if personas.size() < 2:
		beat_failed.emit(group_id, "a beat needs at least two villagers")
		return
	if not _allow_request(group_id):
		beat_failed.emit(group_id, "rate limited")
		return

	var request: HTTPRequest = HTTPRequest.new()
	request.timeout = TIMEOUT_SECONDS
	request.accept_gzip = true
	add_child(request)
	_pending[request] = group_id
	request.request_completed.connect(_on_request_completed.bind(request, group_id))

	var headers: PackedStringArray = PackedStringArray([
		"Content-Type: application/json",
		"x-api-key: %s" % Secrets.get_key("anthropic"),
		"anthropic-version: %s" % API_VERSION,
		"anthropic-beta: %s" % FALLBACK_BETA,
	])
	var body: String = JSON.stringify(_build_body(personas, situation, history))
	var error: Error = request.request(ENDPOINT, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		_finish(request, group_id)
		beat_failed.emit(group_id, "could not start request: %s" % error_string(error))


## The request body. The system prompt is two blocks so the cache breakpoint sits on
## the last stable one: lore, direction and personas never vary within a session, and
## everything that does vary is in the user message below the breakpoint.
func _build_body(
	personas: Array[NPCPersona],
	situation: Dictionary,
	history: Array[ConversationTurn],
) -> Dictionary:
	var cast: PackedStringArray = PackedStringArray()
	for persona: NPCPersona in personas:
		cast.append(persona.to_prompt_section())

	var system: Array = [
		{
			"type": "text",
			"text": VILLAGE_LORE,
		},
		{
			"type": "text",
			"text": "%s\n\n## The villagers in this conversation\n\n%s" % [
				DIRECTION, "\n\n".join(cast),
			],
			# Everything above this point is byte-identical on every request for this
			# group, so it is read from cache rather than re-billed as input.
			"cache_control": {"type": "ephemeral"},
		},
	]

	var messages: Array = []
	if not history.is_empty():
		var transcript: PackedStringArray = PackedStringArray()
		var start: int = maxi(0, history.size() - HISTORY_LIMIT)
		for i: int in range(start, history.size()):
			var turn: ConversationTurn = history[i]
			transcript.append("%s: %s" % [turn.speaker, turn.line])
		messages.append({
			"role": "user",
			"content": "Earlier in this conversation:\n%s" % "\n".join(transcript),
		})
		messages.append({
			"role": "assistant",
			"content": "Understood. I will continue from there.",
		})
	messages.append({
		"role": "user",
		"content": _describe_situation(situation),
	})

	return {
		"model": MODEL,
		"max_tokens": MAX_TOKENS,
		"system": system,
		"messages": messages,
		"output_config": {
			"effort": EFFORT,
			"format": {"type": "json_schema", "schema": TURN_SCHEMA},
		},
		"fallbacks": "default",
	}


## The only part of the prompt that changes between requests.
func _describe_situation(situation: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("Write the next beat.")
	lines.append("")
	if situation.has("location"):
		lines.append("Where: %s" % situation["location"])
	if situation.has("time_of_day"):
		lines.append("When: %s" % situation["time_of_day"])
	if situation.has("weather"):
		lines.append("Weather: %s" % situation["weather"])
	if situation.get("player_present", false):
		lines.append("The player is standing close enough to hear every word.")
	else:
		lines.append("The player is not within earshot.")
	if situation.has("topic") and not str(situation["topic"]).is_empty():
		lines.append("Something on their minds: %s" % situation["topic"])
	return "\n".join(lines)


func _on_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	request: HTTPRequest,
	group_id: StringName,
) -> void:
	_finish(request, group_id)

	if result != HTTPRequest.RESULT_SUCCESS:
		beat_failed.emit(group_id, "transport error %d" % result)
		return

	var text: String = body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		beat_failed.emit(group_id, "response was not JSON")
		return
	var response: Dictionary = parsed

	if response_code != 200:
		var detail: String = "HTTP %d" % response_code
		if response.has("error") and typeof(response["error"]) == TYPE_DICTIONARY:
			detail += ": %s" % response["error"].get("message", "")
		beat_failed.emit(group_id, detail)
		return

	# A refusal arrives as a 200 with no usable content, so it has to be checked
	# before the content blocks are read.
	if response.get("stop_reason", "") == "refusal":
		var category: String = ""
		if typeof(response.get("stop_details")) == TYPE_DICTIONARY:
			category = str(response["stop_details"].get("category", ""))
		beat_failed.emit(group_id, "declined by the model (%s)" % category)
		return

	_report_usage(response)

	var turns: Array[ConversationTurn] = _parse_turns(response)
	if turns.is_empty():
		beat_failed.emit(group_id, "no turns in the response")
		return
	beat_ready.emit(group_id, turns)


## `output_config.format` guarantees the first text block is schema-valid JSON.
func _parse_turns(response: Dictionary) -> Array[ConversationTurn]:
	var turns: Array[ConversationTurn] = []
	var content: Array = response.get("content", [])
	for block: Variant in content:
		if typeof(block) != TYPE_DICTIONARY or block.get("type", "") != "text":
			continue
		# Parsed through a JSON instance rather than `JSON.parse_string`, which pushes an
		# engine error when the text is not JSON. A reply that is prose instead of a
		# beat is an expected outcome to handle, not an engine fault to report.
		var reader: JSON = JSON.new()
		if reader.parse(str(block.get("text", ""))) != OK:
			continue
		var payload: Variant = reader.data
		if typeof(payload) != TYPE_DICTIONARY:
			continue
		var raw_turns: Variant = payload.get("turns", [])
		if typeof(raw_turns) != TYPE_ARRAY:
			continue
		for entry: Variant in raw_turns:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			turns.append(ConversationTurn.from_dictionary(entry))
		break
	return turns


func _report_usage(response: Dictionary) -> void:
	if typeof(response.get("usage")) != TYPE_DICTIONARY:
		return
	var usage: Dictionary = response["usage"]
	usage_reported.emit(
		int(usage.get("input_tokens", 0)),
		int(usage.get("output_tokens", 0)),
		int(usage.get("cache_read_input_tokens", 0)),
	)


## A cheap guard against a group looping on requests. Not a billing control; it only
## stops a runaway scene from spending tokens unattended.
func _allow_request(group_id: StringName) -> bool:
	var now: float = Time.get_unix_time_from_system()
	var stamps: Array = _recent.get(group_id, [])
	var kept: Array = []
	for stamp: float in stamps:
		if now - stamp < 60.0:
			kept.append(stamp)
	if kept.size() >= MAX_BEATS_PER_MINUTE:
		_recent[group_id] = kept
		return false
	kept.append(now)
	_recent[group_id] = kept
	return true


func _finish(request: HTTPRequest, _group_id: StringName) -> void:
	_pending.erase(request)
	if is_instance_valid(request):
		request.queue_free()
