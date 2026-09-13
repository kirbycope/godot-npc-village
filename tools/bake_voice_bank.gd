extends SceneTree
## Builds `assets/voice/`, the bank of spoken lines committed to the repository.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/bake_voice_bank.gd
##     ... -s tools/bake_voice_bank.gd -- --dry-run      report, synthesize nothing
##     ... -s tools/bake_voice_bank.gd -- --promote-only copy from the cache, never call out
##
## Two sources feed the bank. Every line already in the writable cache with an index
## entry is promoted as it stands, costing nothing. Every authored fallback line found on
## a `ConversationGroup` in the world scene is synthesized if it is not already there,
## because those are the lines a keyless build falls back to and the ones most worth
## having permanently.
##
## The point of committing the bank is that the clips become ordinary files in git. A web
## build can then pull them from raw.githubusercontent.com at run time instead of
## carrying them in the export, and a player with no ElevenLabs key still hears a village
## that talks. Nothing here ever needs to run again for those lines: a baked clip is
## free, forever.
##
## Every clip is named by the same hash the service looks up, so the bank is a drop-in
## for the cache. The manifest is what makes it legible, recording for each hash what is
## said, who says it, in which voice, and how long it runs.

const BANK_DIR: String = "res://assets/voice"
const MANIFEST: String = "res://assets/voice/manifest.json"
const CACHE_DIR: String = "user://voice_cache"
const CACHE_INDEX: String = "user://voice_cache/index.json"
const WORLD_SCENE: String = "res://scenes/world.tscn"

## Seconds to wait for one synthesis before giving up on it.
const REQUEST_TIMEOUT: float = 30.0

var _dry_run: bool = false
var _promote_only: bool = false
var _manifest: Dictionary = {}
var _baked: int = 0
var _promoted: int = 0
var _skipped: int = 0
var _failed: int = 0
var _characters: int = 0


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--dry-run":
			_dry_run = true
		elif argument == "--promote-only":
			_promote_only = true

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BANK_DIR))
	_load_manifest()

	_promote_cached_clips()
	await _bake_fallback_lines()

	_write_manifest()
	print("\n%d promoted, %d synthesized, %d already present, %d failed (%d characters)" % [
		_promoted, _baked, _skipped, _failed, _characters,
	])
	print("Bank now holds %d clips." % _manifest.size())
	quit(1 if _failed > 0 else 0)


func _load_manifest() -> void:
	if not FileAccess.file_exists(MANIFEST):
		return
	var file: FileAccess = FileAccess.open(MANIFEST, FileAccess.READ)
	if file == null:
		return
	var reader: JSON = JSON.new()
	var text: String = file.get_as_text()
	file.close()
	if reader.parse(text) == OK and typeof(reader.data) == TYPE_DICTIONARY:
		_manifest = reader.data.get("clips", {})


## Copies everything the writable cache knows the text of into the bank. Clips cached
## before the index existed are skipped rather than committed as anonymous hashes: a
## file nobody can identify is not worth carrying in a repository forever.
func _promote_cached_clips() -> void:
	if not FileAccess.file_exists(CACHE_INDEX):
		print("No cache index; nothing to promote.")
		return
	var file: FileAccess = FileAccess.open(CACHE_INDEX, FileAccess.READ)
	if file == null:
		return
	var reader: JSON = JSON.new()
	var text: String = file.get_as_text()
	file.close()
	if reader.parse(text) != OK or typeof(reader.data) != TYPE_DICTIONARY:
		return

	var index: Dictionary = reader.data
	for key: String in index:
		if _manifest.has(key):
			_skipped += 1
			continue
		var source: String = "%s/%s.mp3" % [CACHE_DIR, key]
		if not FileAccess.file_exists(source):
			continue
		var entry: Dictionary = index[key]
		print("  promote  %-9s %s" % [entry.get("speaker", "?"), _preview(entry.get("text", ""))])
		if _dry_run:
			_promoted += 1
			continue
		if _copy(source, "%s/%s.mp3" % [BANK_DIR, key]):
			_manifest[key] = entry
			_promoted += 1
		else:
			_failed += 1


## Synthesizes the authored fallback lines, which are the lines a build with no API key
## falls back to and therefore the ones that most need to exist without one.
func _bake_fallback_lines() -> void:
	var scene: PackedScene = load(WORLD_SCENE)
	if scene == null:
		printerr("Could not load %s" % WORLD_SCENE)
		return
	var world: Node = scene.instantiate()

	for group: Node in world.find_children("*", "Node3D", true, false):
		var lines: Variant = group.get("fallback_lines")
		if typeof(lines) != TYPE_PACKED_STRING_ARRAY:
			continue
		var villagers: Variant = group.get("npcs")
		if typeof(villagers) != TYPE_ARRAY:
			continue
		for line: String in lines:
			var split: int = line.find(":")
			if split <= 0:
				continue
			var persona_id: StringName = StringName(line.substr(0, split).strip_edges())
			var spoken: String = line.substr(split + 1).strip_edges()
			var persona: NPCPersona = _persona_for(villagers, persona_id)
			if persona == null:
				continue
			await _bake_one(persona, spoken)

	world.free()


func _persona_for(villagers: Array, persona_id: StringName) -> NPCPersona:
	for villager: Variant in villagers:
		if villager == null:
			continue
		var persona: Variant = villager.get("persona")
		if persona is NPCPersona and (persona as NPCPersona).id == persona_id:
			return persona
	return null


func _bake_one(persona: NPCPersona, text: String) -> void:
	var key: String = VoiceService._cache_key(text, persona)
	if _manifest.has(key):
		_skipped += 1
		return

	# It may already be in the writable cache even without an index entry.
	var cached: String = "%s/%s.mp3" % [CACHE_DIR, key]
	if FileAccess.file_exists(cached):
		print("  promote  %-9s %s" % [persona.display_name, _preview(text)])
		if not _dry_run and _copy(cached, "%s/%s.mp3" % [BANK_DIR, key]):
			_manifest[key] = _entry(persona, text, cached)
			_promoted += 1
		return

	if _promote_only:
		print("  missing  %-9s %s" % [persona.display_name, _preview(text)])
		_skipped += 1
		return

	print("  bake     %-9s %s" % [persona.display_name, _preview(text)])
	if _dry_run:
		_baked += 1
		_characters += text.length()
		return

	var bytes: PackedByteArray = await _synthesize(persona, text)
	if bytes.is_empty():
		_failed += 1
		return
	var target: String = "%s/%s.mp3" % [BANK_DIR, key]
	var file: FileAccess = FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		printerr("Could not write %s" % target)
		_failed += 1
		return
	file.store_buffer(bytes)
	file.close()
	_manifest[key] = _entry(persona, text, target)
	_baked += 1
	_characters += text.length()


## One synthesis, straight to the API. This deliberately does not go through
## `VoiceService`, which would refuse: the service is budgeted for a play session, while
## baking is a deliberate one-off that should not be silently capped.
func _synthesize(persona: NPCPersona, text: String) -> PackedByteArray:
	var key: String = Secrets.get_key("elevenlabs")
	if key.is_empty():
		printerr("No ElevenLabs key; cannot bake.")
		return PackedByteArray()

	var request: HTTPRequest = HTTPRequest.new()
	request.timeout = REQUEST_TIMEOUT
	root.add_child(request)

	var headers: PackedStringArray = PackedStringArray([
		"Content-Type: application/json",
		"xi-api-key: %s" % key,
		"Accept: audio/mpeg",
	])
	var body: String = JSON.stringify({
		"text": text,
		"model_id": VoiceService.MODEL_ID,
		"voice_settings": {
			"stability": persona.voice_stability,
			"similarity_boost": persona.voice_similarity,
			"style": persona.voice_style,
			"use_speaker_boost": true,
		},
	})
	var url: String = (
		(VoiceService.ENDPOINT % persona.voice_id)
		+ "?output_format=" + VoiceService.OUTPUT_FORMAT
	)
	if request.request(url, headers, HTTPClient.METHOD_POST, body) != OK:
		request.queue_free()
		return PackedByteArray()

	var result: Array = await request.request_completed
	request.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		printerr("    failed: HTTP %s" % result[1])
		return PackedByteArray()
	return result[3]


func _entry(persona: NPCPersona, text: String, path: String) -> Dictionary:
	var seconds: float = 0.0
	var stream: AudioStream = load(path) if path.begins_with("res://") else null
	if stream != null:
		seconds = stream.get_length()
	return {
		"text": text,
		"persona": String(persona.id),
		"speaker": persona.display_name,
		"voice_id": persona.voice_id,
		"model_id": VoiceService.MODEL_ID,
		"seconds": snappedf(seconds, 0.01),
	}


func _copy(source: String, target: String) -> bool:
	var input: FileAccess = FileAccess.open(source, FileAccess.READ)
	if input == null:
		return false
	var bytes: PackedByteArray = input.get_buffer(input.get_length())
	input.close()
	var output: FileAccess = FileAccess.open(target, FileAccess.WRITE)
	if output == null:
		return false
	output.store_buffer(bytes)
	output.close()
	return true


## The manifest is sorted and written with tabs so a change to it reads as a sensible
## diff rather than a reordered blob.
func _write_manifest() -> void:
	if _dry_run:
		print("\n(dry run: the manifest was not written)")
		return
	var keys: Array = _manifest.keys()
	keys.sort()
	var ordered: Dictionary = {}
	for key: String in keys:
		ordered[key] = _manifest[key]
	var document: Dictionary = {
		"_comment": (
			"Clips committed to this repository, named by the hash VoiceService looks "
			+ "up. Built by tools/bake_voice_bank.gd; do not edit by hand."
		),
		"model_id": VoiceService.MODEL_ID,
		"output_format": VoiceService.OUTPUT_FORMAT,
		"clips": ordered,
	}
	var file: FileAccess = FileAccess.open(MANIFEST, FileAccess.WRITE)
	if file == null:
		printerr("Could not write %s" % MANIFEST)
		return
	file.store_string(JSON.stringify(document, "\t", true) + "\n")
	file.close()
	print("wrote ", MANIFEST)


func _preview(text: String) -> String:
	var flat: String = text.replace("\n", " ")
	return flat if flat.length() <= 58 else flat.substr(0, 55) + "..."
