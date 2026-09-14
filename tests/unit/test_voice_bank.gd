extends GutTest
## The committed voice bank: `assets/voice/` and its manifest.
##
## The bank is what lets a build with no API key, no network, and no writable cache still
## have a voice for every authored line, and what a web build pulls from
## raw.githubusercontent.com instead of carrying the audio in its export. It is only
## worth anything if the manifest and the files on disk agree, so that is what is checked
## here. Nothing in this file makes a request.

const BANK_DIR: String = "res://assets/voice"
const MANIFEST: String = "res://assets/voice/manifest.json"


func _manifest() -> Dictionary:
	var file: FileAccess = FileAccess.open(MANIFEST, FileAccess.READ)
	assert_not_null(file, "the voice bank manifest should exist")
	if file == null:
		return {}
	var reader: JSON = JSON.new()
	var text: String = file.get_as_text()
	file.close()
	assert_eq(reader.parse(text), OK, "the manifest should be valid JSON")
	return reader.data if typeof(reader.data) == TYPE_DICTIONARY else {}


func test_the_manifest_records_the_model_it_was_baked_with() -> void:
	# A clip synthesized with one model does not answer a lookup made with another,
	# because the model is part of the cache key.
	var document: Dictionary = _manifest()
	assert_eq(document.get("model_id", ""), VoiceService.MODEL_ID)
	assert_eq(document.get("output_format", ""), VoiceService.OUTPUT_FORMAT)


func test_every_manifest_entry_has_a_file() -> void:
	var clips: Dictionary = _manifest().get("clips", {})
	assert_gt(clips.size(), 0, "the bank should hold clips")
	for key: String in clips:
		assert_true(
			FileAccess.file_exists("%s/%s.mp3" % [BANK_DIR, key]),
			"the manifest lists %s but there is no such clip" % key,
		)


func test_every_clip_is_in_the_manifest() -> void:
	# An unlisted clip is an unidentifiable blob: nothing on disk says what it says.
	var clips: Dictionary = _manifest().get("clips", {})
	var directory: DirAccess = DirAccess.open(BANK_DIR)
	assert_not_null(directory)
	for file_name: String in directory.get_files():
		if not file_name.ends_with(".mp3"):
			continue
		assert_true(
			clips.has(file_name.get_basename()),
			"%s is in the bank but not in the manifest" % file_name,
		)


func test_every_entry_describes_itself() -> void:
	var clips: Dictionary = _manifest().get("clips", {})
	for key: String in clips:
		var entry: Dictionary = clips[key]
		assert_false(str(entry.get("text", "")).is_empty(), "%s has no text" % key)
		assert_false(str(entry.get("speaker", "")).is_empty(), "%s has no speaker" % key)
		assert_false(str(entry.get("voice_id", "")).is_empty(), "%s has no voice" % key)
		assert_gt(float(entry.get("seconds", 0.0)), 0.0, "%s has no duration" % key)


func test_the_hash_matches_what_the_service_would_look_up() -> void:
	# The whole bank rests on this: a clip is found by hashing the line, the voice and the
	# settings, so a manifest key that does not match that hash is a clip nobody can find.
	var personas: Dictionary = {}
	var directory: DirAccess = DirAccess.open("res://resources/personas")
	for file_name: String in directory.get_files():
		if file_name.ends_with(".tres"):
			var persona: NPCPersona = load("res://resources/personas/%s" % file_name)
			personas[String(persona.id)] = persona

	var clips: Dictionary = _manifest().get("clips", {})
	var checked: int = 0
	for key: String in clips:
		var entry: Dictionary = clips[key]
		var persona: NPCPersona = personas.get(str(entry.get("persona", "")))
		if persona == null:
			continue
		assert_eq(
			VoiceService._cache_key(str(entry["text"]), persona), key,
			"the key for '%s' does not match what the service would compute" % entry["text"],
		)
		checked += 1
	assert_gt(checked, 0, "there should be clips whose persona still exists")


func test_a_banked_line_plays_with_no_key_and_no_network() -> void:
	var clips: Dictionary = _manifest().get("clips", {})
	var personas: Dictionary = {}
	var directory: DirAccess = DirAccess.open("res://resources/personas")
	for file_name: String in directory.get_files():
		if file_name.ends_with(".tres"):
			var persona: NPCPersona = load("res://resources/personas/%s" % file_name)
			personas[String(persona.id)] = persona

	var spoken: String = ""
	var speaker: NPCPersona = null
	for key: String in clips:
		var entry: Dictionary = clips[key]
		if personas.has(str(entry.get("persona", ""))):
			spoken = str(entry["text"])
			speaker = personas[str(entry["persona"])]
			break
	assert_not_null(speaker, "a banked line with a live persona is needed for this test")
	if speaker == null:
		return

	watch_signals(VoiceService)
	var handle: int = VoiceService.speak(spoken, speaker)
	assert_gt(handle, 0, "a banked line should be answered")
	await wait_frames(2)
	assert_signal_emitted(VoiceService, "clip_ready")
	var parameters: Array = get_signal_parameters(VoiceService, "clip_ready")
	assert_not_null(parameters[1], "a stream should come back")
	assert_true(parameters[2], "it should be reported as coming from storage, not the API")
