extends GutTest
## The villagers' bodies and their animations have to share one rig.
##
## The Quaternius fantasy outfits and the Universal Animation Library are modelled on the
## same skeleton, which is the only reason any villager can play any of the 262 clips
## with no retargeting step. That is an assumption about two third-party packs, so it is
## worth asserting rather than trusting: if a future pack update changed a joint name,
## the villagers would go still and nothing would say why.

const ANIMATION_LIBRARIES: Array[String] = [
	"res://assets/quaternius/animations/UAL1.glb",
	"res://assets/quaternius/animations/UAL2.glb",
]

## The clips the conversation system actually asks for by name.
## Godot's glTF importer strips a `_Loop` suffix and sets the loop flag instead, so the
## names here are the imported ones rather than the ones in the pack.
const REQUIRED_CLIPS: Array[String] = [
	"Idle",
	"Idle_Talking",
	"Yes",
	"Idle_No",
]


func _every_animation() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for path: String in ANIMATION_LIBRARIES:
		var library: AnimationLibrary = load(path)
		assert_not_null(library, "%s should import as an AnimationLibrary" % path)
		if library == null:
			continue
		for name: StringName in library.get_animation_list():
			names.append(String(name))
	return names


func test_the_animation_libraries_import_as_libraries() -> void:
	# If these come back as PackedScenes the .import files have lost their importer
	# setting, and every villager falls back to standing still.
	for path: String in ANIMATION_LIBRARIES:
		var resource: Resource = load(path)
		assert_not_null(resource, "%s should load" % path)
		assert_true(resource is AnimationLibrary, "%s should be an AnimationLibrary" % path)


func test_the_clips_the_villagers_rely_on_all_exist() -> void:
	var names: PackedStringArray = _every_animation()
	assert_gt(names.size(), 200, "both libraries should be present")
	for clip: String in REQUIRED_CLIPS:
		assert_true(names.has(clip), "the animation library is missing '%s'" % clip)


func test_every_villager_has_a_body() -> void:
	var directory: DirAccess = DirAccess.open("res://resources/personas")
	assert_not_null(directory)
	var checked: int = 0
	for file_name: String in directory.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var persona: NPCPersona = load("res://resources/personas/%s" % file_name)
		assert_not_null(persona.outfit, "%s has no outfit assigned" % file_name)
		checked += 1
	assert_gt(checked, 0)


func test_every_outfit_shares_the_animation_rig() -> void:
	# 65 joints, matched by name. This is the assertion the upgrade rests on.
	var reference: PackedStringArray = _joint_names_of_scene(
		load("res://scenes/villagers/smith.tscn")
	)
	assert_gt(reference.size(), 50, "the reference villager should be rigged")

	var directory: DirAccess = DirAccess.open("res://resources/personas")
	for file_name: String in directory.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var persona: NPCPersona = load("res://resources/personas/%s" % file_name)
		if persona.outfit == null:
			continue
		var joints: PackedStringArray = _joint_names_of_scene(persona.outfit)
		for bone: String in reference:
			assert_true(
				joints.has(bone),
				"%s is missing the bone '%s' the animations drive" % [persona.id, bone],
			)


## Sorted bone names of the first Skeleton3D in `scene`.
func _joint_names_of_scene(scene: PackedScene) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	if scene == null:
		return names
	var root: Node = scene.instantiate()
	var skeletons: Array[Node] = root.find_children("*", "Skeleton3D", true, false)
	if not skeletons.is_empty():
		var skeleton: Skeleton3D = skeletons[0]
		for i: int in skeleton.get_bone_count():
			names.append(skeleton.get_bone_name(i))
	root.free()
	names.sort()
	return names
