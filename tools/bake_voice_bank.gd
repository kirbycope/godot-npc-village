extends SceneTree
## Builds `assets/voice/`, the bank of spoken lines committed to the repository.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/bake_voice_bank.gd
##     ... -s tools/bake_voice_bank.gd -- --dry-run      report, synthesize nothing
##     ... -s tools/bake_voice_bank.gd -- --promote-only copy from the cache, never call out
##
## The bank holds the hand-written opening lines and nothing else. Those are the lines on
## each persona's `opening_line`, the first thing a player hears from a villager, and the
## only dialogue that recurs word for word every session. Anything the model invented is
## different every time, so its clip is dead weight the moment it is written and is
## pruned out.
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
const PERSONA_DIR: String = "res://resources/personas"

## Seconds to wait for one synthesis before giving up on it.
const REQUEST_TIMEOUT: float = 30.0

## The VoiceService autoload, fetched by node path rather than by name. Naming the
## autoload in code would make this script depend on it at compile time, and a `-s`
## script is compiled before the autoloads exist.
var _voice: Node

## Its constants, read from the script so the bank is written with exactly the model and
## format the game will look for.
var _voice_constants: Dictionary = {}

## Keys of the clips the authored dialogue asks for. Anything in the bank outside this
## set is a leftover and is removed when pruning.
var _authored: Dictionary = {}

var _dry_run: bool = false
var _promote_only: bool = false

## By default the bank is exactly the authored dialogue and nothing else. Pass
## --keep-unauthored to hold on to clips captured from generated conversation.
var _keep_unauthored: bool = false
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
		elif argument == "--keep-unauthored":
			_keep_unauthored = true

	_voice = root.get_node_or_null("VoiceService")
	if _voice == null:
		printerr("VoiceService is not autoloaded; cannot compute cache keys.")
		quit(1)
		return
	_voice_constants = _voice.get_script().get_script_constant_map()

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BANK_DIR))
	_load_manifest()

	_collect_authored()
	_promote_cached_clips()
	await _bake_authored_lines()
	_prune()

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


## Works out the cache key of every hand-written line, before anything is copied.
##
## Hand-written means the `opening_line` on each persona. Those are fixed text: they
## recur every session, so a clip of one is worth
## carrying in the repository forever. A line the model invented is different every time
## and its clip is dead weight the moment it is written, which is why the bank is pruned
## down to this set.
func _collect_authored() -> void:
	for persona: NPCPersona in _load_personas().values():
		var line: String = persona.opening_line.strip_edges()
		if not line.is_empty():
			_authored[_voice.call("_cache_key", line, persona)] = true
	print("Hand-written lines: %d" % _authored.size())


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
		if not _keep_unauthored and not _authored.has(key):
			# A line the model happened to say once. It will never be said again in
			# exactly those words, so the clip would be dead weight in the repository.
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


## Synthesizes every hand-written opening line that is not already in the bank.
func _bake_authored_lines() -> void:
	var personas: Dictionary = _load_personas()
	var ids: Array = personas.keys()
	ids.sort()
	for persona_id: String in ids:
		var persona: NPCPersona = personas[persona_id]
		var line: String = persona.opening_line.strip_edges()
		if not line.is_empty():
			await _bake_one(persona, line)


## Every persona in the project, by id.
func _load_personas() -> Dictionary:
	var personas: Dictionary = {}
	var directory: DirAccess = DirAccess.open(PERSONA_DIR)
	if directory == null:
		return personas
	for file_name: String in directory.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var persona: NPCPersona = load("%s/%s" % [PERSONA_DIR, file_name])
		if persona != null:
			personas[String(persona.id)] = persona
	return personas


func _bake_one(persona: NPCPersona, text: String) -> void:
	var key: String = _voice.call("_cache_key", text, persona)
	if _manifest.has(key):
		_skipped += 1
		return

	# The bank may already hold the file even if the manifest lost track of it, for
	# instance after the manifest was deleted to rebuild it. Adopting the file costs
	# nothing; re-synthesizing it costs characters for a clip already on disk.
	var banked: String = "%s/%s.mp3" % [BANK_DIR, key]
	if FileAccess.file_exists(banked):
		print("  adopt    %-9s %s" % [persona.display_name, _preview(text)])
		if not _dry_run:
			_manifest[key] = _entry(persona, text, FileAccess.get_file_as_bytes(banked))
		_promoted += 1
		return

	# It may already be in the writable cache even without an index entry.
	var cached: String = "%s/%s.mp3" % [CACHE_DIR, key]
	if FileAccess.file_exists(cached):
		print("  promote  %-9s %s" % [persona.display_name, _preview(text)])
		if not _dry_run and _copy(cached, "%s/%s.mp3" % [BANK_DIR, key]):
			_manifest[key] = _entry(persona, text, FileAccess.get_file_as_bytes(cached))
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
	_manifest[key] = _entry(persona, text, bytes)
	_baked += 1
	_characters += text.length()


## One synthesis, straight to the API. This deliberately does not go through
## `VoiceService`, which would refuse: the service is budgeted for a play session, while
## baking is a deliberate one-off that should not be silently capped.
func _synthesize(persona: NPCPersona, text: String) -> PackedByteArray:
	# Fetched by path for the same reason as VoiceService: naming an autoload makes this
	# script depend on it at compile time, before any autoload exists.
	var secrets: Node = root.get_node_or_null("Secrets")
	var key: String = str(secrets.call("get_key", "elevenlabs")) if secrets != null else ""
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
		"model_id": _voice_constants["MODEL_ID"],
		"voice_settings": {
			"stability": persona.voice_stability,
			"similarity_boost": persona.voice_similarity,
			"style": persona.voice_style,
			"use_speaker_boost": true,
		},
	})
	var url: String = (
		(str(_voice_constants["ENDPOINT"]) % persona.voice_id)
		+ "?output_format=" + str(_voice_constants["OUTPUT_FORMAT"])
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


## The clip's own metadata. The duration is decoded from the bytes rather than read off
## a loaded resource: a file written to `res://` this instant has not been imported yet,
## so loading it fails and every freshly baked clip would be recorded as zero seconds
## long.
func _entry(persona: NPCPersona, text: String, bytes: PackedByteArray) -> Dictionary:
	var seconds: float = 0.0
	var stream: AudioStreamMP3 = AudioStreamMP3.load_from_buffer(bytes)
	if stream != null:
		seconds = stream.get_length()
	return {
		"text": text,
		"persona": String(persona.id),
		"speaker": persona.display_name,
		"voice_id": persona.voice_id,
		"model_id": _voice_constants["MODEL_ID"],
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
		"model_id": _voice_constants["MODEL_ID"],
		"output_format": _voice_constants["OUTPUT_FORMAT"],
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


## Removes anything from the bank that the authored dialogue does not ask for.
##
## The bank fills up with clips captured from whatever the model happened to say while
## the game was running, and those lines never recur: a generated sentence is different
## every time, so the clip is dead weight in the repository the moment it is written.
## What belongs here permanently is the authored dialogue, which is fixed, recurs every
## session, and is the only thing a keyless build can rely on.
func _prune() -> void:
	if _keep_unauthored:
		return
	var stale: Array[String] = []
	for key: String in _manifest:
		if not _authored.has(key):
			stale.append(key)
	if stale.is_empty():
		return
	for key: String in stale:
		var entry: Dictionary = _manifest[key]
		print("  remove   %-9s %s" % [
			entry.get("speaker", "?"), _preview(str(entry.get("text", ""))),
		])
		if _dry_run:
			continue
		_manifest.erase(key)
		var path: String = "%s/%s.mp3" % [BANK_DIR, key]
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".import"))
	print("  %d unauthored clip(s) removed" % stale.size())
