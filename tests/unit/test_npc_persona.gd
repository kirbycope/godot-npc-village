extends GutTest
## [NPCPersona] prompt rendering.
##
## The rendered persona sits above the prompt cache breakpoint, so it has to be
## byte identical between requests. Anything that iterates a Dictionary without sorting
## it would render in whatever order the engine happened to hash the keys, the cached
## prefix would differ, and every request would be billed as a cache miss for a reason
## that is invisible in the response.


func _persona() -> NPCPersona:
	var persona: NPCPersona = NPCPersona.new()
	persona.id = &"smith"
	persona.display_name = "Aldric"
	persona.occupation = "blacksmith"
	persona.biography = "Keeps the forge and is tired."
	persona.traits = PackedStringArray(["gruff", "literal"])
	persona.knowledge = PackedStringArray(["Maud owes him six silver."])
	persona.relationships = {
		&"innkeeper": "Finds him heavy going.",
		&"baker": "Owes him money.",
		&"guard": "A friend.",
	}
	return persona


func test_the_rendering_contains_the_identifying_fields() -> void:
	var text: String = _persona().to_prompt_section()
	assert_string_contains(text, "Aldric")
	assert_string_contains(text, "smith")
	assert_string_contains(text, "blacksmith")
	assert_string_contains(text, "gruff, literal")
	assert_string_contains(text, "Maud owes him six silver.")


func test_the_rendering_is_stable_across_calls() -> void:
	var persona: NPCPersona = _persona()
	assert_eq(persona.to_prompt_section(), persona.to_prompt_section())


func test_relationships_render_in_a_fixed_order() -> void:
	var text: String = _persona().to_prompt_section()
	var baker: int = text.find("baker:")
	var guard: int = text.find("guard:")
	var innkeeper: int = text.find("innkeeper:")
	assert_gt(baker, -1)
	assert_lt(baker, guard, "relationships should be sorted by id")
	assert_lt(guard, innkeeper, "relationships should be sorted by id")


func test_an_empty_persona_renders_without_stray_headings() -> void:
	var bare: NPCPersona = NPCPersona.new()
	bare.id = &"nobody"
	var text: String = bare.to_prompt_section()
	assert_false(text.contains("Knows:"), "no knowledge means no heading")
	assert_false(text.contains("Traits:"), "no traits means no heading")
	assert_false(text.contains("Feelings about others:"), "no relationships means no heading")


func test_every_shipped_persona_uses_a_free_tier_voice() -> void:
	# The account's "professional" voices return HTTP 402 on a free plan, so a cast
	# member assigned one would be silent for anyone without a subscription.
	var blocked: PackedStringArray = PackedStringArray([
		"wyWA56cQNU2KqUW4eCsI",  # Clyde
		"NNl6r8mD7vthiJatiJt1",  # Bradford
		"iBeucLPI8hr8MOJjjYTL",  # David
		"09AoN6tYyW3VSTQqCo7C",  # Jessi, casual
		"wfJ7pHCS3lXZdaz77rIG",  # Jessi
		"yj4ZLC16WtrBEwPzIXzI",  # Jessi, young
	])
	var directory: DirAccess = DirAccess.open("res://resources/personas")
	assert_not_null(directory, "the personas directory should exist")
	var checked: int = 0
	for file_name: String in directory.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var persona: NPCPersona = load("res://resources/personas/%s" % file_name)
		assert_not_null(persona, "%s should load as a persona" % file_name)
		assert_false(persona.voice_id.is_empty(), "%s has no voice" % file_name)
		assert_false(
			blocked.has(persona.voice_id),
			"%s uses a professional voice a free account cannot reach" % file_name,
		)
		checked += 1
	assert_gt(checked, 0, "there should be personas to check")
