extends Node
## Turns what the player says into text, with ElevenLabs' speech-to-text.
##
## Autoloaded as `SpeechService`. It owns the microphone and nothing else: capture while
## a key is held, encode, transcribe, emit. Who hears the result and what they do about
## it belongs to [PlayerVoice] and the conversation system.
##
## The captured frames are encoded as a 16-bit mono WAV in memory and posted as
## multipart form data. Nothing is written to disk, and the microphone is only opened
## while the key is actually down rather than left running, so the game is not quietly
## holding an open input stream for a whole session.
##
## Transcription is metered separately from speech synthesis on an ElevenLabs account,
## by audio length rather than by character, so a held key is the thing that costs and a
## long silence costs as much as a long sentence. That is why [member max_seconds] exists.

## Recording began.
signal listening_started()

## Recording ended after `seconds`. The transcript has not arrived yet.
signal listening_stopped(seconds: float)

## The player's words came back.
signal transcribed(text: String)

## Nothing usable came back. `reason` is safe to show in a debug overlay.
signal transcription_failed(reason: String)

const ENDPOINT: String = "https://api.elevenlabs.io/v1/speech-to-text"

## ElevenLabs' transcription model.
const MODEL_ID: String = "scribe_v1"

## The bus carrying the microphone, created by `tools/build_audio_bus.gd`.
const BUS_NAME: StringName = &"Record"

## Sample rate written into the WAV header. The capture effect runs at the mix rate, so
## this is read from the server rather than assumed.
const TIMEOUT_SECONDS: float = 25.0

## Recordings shorter than this are discarded as a mis-tap rather than sent.
@export_range(0.1, 2.0, 0.05) var min_seconds: float = 0.35

## A held key stops recording here regardless, so a key that sticks cannot run up a bill.
@export_range(2.0, 60.0, 1.0) var max_seconds: float = 20.0

## Set false to disable the microphone without removing the key.
@export var enabled: bool = true

var _capture: AudioEffectCapture
var _microphone: AudioStreamPlayer
var _listening: bool = false
var _started_at: float = 0.0
var _available: bool = false


func _ready() -> void:
	if RuntimeMode.is_offline():
		# A test run never opens the microphone and never transcribes.
		return
	_available = Secrets.has_key("elevenlabs")
	if not _available:
		push_warning("[SpeechService] No ElevenLabs key. Push to talk is disabled.")
		return
	_prepare_bus()


func _process(_delta: float) -> void:
	if _listening and Time.get_ticks_msec() * 0.001 - _started_at > max_seconds:
		stop_listening()


## Whether the microphone can be used at all.
func is_available() -> bool:
	return _available and enabled and _capture != null


## Whether the microphone is open right now.
func is_listening() -> bool:
	return _listening


## Opens the microphone and begins collecting samples.
func start_listening() -> void:
	if not is_available() or _listening:
		return
	_capture.clear_buffer()
	if _microphone != null and not _microphone.playing:
		_microphone.play()
	_listening = true
	_started_at = Time.get_ticks_msec() * 0.001
	listening_started.emit()


## Closes the microphone and sends what was captured for transcription.
func stop_listening() -> void:
	if not _listening:
		return
	_listening = false
	var seconds: float = Time.get_ticks_msec() * 0.001 - _started_at
	listening_stopped.emit(seconds)

	var frames: PackedVector2Array = _capture.get_buffer(_capture.get_frames_available())
	if _microphone != null and _microphone.playing:
		_microphone.stop()

	if seconds < min_seconds or frames.is_empty():
		transcription_failed.emit("too short")
		return
	_transcribe(_encode_wav(frames))


## Finds the record bus and hangs a microphone on it.
func _prepare_bus() -> void:
	var bus: int = AudioServer.get_bus_index(BUS_NAME)
	if bus == -1:
		push_warning(
			"[SpeechService] No '%s' audio bus. " % BUS_NAME
			+ "Run tools/build_audio_bus.gd and set it as the default bus layout."
		)
		return
	for i: int in AudioServer.get_bus_effect_count(bus):
		var effect: AudioEffect = AudioServer.get_bus_effect(bus, i)
		if effect is AudioEffectCapture:
			_capture = effect
			break
	if _capture == null:
		push_warning("[SpeechService] The '%s' bus has no AudioEffectCapture." % BUS_NAME)
		return

	_microphone = AudioStreamPlayer.new()
	_microphone.name = "Microphone"
	_microphone.stream = AudioStreamMicrophone.new()
	_microphone.bus = BUS_NAME
	add_child(_microphone)


## Packs captured frames into a 16-bit mono WAV.
##
## The capture effect hands over stereo floats at the mixer's rate. The two channels of
## a microphone carry the same signal, so they are averaged rather than interleaved,
## which halves what has to be uploaded for no loss at all.
func _encode_wav(frames: PackedVector2Array) -> PackedByteArray:
	var rate: int = int(AudioServer.get_mix_rate())
	var samples: PackedByteArray = PackedByteArray()
	samples.resize(frames.size() * 2)
	for i: int in frames.size():
		var mono: float = clampf((frames[i].x + frames[i].y) * 0.5, -1.0, 1.0)
		samples.encode_s16(i * 2, int(mono * 32767.0))

	var wav: PackedByteArray = PackedByteArray()
	wav.append_array("RIFF".to_ascii_buffer())
	wav.append_array(_u32(36 + samples.size()))
	wav.append_array("WAVEfmt ".to_ascii_buffer())
	wav.append_array(_u32(16))          # PCM header length
	wav.append_array(_u16(1))           # format: PCM
	wav.append_array(_u16(1))           # channels: mono
	wav.append_array(_u32(rate))
	wav.append_array(_u32(rate * 2))    # byte rate
	wav.append_array(_u16(2))           # block align
	wav.append_array(_u16(16))          # bits per sample
	wav.append_array("data".to_ascii_buffer())
	wav.append_array(_u32(samples.size()))
	wav.append_array(samples)
	return wav


func _u16(value: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(2)
	bytes.encode_u16(0, value)
	return bytes


func _u32(value: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	return bytes


## Posts the audio as multipart form data, which the endpoint requires. Godot has no
## helper for this, so the body is assembled by hand.
func _transcribe(wav: PackedByteArray) -> void:
	var boundary: String = "----GodotNPCVillage%d" % Time.get_ticks_usec()
	var body: PackedByteArray = PackedByteArray()

	body.append_array(("--%s\r\n" % boundary).to_utf8_buffer())
	body.append_array(
		"Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".to_utf8_buffer()
	)
	body.append_array(("%s\r\n" % MODEL_ID).to_utf8_buffer())

	body.append_array(("--%s\r\n" % boundary).to_utf8_buffer())
	body.append_array((
		"Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n"
	).to_utf8_buffer())
	body.append_array("Content-Type: audio/wav\r\n\r\n".to_utf8_buffer())
	body.append_array(wav)
	body.append_array("\r\n".to_utf8_buffer())
	body.append_array(("--%s--\r\n" % boundary).to_utf8_buffer())

	var request: HTTPRequest = HTTPRequest.new()
	request.timeout = TIMEOUT_SECONDS
	add_child(request)
	request.request_completed.connect(_on_transcribed.bind(request))

	var headers: PackedStringArray = PackedStringArray([
		"Content-Type: multipart/form-data; boundary=%s" % boundary,
		"xi-api-key: %s" % Secrets.get_key("elevenlabs"),
	])
	var error: Error = request.request_raw(
		ENDPOINT, headers, HTTPClient.METHOD_POST, body
	)
	if error != OK:
		request.queue_free()
		transcription_failed.emit("could not start request: %s" % error_string(error))


func _on_transcribed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	request: HTTPRequest,
) -> void:
	if is_instance_valid(request):
		request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS:
		transcription_failed.emit("transport error %d" % result)
		return

	var reader: JSON = JSON.new()
	if reader.parse(body.get_string_from_utf8()) != OK:
		transcription_failed.emit("response was not JSON")
		return
	var payload: Variant = reader.data
	if typeof(payload) != TYPE_DICTIONARY:
		transcription_failed.emit("response was not an object")
		return
	var data: Dictionary = payload

	if response_code != 200:
		var detail: Variant = data.get("detail", {})
		var message: String = ""
		if typeof(detail) == TYPE_DICTIONARY:
			message = str(detail.get("message", detail.get("status", "")))
		transcription_failed.emit("HTTP %d %s" % [response_code, message])
		return

	var text: String = str(data.get("text", "")).strip_edges()
	if text.is_empty():
		# Silence transcribes to an empty string rather than to an error.
		transcription_failed.emit("nothing was said")
		return
	transcribed.emit(text)
