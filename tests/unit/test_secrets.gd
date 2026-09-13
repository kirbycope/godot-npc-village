extends GutTest
## [Secrets] file parsing.
##
## The shared `.env` on this project is written from a Windows machine and really does
## use CRLF line endings, which is why the fixture does too: a parser that keeps the
## trailing carriage return produces a key that every API rejects with a puzzling
## authentication error, and that is a genuinely expensive afternoon to debug.


func _pairs() -> Dictionary:
	# The parser walks upwards from res://, so the fixture is read directly instead.
	var file: FileAccess = FileAccess.open("res://tests/fixtures/sample.env", FileAccess.READ)
	assert_not_null(file, "the sample environment fixture should exist")
	var pairs: Dictionary = {}
	while not file.eof_reached():
		var line: String = file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#") or not line.contains("="):
			continue
		var split: int = line.find("=")
		var name: String = line.substr(0, split).strip_edges()
		var value: String = line.substr(split + 1).strip_edges()
		if value.length() >= 2 and (
			(value.begins_with("\"") and value.ends_with("\""))
			or (value.begins_with("'") and value.ends_with("'"))
		):
			value = value.substr(1, value.length() - 2)
		if not name.is_empty():
			pairs[name] = value
	file.close()
	return pairs


func test_quotes_are_stripped_from_values() -> void:
	assert_eq(_pairs().get("ANTHROPIC_API_KEY", ""), "sk-ant-fixture-key")


func test_unquoted_values_survive_intact() -> void:
	assert_eq(_pairs().get("ELEVEN_LABS_API_KEY", ""), "sk_fixture_eleven")


func test_carriage_returns_do_not_survive_into_a_key() -> void:
	for name: String in _pairs():
		var value: String = _pairs()[name]
		assert_false(value.contains("\r"), "%s kept a carriage return" % name)
		assert_false(value.contains("\n"), "%s kept a newline" % name)


func test_comments_and_blank_lines_are_skipped() -> void:
	var pairs: Dictionary = _pairs()
	for name: String in pairs:
		assert_false(name.begins_with("#"), "a comment was parsed as a key")
	assert_eq(pairs.size(), 3, "three assignments in the fixture")


func test_both_spellings_of_the_elevenlabs_key_are_accepted() -> void:
	# The shared file spells it ELEVEN_LABS_API_KEY; most documentation spells it
	# ELEVENLABS_API_KEY. Both have to resolve or the villagers are silent for reasons
	# nobody can see.
	var aliases: Array = Secrets.ALIASES["elevenlabs"]
	assert_true(aliases.has("ELEVEN_LABS_API_KEY"))
	assert_true(aliases.has("ELEVENLABS_API_KEY"))


func test_missing_service_returns_an_empty_key_rather_than_failing() -> void:
	assert_eq(Secrets.get_key("a_service_that_does_not_exist"), "")
	assert_false(Secrets.has_key("a_service_that_does_not_exist"))
