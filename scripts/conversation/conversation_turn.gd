class_name ConversationTurn
extends RefCounted
## One villager saying one thing.
##
## Produced by [ConversationDirector] from the model's structured output, consumed by
## [ConversationGroup] when the beat is performed. The `emotion` and `gesture` fields
## come back constrained to the schema's enums, so an [NPC] can map them straight onto
## an animation or a voice setting without validating them again.

## The `id` of the persona speaking.
var speaker: StringName = &""

## What they say aloud.
var line: String = ""

## One of the emotions in `ConversationDirector.TURN_SCHEMA`.
var emotion: StringName = &"neutral"

## One of the gestures in `ConversationDirector.TURN_SCHEMA`.
var gesture: StringName = &"none"


func _init(
	p_speaker: StringName = &"",
	p_line: String = "",
	p_emotion: StringName = &"neutral",
	p_gesture: StringName = &"none",
) -> void:
	speaker = p_speaker
	line = p_line
	emotion = p_emotion
	gesture = p_gesture


## Builds a turn from one entry of the model's `turns` array.
static func from_dictionary(data: Dictionary) -> ConversationTurn:
	return ConversationTurn.new(
		StringName(str(data.get("speaker", ""))),
		str(data.get("line", "")).strip_edges(),
		StringName(str(data.get("emotion", "neutral"))),
		StringName(str(data.get("gesture", "none"))),
	)


## Whether this turn is worth performing. The schema guarantees the fields exist, not
## that the model filled them with anything.
func is_valid() -> bool:
	return not speaker.is_empty() and not line.is_empty()


## Roughly how long the line takes to say, used to pace a beat when the voice service
## is unavailable and there is no clip length to wait on.
func estimated_duration() -> float:
	var words: int = line.split(" ", false).size()
	return clampf(float(words) / 2.6, 1.2, 12.0)


func _to_string() -> String:
	return "%s: %s" % [speaker, line]
