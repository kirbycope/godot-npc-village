extends Node
## Speaks a villager's line with ElevenLabs, live, while the game runs.
##
## Autoloaded as `VoiceService`. A line goes out as an HTTP request and comes back as
## an [AudioStreamMP3] decoded straight from the response bytes, nothing is written
## into the project, so the villagers can say things no one wrote in advance.
##
## Two things keep that affordable.
##
## The first is the cache. Every clip is keyed by the hash of the text, the voice and
## the synthesis settings, and kept under `user://voice_cache/`. A line that has been
## said before is read off disk and costs nothing, which matters because the hand-written
## opening lines are said once per playthrough per group, and the model itself often
## lands on the same short phrase twice.
##
## The second is the budget. The service reads the account's real character quota on
## startup and refuses to synthesize once the configured ceiling is reached, so an
## overnight session cannot quietly drain the month's allowance.

## A clip finished and is ready to play.
signal clip_ready(handle: int, stream: AudioStream, from_cache: bool)

## A clip could not be produced. `reason` is safe to show in a debug overlay.
signal clip_failed(handle: int, reason: String)

## The account's quota came back from the API.
signal quota_updated(used: int, limit: int, tier: String)

## The session ceiling was hit. Every later request fails until the ceiling is raised.
signal budget_exhausted(used: int, ceiling: int)

const ENDPOINT: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const SUBSCRIPTION_ENDPOINT: String = "https://api.elevenlabs.io/v1/user/subscription"

## Flash is the lowest-latency model and bills at half the character rate. Measured
## round trip on this project is a little under 400 ms for a short line, which is
## inside the beat the villagers leave between turns anyway.
const MODEL_ID: String = "eleven_flash_v2_5"

## 44.1 kHz 128 kbps MP3. `AudioStreamMP3.load_from_buffer` decodes it directly.
const OUTPUT_FORMAT: String = "mp3_44100_128"

const CACHE_DIR: String = "user://voice_cache"

## Clips committed to the repository. Checked before the writable cache and before any
## request, so a build with no key and no network still has a voice for every line that
## has been baked. `tools/bake_voice_bank.gd` promotes clips from the writable cache into
## here, and writes the manifest alongside them.
const BANK_DIR: String = "res://assets/voice"

## Maps a clip hash to what it says, who says it, and how long it runs. Without this a
## bank of hash-named files is unreadable: nothing on disk records that
## `0357022e...mp3` is Maud saying "Bread for two, that morning".
const BANK_MANIFEST: String = "res://assets/voice/manifest.json"

## The same index for the writable cache, so clips can be promoted into the bank later
## with their text intact.
const CACHE_INDEX: String = "user://voice_cache/index.json"

## Requests allowed in flight at once. Villagers speak one at a time per group, so
## this only matters when several groups talk across the village together.
const MAX_CONCURRENT: int = 4

const TIMEOUT_SECONDS: float = 20.0

## Characters this session may synthesize before the service refuses.
##
## A free ElevenLabs account gets 10,000 characters a month and a spoken line runs 50 to
## 100 of them, so this is roughly twenty conversations in one sitting.
##
## This used to be the only brake and had to be tight enough to hurt. The real control is
## now `ConversationGroup.max_turns_per_villager`, which stops a group after two lines
## each until the player speaks or walks away and comes back; this is the backstop behind
## it rather than the thing that shapes play, so it can afford to be looser.
@export var session_character_ceiling: int = 2000

## Set false to silence the villagers without removing the key.
@export var enabled: bool = true

## Where the committed bank can be fetched from when it is not packed into the build.
##
## This is what makes a web export work without an API key. The clips are ordinary files
## in the repository, so raw.githubusercontent.com serves them directly; the export can
## then leave the audio out of the `.pck` and stay small, and the page pulls each clip
## the first time it is needed and keeps it in `user://`, which is browser storage. Set
## it to "" to disable remote fetching entirely.
@export var remote_bank_base_url: String = (
	"https://raw.githubusercontent.com/kirbycope/godot-npc-village/main/assets/voice"
)

var _characters_used: int = 0
var _quota_used: int = 0
var _quota_limit: int = 0
var _tier: String = ""
var _next_handle: int = 1
var _active: int = 0
var _queue: Array[Dictionary] = []
var _available: bool = false

## Hashes present in the committed bank, from its manifest.
var _bank: Dictionary = {}

## What the writable cache holds, keyed by hash. Written out whenever it grows.
var _index: Dictionary = {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_load_bank()
	_load_index()
	if RuntimeMode.is_offline():
		# A test run reads clips from the fixtures and never synthesizes, so no request
		# is made and no characters are spent against the account.
		_available = false
		return
	_available = Secrets.has_key("elevenlabs")
	if not _available:
		push_warning("[VoiceService] No ElevenLabs key. The villagers will mime.")
		return
	_fetch_quota()


## Whether a key is present and the budget has not been spent.
func is_available() -> bool:
	return _available and enabled and _characters_used < session_character_ceiling


## Characters synthesized this session. Cache hits do not count.
func characters_used() -> int:
	return _characters_used


## The account quota as last reported by the API, or zeros before it answers.
func quota() -> Dictionary:
	return {"used": _quota_used, "limit": _quota_limit, "tier": _tier}


## Speak `text` as `persona`. Returns a handle that identifies the clip in
## [signal clip_ready] and [signal clip_failed]; 0 means the request was refused
## outright and no signal will follow.
func speak(text: String, persona: NPCPersona) -> int:
	var line: String = text.strip_edges()
	if line.is_empty() or persona == null or persona.voice_id.is_empty():
		return 0

	var handle: int = _next_handle
	_next_handle += 1
	var key: String = _cache_key(line, persona)

	# Committed clips first, then the writable cache, before anything else and before
	# any question of whether the service is available. A clip already on disk costs
	# nothing to play and needs no key, no quota and no network, so a keyless build, an
	# offline session and a test run can all still hear every line that has been baked.
	var banked: AudioStream = _read_bank(key)
	if banked != null:
		clip_ready.emit.call_deferred(handle, banked, true)
		return handle

	var cached: AudioStream = _read_cache(key)
	if cached != null:
		clip_ready.emit.call_deferred(handle, cached, true)
		return handle

	# The manifest is small and ships with every build, so it can be consulted even when
	# the audio itself was left out of the export. A hit here means the clip exists in
	# the repository and can be downloaded rather than synthesized.
	if _bank.has(key) and not remote_bank_base_url.is_empty():
		_fetch_remote(key, handle)
		return handle

	if not enabled or not _available:
		return 0

	if _characters_used + line.length() > session_character_ceiling:
		budget_exhausted.emit(_characters_used, session_character_ceiling)
		clip_failed.emit.call_deferred(handle, "session character ceiling reached")
		return handle

	_queue.append({
		"handle": handle,
		"text": line,
		"persona": persona,
		"key": key,
	})
	_pump()
	return handle


## Drops everything not yet sent. In-flight requests still finish; their clips are
## cached and simply not played.
func cancel_queued() -> void:
	for job: Dictionary in _queue:
		clip_failed.emit(int(job["handle"]), "cancelled")
	_queue.clear()


func _pump() -> void:
	while _active < MAX_CONCURRENT and not _queue.is_empty():
		_send(_queue.pop_front())


func _send(job: Dictionary) -> void:
	var persona: NPCPersona = job["persona"]
	var text: String = job["text"]

	var request: HTTPRequest = HTTPRequest.new()
	request.timeout = TIMEOUT_SECONDS
	add_child(request)
	_active += 1
	request.request_completed.connect(_on_clip_completed.bind(request, job))

	var headers: PackedStringArray = PackedStringArray([
		"Content-Type: application/json",
		"xi-api-key: %s" % Secrets.get_key("elevenlabs"),
		"Accept: audio/mpeg",
	])
	var body: String = JSON.stringify({
		"text": text,
		"model_id": MODEL_ID,
		"voice_settings": {
			"stability": persona.voice_stability,
			"similarity_boost": persona.voice_similarity,
			"style": persona.voice_style,
			"use_speaker_boost": true,
		},
	})
	var url: String = (ENDPOINT % persona.voice_id) + "?output_format=" + OUTPUT_FORMAT
	var error: Error = request.request(url, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		_active -= 1
		request.queue_free()
		clip_failed.emit(int(job["handle"]), "could not start request: %s" % error_string(error))
		_pump()
		return
	_characters_used += text.length()


func _on_clip_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	request: HTTPRequest,
	job: Dictionary,
) -> void:
	_active -= 1
	if is_instance_valid(request):
		request.queue_free()
	var handle: int = int(job["handle"])

	if result != HTTPRequest.RESULT_SUCCESS:
		clip_failed.emit(handle, "transport error %d" % result)
		_pump()
		return

	if response_code != 200:
		clip_failed.emit(handle, _describe_error(response_code, body))
		_pump()
		return

	var stream: AudioStreamMP3 = AudioStreamMP3.load_from_buffer(body)
	if stream == null:
		clip_failed.emit(handle, "response was not decodable audio")
		_pump()
		return

	_write_cache(str(job["key"]), body)
	_record(str(job["key"]), job, body.size(), stream.get_length())
	clip_ready.emit(handle, stream, false)
	_pump()


## ElevenLabs reports refusals as structured JSON rather than plain status text, and
## the distinction matters: a free account is told it may not use a library voice,
## which is a different problem from being out of characters.
func _describe_error(response_code: int, body: PackedByteArray) -> String:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("detail"):
		var detail: Variant = parsed["detail"]
		if typeof(detail) == TYPE_DICTIONARY:
			return "HTTP %d %s: %s" % [
				response_code,
				detail.get("code", detail.get("status", "")),
				detail.get("message", ""),
			]
		return "HTTP %d: %s" % [response_code, str(detail)]
	return "HTTP %d" % response_code


## Identifies a clip by everything that changes how it sounds. Settings are rounded so
## a float that drifts in the last decimal place does not miss the cache.
func _cache_key(text: String, persona: NPCPersona) -> String:
	var material: String = "%s|%s|%.2f|%.2f|%.2f|%s" % [
		persona.voice_id,
		MODEL_ID,
		persona.voice_stability,
		persona.voice_similarity,
		persona.voice_style,
		text,
	]
	return material.sha256_text()


func _cache_path(key: String) -> String:
	return "%s/%s.mp3" % [CACHE_DIR, key]


func _read_cache(key: String) -> AudioStream:
	return _read_mp3(_cache_path(key))


func _write_cache(key: String, bytes: PackedByteArray) -> void:
	var file: FileAccess = FileAccess.open(_cache_path(key), FileAccess.WRITE)
	if file == null:
		push_warning("[VoiceService] Could not write the cache entry for %s." % key)
		return
	file.store_buffer(bytes)
	file.close()


## Reads the real account quota so the HUD can show what is actually left rather than
## only what this session has spent.
func _fetch_quota() -> void:
	var request: HTTPRequest = HTTPRequest.new()
	request.timeout = TIMEOUT_SECONDS
	add_child(request)
	request.request_completed.connect(_on_quota_completed.bind(request))
	var headers: PackedStringArray = PackedStringArray([
		"xi-api-key: %s" % Secrets.get_key("elevenlabs"),
	])
	if request.request(SUBSCRIPTION_ENDPOINT, headers, HTTPClient.METHOD_GET) != OK:
		request.queue_free()


func _on_quota_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	request: HTTPRequest,
) -> void:
	if is_instance_valid(request):
		request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_quota_used = int(parsed.get("character_count", 0))
	_quota_limit = int(parsed.get("character_limit", 0))
	_tier = str(parsed.get("tier", ""))
	var remaining: int = _quota_limit - _quota_used
	if remaining < session_character_ceiling:
		session_character_ceiling = maxi(0, remaining)
	print("[VoiceService] %s tier, %d of %d characters used this month." % [
		_tier, _quota_used, _quota_limit,
	])
	quota_updated.emit(_quota_used, _quota_limit, _tier)


# --------------------------------------------------------------------------------
# The committed bank
# --------------------------------------------------------------------------------

## Reads the manifest of clips committed to the repository.
func _load_bank() -> void:
	if not FileAccess.file_exists(BANK_MANIFEST):
		return
	var file: FileAccess = FileAccess.open(BANK_MANIFEST, FileAccess.READ)
	if file == null:
		return
	var reader: JSON = JSON.new()
	var text: String = file.get_as_text()
	file.close()
	if reader.parse(text) != OK or typeof(reader.data) != TYPE_DICTIONARY:
		push_warning("[VoiceService] The voice bank manifest could not be read.")
		return
	var data: Dictionary = reader.data
	_bank = data.get("clips", {})
	print("[VoiceService] Voice bank: %d committed clips." % _bank.size())


## A clip from the committed bank, or null when it holds none for this key.
func _read_bank(key: String) -> AudioStream:
	if _bank.is_empty():
		return null
	if not _bank.has(key):
		return null
	return _read_mp3("%s/%s.mp3" % [BANK_DIR, key])


func _load_index() -> void:
	if not FileAccess.file_exists(CACHE_INDEX):
		return
	var file: FileAccess = FileAccess.open(CACHE_INDEX, FileAccess.READ)
	if file == null:
		return
	var reader: JSON = JSON.new()
	var text: String = file.get_as_text()
	file.close()
	if reader.parse(text) == OK and typeof(reader.data) == TYPE_DICTIONARY:
		_index = reader.data


## Notes what a freshly synthesized clip says, so it can be promoted into the bank with
## its text rather than as an anonymous hash.
func _record(key: String, job: Dictionary, bytes: int, seconds: float) -> void:
	var persona: NPCPersona = job["persona"]
	_index[key] = {
		"text": job["text"],
		"persona": String(persona.id),
		"speaker": persona.display_name,
		"voice_id": persona.voice_id,
		"model_id": MODEL_ID,
		"bytes": bytes,
		"seconds": snappedf(seconds, 0.01),
	}
	var file: FileAccess = FileAccess.open(CACHE_INDEX, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_index, "\t", true))
	file.close()


## Decodes an mp3 from `path`, or null if it is missing or unreadable.
func _read_mp3(path: String) -> AudioStream:
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	if bytes.is_empty():
		return null
	return AudioStreamMP3.load_from_buffer(bytes)


## Downloads a banked clip and caches it, so it is paid for once per player rather than
## once per hearing. A failure here is not fatal: the line still reads as a subtitle.
func _fetch_remote(key: String, handle: int) -> void:
	var request: HTTPRequest = HTTPRequest.new()
	request.timeout = TIMEOUT_SECONDS
	add_child(request)
	request.request_completed.connect(_on_remote_completed.bind(request, key, handle))
	var url: String = "%s/%s.mp3" % [remote_bank_base_url.rstrip("/"), key]
	if request.request(url) != OK:
		request.queue_free()
		clip_failed.emit.call_deferred(handle, "could not start the bank download")


func _on_remote_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	request: HTTPRequest,
	key: String,
	handle: int,
) -> void:
	if is_instance_valid(request):
		request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		clip_failed.emit(handle, "bank download failed (HTTP %d)" % response_code)
		return
	var stream: AudioStreamMP3 = AudioStreamMP3.load_from_buffer(body)
	if stream == null:
		clip_failed.emit(handle, "the downloaded clip was not decodable audio")
		return
	_write_cache(key, body)
	clip_ready.emit(handle, stream, true)


## The opening lines for `persona_id`, in the order they should be spoken.
##
## Read from the committed bank's manifest, which is where the authored dialogue lives:
## it is baked once, carried in the repository, and is the only text in the game that is
## the same every session. Returns nothing when nothing has been baked.
func opening_lines_for(persona_id: StringName) -> Array[String]:
	var found: Array[Dictionary] = []
	for key: String in _bank:
		var entry: Dictionary = _bank[key]
		if not entry.has("opening_order"):
			continue
		if StringName(str(entry.get("persona", ""))) != persona_id:
			continue
		found.append(entry)
	found.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["opening_order"]) < int(b["opening_order"])
	)
	var lines: Array[String] = []
	for entry: Dictionary in found:
		lines.append(str(entry["text"]))
	return lines
