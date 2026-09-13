class_name NPCPersona
extends Resource
## Everything the dialogue model and the voice service need to know about one villager.
##
## A persona is authored as a `.tres` under `resources/personas/` and assigned to an
## `NPC` node in the inspector, so adding a villager never means touching code.

## Stable identifier the dialogue model uses to attribute a line. Lowercase, no spaces.
@export var id: StringName = &""

## The name shown in subtitles.
@export var display_name: String = "Villager"

## Trade or role, used in the prompt and in the world-space label.
@export var occupation: String = ""

@export_group("Character")

## Two or three sentences in the third person. Who they are, how they speak, what
## they want. This is the bulk of what shapes their dialogue.
@export_multiline var biography: String = ""

## Short traits such as "gruff", "superstitious", "over-familiar". The model is told
## to keep the voice consistent with these.
@export var traits: PackedStringArray = PackedStringArray()

## Things this villager believes, gossips about, or is hiding. Written as plain
## statements; the model decides when one surfaces.
@export_multiline var knowledge: PackedStringArray = PackedStringArray()

@export_group("Relationships")

## Maps another persona's `id` to how this one regards them, for example
## `&"baker": "Owes him money and resents being reminded."`
@export var relationships: Dictionary[StringName, String] = {}

@export_group("Appearance")

## Colour of the villager's clothing, applied over the model's main material. The
## Quaternius mannequin ships a single gold body and a purple joint material, which
## reads as a shop dummy; recolouring the two per persona is what turns six identical
## mannequins into six people who can be told apart across a square.
@export var tunic_color: Color = Color(0.62, 0.56, 0.45)

## Colour of the hands, face and boots, applied over the model's joint material.
@export var trim_color: Color = Color(0.74, 0.58, 0.44)


@export_group("Voice")

## ElevenLabs voice id. Free-tier accounts can only use voices in the "premade"
## category; a "professional" voice returns HTTP 402.
@export var voice_id: String = ""

## Lower is more consistent, higher is more expressive.
@export_range(0.0, 1.0, 0.05) var voice_stability: float = 0.45

## How closely the delivery tracks the original voice sample.
@export_range(0.0, 1.0, 0.05) var voice_similarity: float = 0.8

## Exaggeration of the speaker's style. Costs latency above 0.
@export_range(0.0, 1.0, 0.05) var voice_style: float = 0.3

## Pitch shift applied to the played back clip, so two villagers can share one
## ElevenLabs voice without sounding identical. 1.0 leaves the clip untouched.
@export_range(0.7, 1.4, 0.01) var voice_pitch: float = 1.0


## The persona rendered for the dialogue model's system prompt. Kept deterministic:
## the system prompt is cached upstream and any instability would cost the cache hit.
func to_prompt_section() -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("### %s (id: %s)" % [display_name, id])
	if not occupation.is_empty():
		lines.append("Occupation: %s" % occupation)
	if not traits.is_empty():
		lines.append("Traits: %s" % ", ".join(traits))
	if not biography.is_empty():
		lines.append(biography)
	if not knowledge.is_empty():
		lines.append("Knows:")
		for item: String in knowledge:
			lines.append("- %s" % item)
	if not relationships.is_empty():
		lines.append("Feelings about others:")
		# Sorted as Strings, not as StringNames. Comparing StringNames sorts them by
		# their internal pointer rather than alphabetically, so the block would render
		# in a different order from run to run. That order sits above the prompt cache
		# breakpoint, and an unstable prefix means every request misses the cache and is
		# billed in full, with nothing in the response to say why.
		var keys: Array[String] = []
		for other: StringName in relationships:
			keys.append(String(other))
		keys.sort()
		for other: String in keys:
			lines.append("- %s: %s" % [other, relationships[StringName(other)]])
	return "\n".join(lines)
