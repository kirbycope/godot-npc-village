extends GutTest
## [VoiceService] caching and budgeting, without synthesizing anything.
##
## No request is made here and no characters are spent. `tests/fixtures/line.mp3` is a
## real clip recorded from ElevenLabs once; the tests plant it in the cache under the
## key the service would compute and then check that `speak` finds it.
##
## The cache is the reason this project is affordable to run at all, so its key is
## worth pinning down: two villagers saying the same words in different voices must not
## collide, and the same villager saying the same words twice must hit.

const FIXTURE: String = "res://tests/fixtures/line.mp3"
const LINE: String = "Six silver, Maud. You said harvest's end."

var _persona: NPCPersona
var _planted: Array[String] = []


func before_each() -> void:
	_persona = NPCPersona.new()
	_persona.id = &"smith"
	_persona.display_name = "Aldric"
	_persona.voice_id = "pNInz6obpgDQGcFmaJgB"
	_persona.voice_stability = 0.55
	_persona.voice_similarity = 0.8
	_persona.voice_style = 0.25


func after_each() -> void:
	for path: String in _planted:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_planted.clear()


## Writes the recorded clip into the cache under `persona`'s key for `line`.
func _plant(line: String, persona: NPCPersona) -> String:
	var source: FileAccess = FileAccess.open(FIXTURE, FileAccess.READ)
	assert_not_null(source, "the recorded clip fixture should exist")
	var bytes: PackedByteArray = source.get_buffer(source.get_length())
	source.close()

	var key: String = VoiceService._cache_key(line, persona)
	var path: String = VoiceService._cache_path(key)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(VoiceService.CACHE_DIR)
	)
	var target: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(target, "should be able to write into the voice cache")
	target.store_buffer(bytes)
	target.close()
	_planted.append(path)
	return path


func test_the_voice_service_stays_offline_during_tests() -> void:
	assert_true(RuntimeMode.is_offline(), "a GUT run must be offline")
	assert_false(VoiceService.is_available(), "the service must not be armed to synthesize")


func test_the_recorded_clip_decodes_from_memory() -> void:
	# The whole runtime design rests on decoding response bytes straight into a stream.
	var file: FileAccess = FileAccess.open(FIXTURE, FileAccess.READ)
	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	var stream: AudioStreamMP3 = AudioStreamMP3.load_from_buffer(bytes)
	assert_not_null(stream, "the recorded clip should decode")
	assert_gt(stream.get_length(), 0.0, "the decoded clip should have a duration")


func test_a_cached_line_is_returned_without_spending_characters() -> void:
	_plant(LINE, _persona)
	var before: int = VoiceService.characters_used()

	watch_signals(VoiceService)
	var handle: int = VoiceService.speak(LINE, _persona)
	assert_gt(handle, 0, "a cached line should still get a handle")
	# The cache hit is emitted deferred, so let the frame finish.
	await wait_frames(2)

	assert_signal_emitted(VoiceService, "clip_ready")
	var parameters: Array = get_signal_parameters(VoiceService, "clip_ready")
	assert_eq(parameters[0], handle, "the clip should answer the handle it was given")
	assert_not_null(parameters[1], "a stream should come back")
	assert_true(parameters[2], "the clip should be reported as coming from the cache")
	assert_eq(
		VoiceService.characters_used(), before,
		"a cache hit must not count against the character budget",
	)


func test_an_uncached_line_is_refused_while_offline() -> void:
	# Offline the service may read the cache but must never reach for the network.
	var handle: int = VoiceService.speak("A line nobody has ever said before.", _persona)
	assert_eq(handle, 0, "an uncached line should be refused rather than requested")


func test_the_cache_key_is_stable_for_the_same_line_and_voice() -> void:
	assert_eq(
		VoiceService._cache_key(LINE, _persona),
		VoiceService._cache_key(LINE, _persona),
	)


func test_the_cache_key_separates_different_voices() -> void:
	var other: NPCPersona = NPCPersona.new()
	other.voice_id = "Xb7hH8MSUJpSbSDYk0k2"
	other.voice_stability = _persona.voice_stability
	other.voice_similarity = _persona.voice_similarity
	other.voice_style = _persona.voice_style
	assert_ne(
		VoiceService._cache_key(LINE, _persona),
		VoiceService._cache_key(LINE, other),
		"the same words in another voice are a different clip",
	)


func test_the_cache_key_separates_different_lines() -> void:
	assert_ne(
		VoiceService._cache_key(LINE, _persona),
		VoiceService._cache_key("Something else entirely.", _persona),
	)


func test_the_cache_key_tracks_the_synthesis_settings() -> void:
	var excitable: NPCPersona = NPCPersona.new()
	excitable.voice_id = _persona.voice_id
	excitable.voice_stability = 0.1
	excitable.voice_similarity = _persona.voice_similarity
	excitable.voice_style = _persona.voice_style
	assert_ne(
		VoiceService._cache_key(LINE, _persona),
		VoiceService._cache_key(LINE, excitable),
		"settings change how the line sounds, so they change the clip",
	)


func test_speak_refuses_a_persona_with_no_voice() -> void:
	var mute: NPCPersona = NPCPersona.new()
	mute.id = &"mute"
	assert_eq(VoiceService.speak(LINE, mute), 0)


func test_speak_refuses_an_empty_line() -> void:
	assert_eq(VoiceService.speak("   ", _persona), 0)
