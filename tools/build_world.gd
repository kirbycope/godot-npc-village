extends SceneTree
## Assembles `scenes/npc.tscn` and `scenes/world.tscn` from the Kenney and Quaternius
## kits and saves them as ordinary scenes.
##
## Run headless from the project root:
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/build_world.gd
##
## The generated scenes are committed and are what the game actually loads; nothing is
## built at run time. A village laid out by hand in the editor would be perfectly
## valid, but assembling six hundred modular pieces by hand is a poor use of an
## afternoon, and a script makes the layout reproducible and easy to re-balance.

const KIT: String = "res://assets/kenney/fantasy_town/models/%s.glb"
const NATURE: String = "res://assets/kenney/nature/models/%s.glb"
const MANNEQUIN_M: String = "res://addons/3d_player_controller/assets/quaternius/characters/Mannequin_M.glb"
const MANNEQUIN_F: String = "res://addons/3d_player_controller/assets/quaternius/characters/Mannequin_F.glb"
const IDLE_LIBRARY: String = "res://addons/3d_player_controller/assets/mixamo/animations/root_motion/Idle.glb"
const PLAYER_SCENE: String = "res://addons/3d_player_controller/scenes/player.tscn"

const NPC_SCENE_PATH: String = "res://scenes/npc.tscn"
const WORLD_SCENE_PATH: String = "res://scenes/world.tscn"

## The Kenney fantasy town kit is modelled on a one unit grid with walls one unit high.
## A villager is 1.83 units tall, which would make them nearly as tall as a storey, so
## the whole kit is scaled up. At 3.0 a wall is a three metre storey and the grid is a
## three metre bay, which is about right for a cottage.
const KIT_SCALE: float = 3.0

## World metres per grid cell.
const CELL: float = KIT_SCALE

## Rotations that put a wall panel on a given side of its cell. A wall model sits on
## the +x edge of its own cell, and +90 degrees about Y turns +x into -z.
const FACE_EAST: float = 0.0
const FACE_NORTH: float = 90.0
const FACE_WEST: float = 180.0
const FACE_SOUTH: float = 270.0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init() -> void:
	# The autoload singletons are added to the tree after `_init` returns, and the
	# conversation scripts refer to them by name, so nothing that loads those scripts
	# can run until a frame has passed.
	_run()


func _run() -> void:
	await process_frame
	_rng.seed = 20260913
	var npc_scene: PackedScene = _build_npc_scene()
	if npc_scene == null:
		quit(1)
		return
	if not _build_world(npc_scene):
		quit(1)
		return
	quit(0)


# --------------------------------------------------------------------------------
# The villager scene
# --------------------------------------------------------------------------------

## Builds the reusable villager: a body, a rig with an idle clip, a speaking modifier
## on the skeleton, a positional voice, and the two labels.
func _build_npc_scene() -> PackedScene:
	var npc: CharacterBody3D = CharacterBody3D.new()
	npc.name = "NPC"
	npc.set_script(load("res://scripts/npc/npc.gd"))
	npc.collision_layer = 1
	npc.collision_mask = 1

	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.name = "Collision"
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = 0.3
	shape.shape = capsule
	shape.position = Vector3(0.0, 0.9, 0.0)
	npc.add_child(shape)
	shape.owner = npc

	var model_scene: PackedScene = load(MANNEQUIN_M)
	if model_scene == null:
		printerr("Could not load the villager model at %s" % MANNEQUIN_M)
		return null
	var model: Node3D = model_scene.instantiate()
	model.name = "Model"
	npc.add_child(model)
	# Left as a scene instance rather than owned node by node, so the villager scene
	# stores a reference to the model and picks up any change to it.
	model.owner = npc

	var skeletons: Array[Node] = model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		printerr("The villager model has no Skeleton3D.")
		return null
	var skeleton: Skeleton3D = skeletons[0]

	# The skeleton lives inside an instanced scene, and `pack()` discards nodes added
	# under an instance unless that instance is marked editable. Without this the
	# modifier is silently dropped from the saved scene and the villagers stand rigid
	# while they talk, with no error to say why.
	npc.set_editable_instance(model, true)

	var modifier: SkeletonModifier3D = SkeletonModifier3D.new()
	modifier.set_script(load("res://scripts/npc/speaking_modifier.gd"))
	modifier.name = "SpeakingModifier"
	skeleton.add_child(modifier)
	modifier.owner = npc

	# The clip's tracks are addressed relative to the model root, so the player has to
	# sit under it for "GeneralSkeleton:Hips" to resolve.
	var animation_player: AnimationPlayer = AnimationPlayer.new()
	animation_player.name = "AnimationPlayer"
	model.add_child(animation_player)
	animation_player.owner = npc
	var idle: AnimationLibrary = load(IDLE_LIBRARY) as AnimationLibrary
	if idle == null:
		printerr("Could not load the idle animation library.")
		return null
	animation_player.add_animation_library(&"idle", idle)
	animation_player.autoplay = "idle/mixamo_com"

	var voice: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	voice.name = "VoicePlayer"
	voice.position = Vector3(0.0, 1.6, 0.0)
	# Villagers should be audible across the square but fall away outside it, so the
	# player can walk between conversations without hearing all of them at once.
	voice.unit_size = 6.0
	voice.max_distance = 22.0
	voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	npc.add_child(voice)
	voice.owner = npc

	var plate: Label3D = _make_label("NamePlate", 0.0034, Vector3(0.0, 2.22, 0.0))
	plate.modulate = Color(0.87, 0.85, 0.78)
	plate.outline_size = 10
	npc.add_child(plate)
	plate.owner = npc


	npc.set("animation_player", animation_player)
	npc.set("speaking_modifier", modifier)
	npc.set("voice_player", voice)
	npc.set("name_plate", plate)

	var packed: PackedScene = PackedScene.new()
	if packed.pack(npc) != OK:
		printerr("Could not pack the villager scene.")
		return null
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes"))
	if ResourceSaver.save(packed, NPC_SCENE_PATH) != OK:
		printerr("Could not save %s" % NPC_SCENE_PATH)
		return null
	print("wrote ", NPC_SCENE_PATH)
	return load(NPC_SCENE_PATH)


## `pixel_size` is metres per font pixel, so at font size 64 a label stands
## `64 * pixel_size` metres tall. Anything under about a quarter of a metre is
## unreadable from across the square.
func _make_label(label_name: String, pixel_size: float, offset: Vector3) -> Label3D:
	var label: Label3D = Label3D.new()
	label.name = label_name
	label.position = offset
	label.pixel_size = pixel_size
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.double_sided = true
	label.no_depth_test = false
	label.shaded = false
	label.outline_modulate = Color(0.05, 0.04, 0.03, 0.85)
	label.font_size = 64
	return label


# --------------------------------------------------------------------------------
# The village
# --------------------------------------------------------------------------------

func _build_world(npc_scene: PackedScene) -> bool:
	var world: Node3D = Node3D.new()
	world.name = "World"

	_add_environment(world)
	_add_ground(world)
	_add_roads(world)
	_add_square(world)
	_add_buildings(world)
	_add_outskirts(world)

	var groups: Node3D = Node3D.new()
	groups.name = "Conversations"
	world.add_child(groups)
	groups.owner = world

	# Three conversations, spread so the player can only hear one at a time.
	_add_group(world, groups, npc_scene, &"fountain", "the market fountain",
		"the miller's daughter, missing six days",
		Vector3(0.0, 0.0, 5.2),
		[
			{"persona": "smith", "model": MANNEQUIN_M, "offset": Vector3(-1.1, 0.0, 0.2)},
			{"persona": "baker", "model": MANNEQUIN_F, "offset": Vector3(1.1, 0.0, -0.2)},
		],
		[
			"smith: Irons cost what they cost, Maud.",
			"baker: And you'll have it, and a loaf besides.",
			"smith: I've heard that before.",
		])

	_add_group(world, groups, npc_scene, &"tavern", "the door of the Crooked Hart",
		"the tax collector, expected before the harvest",
		Vector3(-3.0, 0.0, -12.2),
		[
			{"persona": "innkeeper", "model": MANNEQUIN_M, "offset": Vector3(-1.0, 0.0, 0.3)},
			{"persona": "guard", "model": MANNEQUIN_M, "offset": Vector3(1.0, 0.0, -0.3)},
		],
		[
			"innkeeper: You'll want the ledger straight before he comes.",
			"guard: I want a good deal of things, Corwin.",
			"innkeeper: Then have a drink while you want them.",
		])

	_add_group(world, groups, npc_scene, &"chapel", "the chapel steps",
		"what was left at the chapel door, and the disturbed graves",
		Vector3(9.0, 0.0, 12.4),
		[
			{"persona": "elder", "model": MANNEQUIN_M, "offset": Vector3(-1.0, 0.0, 0.0)},
			{"persona": "healer", "model": MANNEQUIN_F, "offset": Vector3(1.0, 0.0, 0.0)},
		],
		[
			"elder: You needn't have come down the hill for this.",
			"healer: I came for the air, Father.",
			"elder: You came because you cannot leave it alone. Nor can I.",
		])

	var hud: CanvasLayer = CanvasLayer.new()
	hud.name = "SubtitleHUD"
	hud.set_script(load("res://scripts/ui/subtitle_hud.gd"))
	world.add_child(hud)
	hud.owner = world

	_add_player(world)

	var packed: PackedScene = PackedScene.new()
	if packed.pack(world) != OK:
		printerr("Could not pack the world scene.")
		return false
	if ResourceSaver.save(packed, WORLD_SCENE_PATH) != OK:
		printerr("Could not save %s" % WORLD_SCENE_PATH)
		return false
	print("wrote ", WORLD_SCENE_PATH)
	return true


func _add_environment(world: Node3D) -> void:
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.name = "Sun"
	# Low and from the side, so the roofs cast across the square and the village reads
	# as morning rather than noon.
	sun.rotation_degrees = Vector3(-38.0, 132.0, 0.0)
	sun.light_energy = 1.55
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	world.add_child(sun)
	sun.owner = world

	var environment: Environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	var material: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	material.sky_top_color = Color(0.27, 0.45, 0.70)
	material.sky_horizon_color = Color(0.68, 0.74, 0.78)
	material.ground_bottom_color = Color(0.22, 0.24, 0.20)
	material.ground_horizon_color = Color(0.66, 0.67, 0.62)
	material.sun_angle_max = 12.0
	sky.sky_material = material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 0.55
	environment.ambient_light_energy = 0.9
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.ssao_enabled = true
	environment.ssao_intensity = 1.6
	# Just enough haze to separate the treeline from the sky. Any denser and it drains
	# the contrast out of the village itself, which is what the whole scene is for.
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_light_color = Color(0.70, 0.76, 0.80)
	environment.fog_density = 0.0
	environment.fog_depth_begin = 55.0
	environment.fog_depth_end = 140.0
	environment.fog_depth_curve = 1.6
	var world_environment: WorldEnvironment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	world.add_child(world_environment)
	world_environment.owner = world


func _add_ground(world: Node3D) -> void:
	var ground: StaticBody3D = StaticBody3D.new()
	ground.name = "Ground"
	world.add_child(ground)
	ground.owner = world

	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.name = "Mesh"
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(160.0, 160.0)
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.30, 0.37, 0.20)
	material.roughness = 0.95
	plane.material = material
	mesh.mesh = plane
	ground.add_child(mesh)
	mesh.owner = world

	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "Collision"
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(160.0, 1.0, 160.0)
	collision.shape = box
	collision.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(collision)
	collision.owner = world


## The mill road running east to west below the square, and the chapel lane off it.
func _add_roads(world: Node3D) -> void:
	var roads: Node3D = _group(world, "Roads")
	for x: int in range(-9, 10):
		_place(roads, world, KIT % "road", Vector3(x * CELL, 0.02, 3.0 * CELL), 0.0)
	for z: int in range(4, 6):
		_place(roads, world, KIT % "road", Vector3(3.0 * CELL, 0.02, z * CELL), 90.0)


## The market square: the fountain at its centre, stalls facing in, lanterns.
func _add_square(world: Node3D) -> void:
	var square: Node3D = _group(world, "Square")
	_place(square, world, KIT % "fountain-round", Vector3.ZERO, 0.0)

	# Stalls line the east and west of the square and face the fountain, which leaves
	# the middle clear for the villagers to stand in.
	var stalls: Array[Dictionary] = [
		{"cell": Vector2i(-2, -1), "rot": FACE_EAST, "model": "stall-red"},
		{"cell": Vector2i(-2, 0), "rot": FACE_EAST, "model": "stall-green"},
		{"cell": Vector2i(-2, 1), "rot": FACE_EAST, "model": "stall"},
		{"cell": Vector2i(2, -1), "rot": FACE_WEST, "model": "stall"},
		{"cell": Vector2i(2, 0), "rot": FACE_WEST, "model": "stall-red"},
		{"cell": Vector2i(2, 1), "rot": FACE_WEST, "model": "stall-green"},
	]
	for entry: Dictionary in stalls:
		_place(square, world, KIT % entry["model"], _cell_to_world(entry["cell"], 0.0), entry["rot"])

	_place(square, world, KIT % "cart", Vector3(-1.3 * CELL, 0.0, 2.1 * CELL), 28.0)
	_place(square, world, KIT % "stall-bench", Vector3(1.2 * CELL, 0.0, 2.2 * CELL), FACE_WEST)
	# The lantern is a tall model: at the kit scale it stands 4.7 m, which towers over a
	# 1.83 m villager. Two thirds of that reads as a street lamp rather than a mast.
	for spot: Vector3 in [
		Vector3(-2.7 * CELL, 0.0, -1.7 * CELL),
		Vector3(2.7 * CELL, 0.0, -1.7 * CELL),
		Vector3(-2.7 * CELL, 0.0, 2.6 * CELL),
		Vector3(2.7 * CELL, 0.0, 2.6 * CELL),
	]:
		_place(square, world, KIT % "lantern", spot, 0.0, 0.62)


func _add_buildings(world: Node3D) -> void:
	var buildings: Node3D = _group(world, "Buildings")

	# The smithy closes the west side of the square, its door onto the square.
	_building(buildings, world, Vector2i(-6, -3), Vector2i(3, 2), 1, false,
		Vector2i(-4, -2), FACE_EAST)
	_place(buildings, world, KIT % "chimney", Vector3(-6.0 * CELL, CELL, -3.0 * CELL), 0.0)
	_place(buildings, world, KIT % "chimney-top", Vector3(-6.0 * CELL, 1.55 * CELL, -3.0 * CELL), 0.0)

	# The bakery closes the east side.
	_building(buildings, world, Vector2i(3, -3), Vector2i(3, 2), 1, false,
		Vector2i(3, -2), FACE_WEST)
	_place(buildings, world, KIT % "chimney", Vector3(5.0 * CELL, CELL, -3.0 * CELL), 0.0)
	_place(buildings, world, KIT % "chimney-top", Vector3(5.0 * CELL, 1.55 * CELL, -3.0 * CELL), 0.0)

	# The Crooked Hart stands over the north end, two storeys, banners out.
	_building(buildings, world, Vector2i(-2, -6), Vector2i(4, 2), 2, true,
		Vector2i(-1, -5), FACE_SOUTH)
	_place(buildings, world, KIT % "banner-red", Vector3(-0.5 * CELL, 1.25 * CELL, -13.45), FACE_SOUTH)
	_place(buildings, world, KIT % "banner-green", Vector3(1.5 * CELL, 1.25 * CELL, -13.45), FACE_SOUTH)

	# A cottage on the south west corner.
	_building(buildings, world, Vector2i(-6, 1), Vector2i(2, 2), 1, true,
		Vector2i(-5, 1), FACE_EAST)

	# The chapel sits below the mill road, at the end of its own lane.
	_building(buildings, world, Vector2i(2, 5), Vector2i(3, 2), 1, false,
		Vector2i(3, 5), FACE_NORTH)
	_place(buildings, world, KIT % "pillar-stone", Vector3(1.4 * CELL, 0.0, 5.0 * CELL), 0.0)
	_place(buildings, world, KIT % "pillar-stone", Vector3(1.4 * CELL, 0.0, 6.0 * CELL), 0.0)

	# The watermill at the eastern edge, where the road leaves the village.
	_place(buildings, world, KIT % "watermill", Vector3(9.5 * CELL, 0.9 * CELL, 3.0 * CELL), 180.0)
	_place(buildings, world, KIT % "windmill", Vector3(-9.5 * CELL, 1.56 * CELL, -5.0 * CELL), 140.0)


## Lays a rectangular building of `size` cells with its north west corner at `origin`.
## `storeys` walls high, wooden or stone, with a doorway at `door_cell` and a two slope
## roof. Depth is expected to be two cells, which is what the roof assumption needs.
func _building(
	parent: Node3D,
	world: Node3D,
	origin: Vector2i,
	size: Vector2i,
	storeys: int,
	wood: bool,
	door_cell: Vector2i,
	door_facing: float,
) -> void:
	var wall: String = "wall-wood" if wood else "wall"
	var door: String = "wall-wood-doorway-square" if wood else "wall-doorway-square"
	var window: String = "wall-wood-window-shutters" if wood else "wall-window-shutters"

	var x0: int = origin.x
	var x1: int = origin.x + size.x - 1
	var z0: int = origin.y
	var z1: int = origin.y + size.y - 1

	for storey: int in storeys:
		var y: float = float(storey) * CELL
		for z: int in range(z0, z1 + 1):
			_wall(parent, world, wall, door, window, Vector2i(x1, z), y, FACE_EAST,
				door_cell, door_facing, storey)
			_wall(parent, world, wall, door, window, Vector2i(x0, z), y, FACE_WEST,
				door_cell, door_facing, storey)
		for x: int in range(x0, x1 + 1):
			_wall(parent, world, wall, door, window, Vector2i(x, z0), y, FACE_NORTH,
				door_cell, door_facing, storey)
			_wall(parent, world, wall, door, window, Vector2i(x, z1), y, FACE_SOUTH,
				door_cell, door_facing, storey)

	var roof_y: float = float(storeys) * CELL
	for x: int in range(x0, x1 + 1):
		_place(parent, world, KIT % "roof", _cell_to_world(Vector2i(x, z0), roof_y), FACE_NORTH)
		_place(parent, world, KIT % "roof", _cell_to_world(Vector2i(x, z1), roof_y), FACE_SOUTH)


## One wall panel, swapped for a door on the ground floor of `door_cell` and a window
## on roughly a third of the rest, so the elevations are not blank.
func _wall(
	parent: Node3D,
	world: Node3D,
	wall: String,
	door: String,
	window: String,
	cell: Vector2i,
	y: float,
	facing: float,
	door_cell: Vector2i,
	door_facing: float,
	storey: int,
) -> void:
	var model: String = wall
	if storey == 0 and cell == door_cell and is_equal_approx(facing, door_facing):
		model = door
	elif _rng.randf() < 0.34:
		model = window
	_place(parent, world, KIT % model, _cell_to_world(cell, y), facing)


## Trees, hedges and rocks around the edge, thinning towards the square so the village
## does not look dropped into a clearing.
func _add_outskirts(world: Node3D) -> void:
	var outskirts: Node3D = _group(world, "Outskirts")
	var trees: PackedStringArray = PackedStringArray([
		"tree", "tree-crooked", "tree-high", "tree-high-round", "tree-high-crooked",
	])
	for i: int in 90:
		var angle: float = _rng.randf() * TAU
		var radius: float = _rng.randf_range(26.0, 62.0)
		var spot: Vector3 = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		if absf(spot.z) < 5.0 and spot.x > -32.0 and spot.x < 32.0:
			continue  # keep the mill road clear
		_place(
			outskirts, world, KIT % trees[_rng.randi() % trees.size()], spot,
			_rng.randf() * 360.0, _rng.randf_range(0.85, 1.35),
		)
	for i: int in 9:
		var angle: float = _rng.randf() * TAU
		var radius: float = _rng.randf_range(34.0, 56.0)
		_place(
			outskirts, world, KIT % "rock-small",
			Vector3(cos(angle) * radius, 0.0, sin(angle) * radius),
			_rng.randf() * 360.0, _rng.randf_range(0.35, 0.6),
		)
	for z: int in range(1, 6):
		_place(outskirts, world, KIT % "hedge", _cell_to_world(Vector2i(7, z), 0.0), FACE_WEST)


## Builds one conversation: the villagers, the trigger area, and the group node that
## drives them. Signals are connected on the nodes here, so the saved scene carries the
## wiring rather than a `_ready` rebuilding it every run.
func _add_group(
	world: Node3D,
	parent: Node3D,
	npc_scene: PackedScene,
	id: StringName,
	location: String,
	topic: String,
	origin: Vector3,
	members: Array,
	fallback: Array,
) -> void:
	var group: Node3D = Node3D.new()
	group.name = String(id).capitalize().replace(" ", "")
	group.set_script(load("res://scripts/conversation/conversation_group.gd"))
	group.position = origin
	parent.add_child(group)
	group.owner = world

	var npcs: Array[Node] = []
	for member: Dictionary in members:
		var npc: Node3D = npc_scene.instantiate()
		npc.name = str(member["persona"]).capitalize()
		npc.position = member["offset"]
		npc.set("persona", load("res://resources/personas/%s.tres" % member["persona"]))
		npc.add_to_group("villagers", true)
		group.add_child(npc)
		npc.owner = world
		npcs.append(npc)

	# The villagers start facing each other, which reads as a conversation already in
	# progress the moment the scene loads.
	if npcs.size() == 2:
		var a: Node3D = npcs[0]
		var b: Node3D = npcs[1]
		a.rotation.y = atan2(b.position.x - a.position.x, b.position.z - a.position.z)
		b.rotation.y = atan2(a.position.x - b.position.x, a.position.z - b.position.z)

	var area: Area3D = Area3D.new()
	area.name = "PlayerArea"
	area.monitoring = true
	group.add_child(area)
	area.owner = world
	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.name = "Shape"
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = 6.5
	shape.shape = sphere
	area.add_child(shape)
	shape.owner = world

	# Built through the Array constructor rather than declared as `Array[NPC]`, because
	# naming the type here would pull `npc.gd` into this script's own compilation, which
	# happens before the autoloads it refers to exist.
	var typed: Array = Array([], TYPE_OBJECT, &"CharacterBody3D", load("res://scripts/npc/npc.gd"))
	for npc: Node in npcs:
		typed.push_back(npc)
	group.set("group_id", id)
	group.set("location_name", location)
	group.set("topic", topic)
	group.set("npcs", typed)
	group.set("player_area", area)
	var lines: PackedStringArray = PackedStringArray()
	for line: String in fallback:
		lines.append(line)
	group.set("fallback_lines", lines)

	# CONNECT_PERSIST is what makes a connection part of the saved scene. Without it the
	# connection exists only on the live object the builder made, `pack()` drops it, and
	# the shipped scene has an Area3D wired to nothing at all.
	area.body_entered.connect(
		Callable(group, "_on_player_area_body_entered"), Object.CONNECT_PERSIST
	)
	area.body_exited.connect(
		Callable(group, "_on_player_area_body_exited"), Object.CONNECT_PERSIST
	)


func _add_player(world: Node3D) -> void:
	var scene: PackedScene = load(PLAYER_SCENE)
	if scene == null:
		push_warning("The player controller scene is missing; the village has no player.")
		return
	var player: Node3D = scene.instantiate()
	player.name = "Player"
	player.position = Vector3(-4.0, 0.2, 11.0)
	player.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	if not player.is_in_group("player"):
		player.add_to_group("player", true)
	world.add_child(player)
	player.owner = world


# --------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------

func _group(world: Node3D, group_name: String) -> Node3D:
	var node: Node3D = Node3D.new()
	node.name = group_name
	world.add_child(node)
	node.owner = world
	return node


func _cell_to_world(cell: Vector2i, y: float) -> Vector3:
	return Vector3(float(cell.x) * CELL, y, float(cell.y) * CELL)


## Instances `path` under `parent`, scaled to the kit scale. Kit pieces are visual only
## and carry no collision, so a static body with a box is wrapped around anything the
## player should not walk through, which is everything except the roads and roofs.
func _place(
	parent: Node3D,
	world: Node3D,
	path: String,
	position: Vector3,
	rotation_y: float,
	extra_scale: float = 1.0,
) -> Node3D:
	var scene: PackedScene = load(path)
	if scene == null:
		push_warning("Missing model: %s" % path)
		return null
	var node: Node3D = scene.instantiate()
	node.position = position
	node.rotation_degrees = Vector3(0.0, rotation_y, 0.0)
	node.scale = Vector3.ONE * KIT_SCALE * extra_scale
	parent.add_child(node)
	node.owner = world
	return node
