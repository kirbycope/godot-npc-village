extends SceneTree
## Generates `resources/default_bus_layout.tres`, which adds the microphone bus.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/build_audio_bus.gd
##
## Push to talk needs somewhere for the microphone to arrive. An `AudioStreamMicrophone`
## plays onto a bus, and an `AudioEffectCapture` on that bus is what lets a script read
## the samples back out. The bus is muted so the player does not hear themselves echoed,
## and its send is set to Master only so the effect still runs.

const OUTPUT: String = "res://resources/default_bus_layout.tres"
const BUS_NAME: StringName = &"Record"


func _init() -> void:
	# Bus 0 is always Master and is left alone.
	var index: int = AudioServer.bus_count
	AudioServer.add_bus(index)
	AudioServer.set_bus_name(index, BUS_NAME)
	AudioServer.set_bus_send(index, &"Master")
	# Muted, or the player hears their own voice a frame late, which is unpleasant.
	AudioServer.set_bus_mute(index, true)
	AudioServer.add_bus_effect(index, AudioEffectCapture.new())

	var layout: AudioBusLayout = AudioServer.generate_bus_layout()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://resources"))
	if ResourceSaver.save(layout, OUTPUT) != OK:
		printerr("Could not save %s" % OUTPUT)
		quit(1)
		return
	print("wrote %s with buses:" % OUTPUT)
	for i: int in AudioServer.bus_count:
		print("  %d %s (muted=%s, effects=%d)" % [
			i, AudioServer.get_bus_name(i), AudioServer.is_bus_mute(i),
			AudioServer.get_bus_effect_count(i),
		])
	quit(0)
