extends SceneTree
## Assembles `scenes/villagers/*.tscn` and `scenes/world.tscn`, and saves them as
## ordinary scenes.
##
## Run headless from the project root:
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/build_world.gd
##
## The generated scenes are committed and are what the game actually loads; nothing is
## built at run time. A village laid out by hand in the editor would be perfectly valid,
## but a script makes the layout reproducible and easy to re-balance.
##
## Everything is Quaternius: the Medieval Village MegaKit for the buildings, the fantasy
## outfits and base characters for the villagers, and the Stylized Nature MegaKit for the
## trees and grass, which reach this project through the WeatherFX addon already dressed
## in its wind shaders.

## The Medieval Village MegaKit. Modelled at real-world scale, so nothing is rescaled: a
## wall is 2 m wide and 3.12 m tall, a door is 2.17 m, a floor tile is 2 m square.
const VILLAGE: String = "res://assets/quaternius/village/%s.gltf"

## Metres per wall module, which is the grid every building is laid out on.
const MODULE: float = 2.0

## Height of one storey, taken from the wall models.
const STOREY: float = 3.12

## The four wall materials the kit provides. Each has matching straight, door and window
## pieces, so a building picks one and stays in it.
## A PackedStringArray constructor is not a constant expression, so these are typed
## arrays instead.
const WALL_MATERIALS: Array[String] = ["Plaster", "UnevenBrick", "WoodBrick", "WoodWear"]

## Trees and grass come from WeatherFX rather than straight from the nature pack. The
## addon wraps the same Quaternius models in its `foliage_wind` and `grass_wind`
## shaders and drives them from the wind it is simulating, so foliage placed this way
## moves with the weather instead of standing frozen through a storm.
const TREE_SCENES: Array[String] = [
	"res://addons/weather_fx/scenes/tree_1.tscn",
	"res://addons/weather_fx/scenes/tree_2.tscn",
	"res://addons/weather_fx/scenes/tree_3.tscn",
	"res://addons/weather_fx/scenes/tree_4.tscn",
	"res://addons/weather_fx/scenes/tree_5.tscn",
]
const GRASS_SCENE: String = "res://addons/weather_fx/scenes/grass_field.tscn"
const WEATHER_SCENE: String = "res://addons/weather_fx/scenes/weather_fx.tscn"
const DATE_AND_TIME_SCRIPT: String = "res://addons/date_and_time/scripts/date_and_time.gd"

## The animation libraries. Both are modelled on the same rig as the fantasy outfits, so
## every villager can play every clip with no retargeting step: a check of the two
## skeletons found 65 of 65 joints shared.
const ANIMATION_LIBRARIES: Dictionary[StringName, String] = {
	&"ual1": "res://assets/quaternius/animations/UAL1.glb",
	&"ual2": "res://assets/quaternius/animations/UAL2.glb",
}

## Fallback body, used only when a persona has no outfit assigned.
const FALLBACK_MODEL: String = "res://assets/quaternius/characters/Male_Peasant.gltf"

## Heads, by persona `feminine` flag. The fantasy outfits are clothing only and stop at
## the neck, so a villager wearing one and nothing else is headless. The base character
## pack supplies the head, and the two are rigged to the same skeleton.
const HEADS: Dictionary[bool, String] = {
	false: "res://assets/quaternius/heads/Regular_Male_OnlyHead.gltf",
	true: "res://assets/quaternius/heads/Regular_Female_OnlyHead.gltf",
}

const HAIR_DIR: String = "res://assets/quaternius/hair"
const PLAYER_SCENE: String = "res://addons/3d_player_controller/scenes/player.tscn"

const VILLAGER_SCENE_DIR: String = "res://scenes/villagers"
const WORLD_SCENE_PATH: String = "res://scenes/world.tscn"

## The authored lines each group falls back to, shared with `tools/bake_voice_bank.gd`
## so the baker can synthesize exactly the lines the game will ask for.
const FALLBACK_LINES: String = "res://resources/fallback_lines.json"

## Which way a wall faces. A wall model spans 2 m along X with its outward face towards
## +Z, and turning it 90 degrees about Y turns that face towards +X.
const FACE_SOUTH: float = 0.0
const FACE_EAST: float = 90.0
const FACE_NORTH: float = 180.0
const FACE_WEST: float = 270.0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

## Circles that nothing may be scattered into, as Vector3(x, z, radius). Filled in as the
## village is built and handed to the grass and the trees afterwards, so foliage cannot
## grow through a wall or up through the paving. Each building contributes a circle big
## enough to cover its roof, which overhangs the walls by up to 2.7 m.
var _exclusions: Array[Vector3] = []


func _init() -> void:
	# The autoload singletons are added to the tree after `_init` returns, and the
	# conversation scripts refer to them by name, so nothing that loads those scripts
	# can run until a frame has passed.
	_run()


func _run() -> void:
	await process_frame
	_rng.seed = 20260913
	if not _build_world():
		quit(1)
		return
	quit(0)


# --------------------------------------------------------------------------------
# The village
# --------------------------------------------------------------------------------

func _build_world() -> bool:
	var world: Node3D = Node3D.new()
	world.name = "World"

	var sun: DirectionalLight3D = _add_environment(world)
	_add_ground(world)
	# The clock and the weather come before the foliage: the weather drives the sun and
	# publishes the wind, and the grass field wants a reference to it.
	var clock: Node = _add_date_and_time(world)
	_add_weather(world, clock, sun)
	# Buildings and paving register their keep-out circles, so they must be placed before
	# anything is scattered.
	_add_buildings(world)
	_add_square(world)
	_add_nature(world)

	var groups: Node3D = Node3D.new()
	groups.name = "Conversations"
	world.add_child(groups)
	groups.owner = world

	_add_group(world, groups, &"square", "the market square",
		"the miller's daughter, missing six days",
		Vector3(0.0, 0.0, 2.0),
		[
			{"persona": "smith", "offset": Vector3(-1.1, 0.0, 0.2)},
			{"persona": "baker", "offset": Vector3(1.1, 0.0, -0.2)},
		],
		_fallback_for(&"square"))

	_add_group(world, groups, &"tavern", "the door of the Crooked Hart",
		"the tax collector, expected before the harvest",
		Vector3(-13.0, 0.0, -11.0),
		[
			{"persona": "innkeeper", "offset": Vector3(-1.0, 0.0, 0.3)},
			{"persona": "guard", "offset": Vector3(1.0, 0.0, -0.3)},
		],
		_fallback_for(&"tavern"))

	_add_group(world, groups, &"chapel", "the chapel steps",
		"what was left at the chapel door, and the disturbed graves",
		Vector3(18.0, 0.0, 11.0),
		[
			{"persona": "elder", "offset": Vector3(-1.0, 0.0, 0.0)},
			{"persona": "healer", "offset": Vector3(1.0, 0.0, 0.0)},
		],
		_fallback_for(&"chapel"))

	var hud: CanvasLayer = CanvasLayer.new()
	hud.name = "SubtitleHUD"
	hud.set_script(load("res://scripts/ui/subtitle_hud.gd"))
	world.add_child(hud)
	hud.owner = world

	_add_player(world)
	_add_player_voice(world)

	var packed: PackedScene = PackedScene.new()
	if packed.pack(world) != OK:
		printerr("Could not pack the world scene.")
		return false
	if ResourceSaver.save(packed, WORLD_SCENE_PATH) != OK:
		printerr("Could not save %s" % WORLD_SCENE_PATH)
		world.free()
		return false
	# Freed rather than left for the engine to collect at exit, which otherwise reports
	# a couple of thousand resources still in use and looks like a leak in the project.
	world.free()
	_strip_instance_connections(WORLD_SCENE_PATH, "Player")
	print("wrote ", WORLD_SCENE_PATH)
	return true


## Removes connections that belong inside an instanced sub-scene.
##
## `PackedScene.pack()` serialises the outgoing signal connections of any node whose
## owner is the scene root, and an instanced scene's root qualifies. The player scene
## already connects its own signals to its own children when it loads, so those same
## connections written into the world scene are made a second time, and the game opens
## with seven "Signal is already connected" errors that look like they come from the
## addon. They do not: they come from this builder, and the editor does not produce them
## because it does not save an instance's internals this way.
##
## Both endpoints are inside the instance, so removing the line loses nothing: the
## instance still makes the connection itself.
func _strip_instance_connections(scene_path: String, instance_root: String) -> void:
	var file: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
	if file == null:
		return
	var text: String = file.get_as_text()
	file.close()

	var kept: PackedStringArray = PackedStringArray()
	var removed: int = 0
	for line: String in text.split("\n"):
		var is_internal: bool = (
			line.begins_with("[connection ")
			and line.contains("from=\"%s\"" % instance_root)
			and line.contains("to=\"%s/" % instance_root)
		)
		if is_internal:
			removed += 1
			continue
		kept.append(line)
	if removed == 0:
		return

	var out: FileAccess = FileAccess.open(scene_path, FileAccess.WRITE)
	if out == null:
		push_warning("Could not rewrite %s to drop duplicated connections." % scene_path)
		return
	out.store_string("\n".join(kept))
	out.close()
	print("  dropped %d connection(s) the %s instance already makes itself" % [
		removed, instance_root,
	])


## The sun and the sky. WeatherFX takes the light over at run time and swings it with
## the hour, so what is set here is only the starting position and colour.
func _add_environment(world: Node3D) -> DirectionalLight3D:
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-42.0, 128.0, 0.0)
	sun.light_energy = 1.3
	sun.light_color = Color(1.0, 0.96, 0.89)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 110.0
	sun.directional_shadow_blend_splits = true
	world.add_child(sun)
	sun.owner = world

	var environment: Environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	var material: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	material.sky_top_color = Color(0.28, 0.45, 0.70)
	material.sky_horizon_color = Color(0.71, 0.76, 0.79)
	material.ground_bottom_color = Color(0.24, 0.25, 0.21)
	material.ground_horizon_color = Color(0.66, 0.67, 0.62)
	sky.sky_material = material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 0.6
	environment.ambient_light_energy = 0.95
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.ssao_enabled = true
	environment.ssao_intensity = 1.5
	environment.sdfgi_enabled = false
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_light_color = Color(0.70, 0.76, 0.80)
	environment.fog_density = 0.0
	environment.fog_depth_begin = 60.0
	environment.fog_depth_end = 150.0
	var world_environment: WorldEnvironment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	world.add_child(world_environment)
	world_environment.owner = world
	return sun


## The in-game clock. Its hour drives the sun through WeatherFX and reaches the dialogue
## prompt through `ConversationGroup`, so the villagers know what time it is.
func _add_date_and_time(world: Node3D) -> Node:
	var clock: Node = Node.new()
	clock.name = "DateAndTime"
	clock.set_script(load("res://addons/date_and_time/scripts/date_and_time.gd"))
	clock.set("current_time", 9.5)
	clock.set("day", 14)
	clock.set("month", 9)
	clock.set("year", 1387)
	# A day every twenty minutes: long enough that the light is not visibly racing,
	# short enough that a player sees dusk without waiting for it.
	clock.set("minutes_per_day", 20.0)
	clock.set("is_running", true)
	clock.add_to_group("date_and_time", true)
	world.add_child(clock)
	clock.owner = world
	return clock


## Rain, snow, storms, wind and the day-night swing of the sun, from the WeatherFX addon.
## The wind it publishes as a global shader parameter is what moves the trees and grass.
func _add_weather(world: Node3D, clock: Node, sun: DirectionalLight3D) -> void:
	var scene: PackedScene = load(WEATHER_SCENE)
	if scene == null:
		push_warning("WeatherFX is not available; the sky will stay still.")
		return
	var weather: Node3D = scene.instantiate()
	weather.name = "WeatherFX"
	world.add_child(weather)
	weather.owner = world
	weather.set("date_and_time_node", clock)
	weather.set("sun_light", sun)
	weather.set("update_global_shader_variables", true)
	weather.add_to_group("weather_fx", true)


func _add_ground(world: Node3D) -> void:
	var ground: StaticBody3D = StaticBody3D.new()
	ground.name = "Ground"
	world.add_child(ground)
	ground.owner = world

	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.name = "Mesh"
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(200.0, 200.0)
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.27, 0.33, 0.19)
	material.roughness = 0.96
	plane.material = material
	mesh.mesh = plane
	ground.add_child(mesh)
	mesh.owner = world

	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "Collision"
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	collision.shape = box
	collision.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(collision)
	collision.owner = world


## Lays out the village. Each building is a footprint in metres with a wall material and
## a side its door opens onto, and the roof is chosen to fit rather than assembled from
## tiles: the kit ships whole roofs by footprint, which is both tidier and far fewer
## nodes than shingling one by hand.
func _add_buildings(world: Node3D) -> void:
	var buildings: Node3D = _group(world, "Buildings")

	# The roofs overhang by up to 2.7 m on a 6 m building, so the buildings are set well
	# apart. Packed tighter they were clipping through each other, and the square was too
	# small to stand a conversation in.

	# The smithy closes the west side of the square, its door onto it.
	_building(buildings, world, Vector2(-15.0, -4.0), Vector2i(6, 6), "WoodBrick", FACE_EAST)
	_place(buildings, world, VILLAGE % "Prop_Chimney", Vector3(-17.0, STOREY, -6.0), 0.0)

	# The bakery closes the east side, and has the other chimney.
	_building(buildings, world, Vector2(15.0, -4.0), Vector2i(6, 6), "Plaster", FACE_WEST)
	_place(buildings, world, VILLAGE % "Prop_Chimney2", Vector3(17.0, STOREY, -6.0), 0.0)

	# The Crooked Hart stands over the north end, the largest building here.
	_building(buildings, world, Vector2(-13.0, -17.0), Vector2i(8, 8), "WoodWear", FACE_SOUTH)

	# Cottages on the south side, set back from the square.
	_building(buildings, world, Vector2(-15.0, 11.0), Vector2i(4, 6), "Plaster", FACE_EAST)
	_building(buildings, world, Vector2(10.0, 14.0), Vector2i(6, 4), "WoodBrick", FACE_NORTH)

	# The chapel sits apart to the south east, in stone.
	_building(buildings, world, Vector2(18.0, 17.0), Vector2i(6, 8), "UnevenBrick", FACE_NORTH)

	# A barn out towards the mill road.
	_building(buildings, world, Vector2(17.0, -17.0), Vector2i(6, 6), "WoodWear", FACE_WEST)


## One building: four walls of `material` around `size` metres centred on `centre`, a
## door on `door_facing`, and a matching roof.
func _building(
	parent: Node3D,
	world: Node3D,
	centre: Vector2,
	size: Vector2i,
	material: String,
	door_facing: float,
) -> void:
	var half_x: float = float(size.x) * 0.5
	var half_z: float = float(size.y) * 0.5
	var across: int = int(size.x / MODULE)
	var deep: int = int(size.y / MODULE)

	# Each run of wall is placed module by module, and one module on the door side is
	# swapped for a doorway. Windows are sprinkled through the rest so no elevation is
	# a blank slab.
	var door_index: int = _rng.randi() % maxi(1, across if (
		is_equal_approx(door_facing, FACE_SOUTH) or is_equal_approx(door_facing, FACE_NORTH)
	) else deep)

	for i: int in across:
		var x: float = centre.x - half_x + MODULE * (float(i) + 0.5)
		_wall(parent, world, material, Vector3(x, 0.0, centre.y + half_z), FACE_SOUTH,
			is_equal_approx(door_facing, FACE_SOUTH) and i == door_index)
		_wall(parent, world, material, Vector3(x, 0.0, centre.y - half_z), FACE_NORTH,
			is_equal_approx(door_facing, FACE_NORTH) and i == door_index)
	for i: int in deep:
		var z: float = centre.y - half_z + MODULE * (float(i) + 0.5)
		_wall(parent, world, material, Vector3(centre.x + half_x, 0.0, z), FACE_EAST,
			is_equal_approx(door_facing, FACE_EAST) and i == door_index)
		_wall(parent, world, material, Vector3(centre.x - half_x, 0.0, z), FACE_WEST,
			is_equal_approx(door_facing, FACE_WEST) and i == door_index)

	# Corner trim hides the seam where two wall runs meet.
	for corner: Vector2 in [
		Vector2(centre.x - half_x, centre.y - half_z),
		Vector2(centre.x + half_x, centre.y - half_z),
		Vector2(centre.x - half_x, centre.y + half_z),
		Vector2(centre.x + half_x, centre.y + half_z),
	]:
		_place(parent, world, VILLAGE % "Corner_Exterior_Brick",
			Vector3(corner.x, 0.0, corner.y), 0.0)

	# A circle through the building's corners, plus the roof overhang.
	var reach: float = sqrt(half_x * half_x + half_z * half_z) + 2.8
	_exclusions.append(Vector3(centre.x, centre.y, reach))

	var roof: String = "Roof_FlatTiles_%dx%d" % [size.x, size.y]
	if ResourceLoader.exists(VILLAGE % roof):
		_place(parent, world, VILLAGE % roof, Vector3(centre.x, STOREY, centre.y), 0.0)
	else:
		push_warning("No roof in the kit for a %d by %d building." % [size.x, size.y])


## One wall module, and the collision that stops the player walking through it.
func _wall(
	parent: Node3D,
	world: Node3D,
	material: String,
	position: Vector3,
	facing: float,
	is_door: bool,
) -> void:
	var model: String = "Wall_%s_Straight" % material
	if is_door:
		model = "Wall_%s_Door_Flat" % material
	elif _rng.randf() < 0.38:
		var windows: Array[String] = [
			"Wall_%s_Window_Wide_Flat" % material,
			"Wall_%s_Window_Thin_Round" % material,
		]
		model = windows[_rng.randi() % windows.size()]
	if not ResourceLoader.exists(VILLAGE % model):
		model = "Wall_%s_Straight" % material
	_place(parent, world, VILLAGE % model, position, facing)

	# The kit's meshes carry no collision, so each wall gets a box. A doorway gets none,
	# which is what makes it a way in rather than a painting of one.
	if is_door:
		return
	var body: StaticBody3D = StaticBody3D.new()
	body.position = position
	body.rotation_degrees = Vector3(0.0, facing, 0.0)
	parent.add_child(body)
	body.owner = world
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(MODULE, STOREY, 0.4)
	shape.shape = box
	shape.position = Vector3(0.0, STOREY * 0.5, -0.1)
	body.add_child(shape)
	shape.owner = world


## The market square: paving, a wagon, crates and fencing. The kit has no fountain or
## well, so the square is made by what is standing in it rather than by a centrepiece.
func _add_square(world: Node3D) -> void:
	var square: Node3D = _group(world, "Square")
	# One paving type across the whole square. Mixing three at random made a patchwork
	# of mismatched greys and tans that read as a bug rather than as worn stone; the
	# variation that helps comes from rotating each tile, not from swapping the material.
	for ix: int in range(-5, 6):
		for iz: int in range(-4, 6):
			var spot: Vector3 = Vector3(float(ix) * MODULE, 0.01, float(iz) * MODULE)
			_place(square, world, VILLAGE % "Floor_RoundRocks", spot,
				90.0 * float(_rng.randi() % 4))

	# The paving is a rectangle and this is a circle, so it over-reaches a little at the
	# corners. Grass creeping onto the cobbles looks worse than a slightly bare verge.
	_exclusions.append(Vector3(0.0, 2.0, 13.5))

	_place(square, world, VILLAGE % "Prop_Wagon", Vector3(-7.5, 0.0, 7.5), 28.0)
	_place(square, world, VILLAGE % "Prop_Crate", Vector3(7.4, 0.0, 7.2), 12.0)
	_place(square, world, VILLAGE % "Prop_Crate", Vector3(8.1, 0.0, 8.1), -22.0)
	_place(square, world, VILLAGE % "Prop_Crate", Vector3(7.7, 0.78, 7.6), 40.0)


## Trees and grass, thinning towards the square. Both come from WeatherFX so the wind it
## simulates actually moves them.
func _add_nature(world: Node3D) -> void:
	var nature: Node3D = _group(world, "Nature")
	var placed: int = 0
	for i: int in 260:
		var angle: float = _rng.randf() * TAU
		var radius: float = _rng.randf_range(26.0, 78.0)
		var spot: Vector3 = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		# Keep the mill road east to west clear so the village has a way in.
		if absf(spot.z) < 6.0 and absf(spot.x) < 46.0:
			continue
		if _is_excluded(spot):
			continue
		var scene: String = TREE_SCENES[_rng.randi() % TREE_SCENES.size()]
		var tree: Node3D = _instance(nature, world, scene, spot)
		if tree == null:
			continue
		tree.rotation.y = _rng.randf() * TAU
		tree.scale = Vector3.ONE * _rng.randf_range(0.8, 1.45)
		placed += 1
	print("  %d trees" % placed)

	_add_grass(nature, world)


## Whether `spot` falls inside any of the keep-out circles.
func _is_excluded(spot: Vector3) -> bool:
	for zone: Vector3 in _exclusions:
		if Vector2(spot.x - zone.x, spot.z - zone.y).length() < zone.z:
			return true
	return false


## One grass field covering the whole village, told where it may not grow.
##
## The addon scatters its blades across `field_size` and skips anything inside a
## circular exclusion zone, which is what makes a single large field workable: dropped in
## blind it grows straight through walls and up through the paving, because the script
## has no idea the buildings are there. Every building and the square registered a circle
## as it was placed, so the field is handed the whole list and simply avoids them.
func _add_grass(parent: Node3D, world: Node3D) -> void:
	var scene: PackedScene = load(GRASS_SCENE)
	if scene == null:
		push_warning("The grass field scene is missing.")
		return
	var field: Node3D = scene.instantiate()
	field.name = "GrassField"
	field.position = Vector3.ZERO
	parent.add_child(field)
	field.owner = world
	field.set("field_size", Vector2(150.0, 150.0))
	field.set("instance_count", 14000)
	field.set("min_scale", 0.65)
	field.set("max_scale", 1.5)
	field.set("cast_grass_shadows", false)
	field.set("additional_exclusion_zones", _exclusions)
	var weather: Node = world.get_node_or_null("WeatherFX")
	if weather != null:
		field.set("weather_fx", weather)
	print("  grass field with %d keep-out circles" % _exclusions.size())


# --------------------------------------------------------------------------------
# Villagers
# --------------------------------------------------------------------------------

## Builds one villager: their outfit, a head, hair, the animation libraries, a voice and
## a name plate. Saved per persona because the body is part of who someone is.
func _build_npc_scene(persona: NPCPersona, scene_path: String) -> PackedScene:
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

	var model_scene: PackedScene = persona.outfit
	if model_scene == null:
		model_scene = load(FALLBACK_MODEL)
	if model_scene == null:
		printerr("No body available for %s" % persona.id)
		return null
	var model: Node3D = model_scene.instantiate()
	model.name = "Model"
	npc.add_child(model)
	model.owner = npc

	var skeletons: Array[Node] = model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		printerr("The outfit for %s has no Skeleton3D." % persona.id)
		return null
	var skeleton: Skeleton3D = skeletons[0]

	# `pack()` discards nodes added under an instance unless the instance is editable.
	# Without this the head, the hair and the modifier are all silently dropped from the
	# saved scene, with no error to say why.
	npc.set_editable_instance(model, true)

	# A villager is assembled from three sources: the outfit, a head, and hair. All are
	# rigged to the same skeleton, so the parts are moved onto the outfit's one and the
	# whole character animates as a single body.
	_graft(npc, skeleton, HEADS.get(persona.feminine, HEADS[false]))
	for hair: String in persona.hair:
		_graft(npc, skeleton, "%s/%s.gltf" % [HAIR_DIR, hair])

	var modifier: SkeletonModifier3D = SkeletonModifier3D.new()
	modifier.set_script(load("res://scripts/npc/speaking_modifier.gd"))
	modifier.name = "SpeakingModifier"
	skeleton.add_child(modifier)
	modifier.owner = npc

	# The clips are addressed relative to the model root, so the player sits under it.
	var animation_player: AnimationPlayer = AnimationPlayer.new()
	animation_player.name = "AnimationPlayer"
	model.add_child(animation_player)
	animation_player.owner = npc
	for key: StringName in ANIMATION_LIBRARIES:
		var library: AnimationLibrary = load(ANIMATION_LIBRARIES[key]) as AnimationLibrary
		if library == null:
			printerr("Could not load the animation library %s" % ANIMATION_LIBRARIES[key])
			continue
		animation_player.add_animation_library(key, library)
	animation_player.autoplay = "ual1/Idle"

	var voice: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	voice.name = "VoicePlayer"
	voice.position = Vector3(0.0, 1.6, 0.0)
	# Audible across the square but falling away outside it, so the player can walk
	# between conversations without hearing all of them at once.
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

	npc.set("persona", persona)
	npc.set("animation_player", animation_player)
	npc.set("speaking_modifier", modifier)
	npc.set("voice_player", voice)
	npc.set("name_plate", plate)

	var packed: PackedScene = PackedScene.new()
	if packed.pack(npc) != OK:
		printerr("Could not pack the villager scene for %s." % persona.id)
		return null
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(VILLAGER_SCENE_DIR))
	if ResourceSaver.save(packed, scene_path) != OK:
		printerr("Could not save %s" % scene_path)
		return null
	print("wrote ", scene_path)
	return load(scene_path)


## Moves every mesh of `path` onto `skeleton`, so a separately authored part animates
## with the body it is worn on.
##
## This works because the packs share one skeleton and Godot imports skins by bone name:
## a skin that names `head` binds to whichever skeleton it ends up under, rather than to
## the joint that happened to sit at that index in the file it came from.
func _graft(owner_node: Node, skeleton: Skeleton3D, path: String) -> void:
	var scene: PackedScene = load(path)
	if scene == null:
		push_warning("Missing character part: %s" % path)
		return
	var donor: Node3D = scene.instantiate()
	var meshes: Array[Node] = donor.find_children("*", "MeshInstance3D", true, false)
	for node: Node in meshes:
		var mesh: MeshInstance3D = node
		# The owner has to be cleared before the move, not after. A node carried into a
		# new tree still claiming its old scene root makes that ownership inconsistent,
		# and Godot warns once per mesh: with a head, eyes, eyebrows and two hairstyles
		# per villager that is a wall of warnings on every rebuild.
		mesh.owner = null
		mesh.get_parent().remove_child(mesh)
		skeleton.add_child(mesh)
		mesh.owner = owner_node
		mesh.skeleton = NodePath("..")
		mesh.transform = Transform3D.IDENTITY
	donor.queue_free()


## `pixel_size` is metres per font pixel, so at font size 64 a label stands
## `64 * pixel_size` metres tall.
func _make_label(label_name: String, pixel_size: float, offset: Vector3) -> Label3D:
	var label: Label3D = Label3D.new()
	label.name = label_name
	label.position = offset
	label.pixel_size = pixel_size
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.double_sided = true
	label.shaded = false
	label.outline_modulate = Color(0.05, 0.04, 0.03, 0.85)
	label.font_size = 64
	return label


## Builds one conversation: the villagers, the trigger area, and the group node driving
## them. Signals are connected with CONNECT_PERSIST so the wiring is saved into the
## scene rather than rebuilt by a `_ready` on every run.
func _add_group(
	world: Node3D,
	parent: Node3D,
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
		var persona_id: String = str(member["persona"])
		var persona: NPCPersona = load("res://resources/personas/%s.tres" % persona_id)
		if persona == null:
			printerr("No persona for %s" % persona_id)
			continue
		var villager_scene: PackedScene = _build_npc_scene(
			persona, "%s/%s.tscn" % [VILLAGER_SCENE_DIR, persona_id]
		)
		if villager_scene == null:
			continue
		var npc: Node3D = villager_scene.instantiate()
		npc.name = persona_id.capitalize()
		npc.position = member["offset"]
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
	player.position = Vector3(-1.0, 0.2, 20.0)
	player.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	if not player.is_in_group("player"):
		player.add_to_group("player", true)
	world.add_child(player)
	player.owner = world


## The authored fallback lines for one group, read from the shared data file so the
## voice baker synthesizes exactly what the game will ask for.
func _fallback_for(group_id: StringName) -> Array:
	var file: FileAccess = FileAccess.open(FALLBACK_LINES, FileAccess.READ)
	if file == null:
		push_warning("Missing %s; that group will have no fallback." % FALLBACK_LINES)
		return []
	var reader: JSON = JSON.new()
	var text: String = file.get_as_text()
	file.close()
	if reader.parse(text) != OK or typeof(reader.data) != TYPE_DICTIONARY:
		push_warning("%s is not readable JSON." % FALLBACK_LINES)
		return []
	var groups: Variant = reader.data.get("groups", {})
	if typeof(groups) != TYPE_DICTIONARY:
		return []
	var lines: Variant = groups.get(String(group_id), [])
	return lines if typeof(lines) == TYPE_ARRAY else []


## Push to talk. It lives on the world rather than under the player so it survives the
## player being replaced, and finds whoever is in the "player" group at run time.
func _add_player_voice(world: Node3D) -> void:
	var voice: Node3D = Node3D.new()
	voice.name = "PlayerVoice"
	voice.set_script(load("res://scripts/player/player_voice.gd"))
	voice.add_to_group("player_voice", true)
	world.add_child(voice)
	voice.owner = world


# --------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------

func _group(world: Node3D, group_name: String) -> Node3D:
	var node: Node3D = Node3D.new()
	node.name = group_name
	world.add_child(node)
	node.owner = world
	return node


## Instances `path` at `position`. The kit is modelled at real-world scale, so unlike the
## previous one nothing here is rescaled.
func _place(
	parent: Node3D,
	world: Node3D,
	path: String,
	position: Vector3,
	rotation_y: float,
) -> Node3D:
	var node: Node3D = _instance(parent, world, path, position)
	if node != null:
		node.rotation_degrees = Vector3(0.0, rotation_y, 0.0)
	return node


func _instance(parent: Node3D, world: Node3D, path: String, position: Vector3) -> Node3D:
	var scene: PackedScene = load(path)
	if scene == null:
		push_warning("Missing model: %s" % path)
		return null
	var node: Node3D = scene.instantiate()
	node.position = position
	parent.add_child(node)
	node.owner = world
	return node
