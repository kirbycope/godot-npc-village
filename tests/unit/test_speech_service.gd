extends GutTest
## [SpeechService]'s WAV encoding, offline.
##
## Nothing here opens the microphone or makes a request. What is checked is the encoder,
## because it is the part that fails silently: a malformed header is accepted by the
## upload and comes back as an empty transcript, which looks exactly like the player
## having said nothing.

const HEADER_BYTES: int = 44


func _frames(count: int, value: float) -> PackedVector2Array:
	var frames: PackedVector2Array = PackedVector2Array()
	frames.resize(count)
	for i: int in count:
		frames[i] = Vector2(value, value)
	return frames


func test_the_service_is_disabled_during_tests() -> void:
	assert_true(RuntimeMode.is_offline())
	assert_false(SpeechService.is_available(), "the microphone must not open in a test")
	assert_false(SpeechService.is_listening())


func test_the_header_is_a_riff_wave() -> void:
	var wav: PackedByteArray = SpeechService._encode_wav(_frames(100, 0.0))
	assert_eq(wav.slice(0, 4).get_string_from_ascii(), "RIFF")
	assert_eq(wav.slice(8, 12).get_string_from_ascii(), "WAVE")
	assert_eq(wav.slice(12, 16).get_string_from_ascii(), "fmt ")
	assert_eq(wav.slice(36, 40).get_string_from_ascii(), "data")


func test_the_header_declares_16_bit_mono_pcm() -> void:
	var wav: PackedByteArray = SpeechService._encode_wav(_frames(100, 0.0))
	assert_eq(wav.decode_u16(20), 1, "format should be PCM")
	assert_eq(wav.decode_u16(22), 1, "a microphone is downmixed to one channel")
	assert_eq(wav.decode_u16(34), 16, "samples should be 16 bit")
	var rate: int = wav.decode_u32(24)
	assert_eq(rate, int(AudioServer.get_mix_rate()), "the rate should be the mixer's")
	assert_eq(wav.decode_u32(28), rate * 2, "byte rate should follow from the rest")
	assert_eq(wav.decode_u16(32), 2, "block align is two bytes for 16 bit mono")


func test_the_declared_sizes_match_the_payload() -> void:
	# A wrong size here is the classic way to produce a file that opens and plays silence.
	var wav: PackedByteArray = SpeechService._encode_wav(_frames(512, 0.25))
	assert_eq(wav.size(), HEADER_BYTES + 512 * 2)
	assert_eq(wav.decode_u32(4), wav.size() - 8, "the RIFF size counts everything after it")
	assert_eq(wav.decode_u32(40), 512 * 2, "the data chunk should be two bytes per frame")


func test_stereo_frames_are_averaged_rather_than_interleaved() -> void:
	var frames: PackedVector2Array = PackedVector2Array([Vector2(1.0, -1.0), Vector2(0.5, 0.5)])
	var wav: PackedByteArray = SpeechService._encode_wav(frames)
	assert_eq(wav.size(), HEADER_BYTES + 4, "two frames become two samples, not four")
	assert_eq(wav.decode_s16(HEADER_BYTES), 0, "1.0 and -1.0 average to silence")
	assert_almost_eq(wav.decode_s16(HEADER_BYTES + 2), 16383, 2, "0.5 should be half scale")


func test_samples_are_clamped_rather_than_wrapped() -> void:
	# Without the clamp an overdriven microphone wraps to full negative, which is the
	# loudest possible noise rather than the loudest possible signal.
	var wav: PackedByteArray = SpeechService._encode_wav(
		PackedVector2Array([Vector2(4.0, 4.0), Vector2(-4.0, -4.0)])
	)
	assert_eq(wav.decode_s16(HEADER_BYTES), 32767)
	assert_eq(wav.decode_s16(HEADER_BYTES + 2), -32767)


func test_an_empty_recording_still_produces_a_valid_header() -> void:
	var wav: PackedByteArray = SpeechService._encode_wav(PackedVector2Array())
	assert_eq(wav.size(), HEADER_BYTES)
	assert_eq(wav.decode_u32(40), 0)
