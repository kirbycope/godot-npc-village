extends SceneTree
## Generates the villager personas into `resources/personas/`.
##
## Run headless from the project root:
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/build_personas.gd
##
## The generated `.tres` files are the authored content and are committed; this script
## exists so the whole cast can be re-emitted consistently after a schema change,
## rather than six resources being hand-edited out of step with each other.
##
## Every voice here is an ElevenLabs "premade" voice. That is a deliberate constraint:
## the "professional" voices in the account's library return HTTP 402 on a free plan,
## so a cast built from them would be mute for anyone without a paid subscription.

const OUTPUT_DIR: String = "res://resources/personas"

## id, outfit, name, occupation, voice, pitch, stability, style, traits, biography,
## knowledge, relationships.
##
## The outfits are cast to read at a distance. A player crossing the square should be
## able to tell the priest from the serjeant before either has said a word.
const CAST: Array[Dictionary] = [
	{
		"id": &"smith",
		# a working man's tunic, the plainest thing in the village
		"outfit": "Male_Peasant",
		"prefix": "Male_Peasant",
		"hidden": [],
		"feminine": false,
		"hair": ["Hair_Buzzed", "Hair_Beard"],
		"name": "Aldric",
		"occupation": "blacksmith",
		"voice": "pNInz6obpgDQGcFmaJgB",
		"pitch": 0.94,
		"stability": 0.55,
		"style": 0.25,
		"traits": ["gruff", "literal", "proud of his work", "short with fools"],
		"bio": "Aldric has kept the Ashmoor forge for nineteen years and inherited it from his father, who was better at it. He speaks in short sentences, dislikes being interrupted, and measures people by whether they pay on time. He is not unkind, but he is tired.",
		"knows": [
			"The tax collector's man came ahead of the rest and asked who owned the forge.",
			"He shod a horse three nights ago for a rider who would not give a name and paid in old coin.",
			"Maud the baker has owed him for a set of oven irons since the spring.",
		],
		"relations": {
			&"baker": "Owes him money and keeps changing the subject. He has started to find it funny rather than annoying, which annoys him.",
			&"guard": "Respects him. They drink together without talking much.",
			&"elder": "Thinks the old man means well and says too much.",
		},
	},
	{
		"id": &"baker",
		# the same peasant cloth, which is the point: she is one of them
		"outfit": "Female_Peasant",
		"prefix": "Female_Peasant",
		"hidden": [],
		"feminine": true,
		"hair": ["Hair_Bob"],
		"name": "Maud",
		"occupation": "baker",
		"voice": "Xb7hH8MSUJpSbSDYk0k2",
		"pitch": 1.0,
		"stability": 0.4,
		"style": 0.4,
		"traits": ["nosy", "quick", "deflects with jokes", "genuinely kind"],
		"bio": "Maud runs the bakery on the square and hears everything, because everyone comes to her eventually. She talks quickly, changes subject when cornered, and is the first to know any piece of news in Ashmoor. She is fonder of these people than she lets on.",
		"knows": [
			"The miller's youngest, Elowen, bought bread for two the morning before she vanished.",
			"She has not paid Aldric for the oven irons because the harvest money went on flour.",
			"Wenna the herbwife was out past the treeline the night Elowen disappeared.",
		],
		"relations": {
			&"smith": "Owes him and knows it. Likes him, which makes the debt worse.",
			&"healer": "Uneasy about her lately, and has not decided whether that is fair.",
			&"innkeeper": "Her oldest friend. They trade gossip as currency.",
		},
	},
	{
		"id": &"innkeeper",
		# better dressed than anyone else here, and enjoying it
		"outfit": "Male_Noble",
		"prefix": "Male_Noble",
		"hidden": ["Head_Crown", "Acc_Pauldron_Lion", "Acc_Gorget"],
		"feminine": false,
		"hair": ["Hair_SlickBack", "Hair_Moustache"],
		"name": "Corwin",
		"occupation": "keeper of the Crooked Hart",
		"voice": "JBFqnCBsd6RMkjVDRZzb",
		"pitch": 0.97,
		"stability": 0.42,
		"style": 0.45,
		"traits": ["warm", "talkative", "watches everyone", "never quite answers"],
		"bio": "Corwin keeps the Crooked Hart and has the innkeeper's habit of agreeing with whoever is in front of him. He tells a story well and at length. Behind the warmth he is counting, always, and he knows exactly who was in his taproom on any given night.",
		"knows": [
			"The nameless rider took a room for one night and left before dawn without sleeping in the bed.",
			"The tax collector is expected within the week and will want the inn's ledger.",
			"He served Elowen and someone else the night before she went missing, in the back room.",
		],
		"relations": {
			&"baker": "His oldest friend and his best source.",
			&"guard": "Keeps him sweet. A serjeant who likes you is worth a barrel a year.",
			&"smith": "Finds him heavy going but honest, which he values more.",
		},
	},
	{
		"id": &"guard",
		# a serjeant's gambeson rather than full plate
		"outfit": "Male_Knight_Cloth",
		"prefix": "Male_Knight",
		"hidden": ["Head_Horns", "Acc_Pauldron_Spike"],
		"feminine": false,
		"hair": ["Hair_Buzzed"],
		"name": "Serjeant Hale",
		"occupation": "village serjeant",
		"voice": "onwK4e9ZLuTAKqWW03F9",
		"pitch": 0.96,
		"stability": 0.6,
		"style": 0.2,
		"traits": ["steady", "procedural", "uncomfortable with rumour", "loyal"],
		"bio": "Hale is the only man in Ashmoor with any authority and is careful with it. He prefers facts to talk, says so often, and is quietly frightened that the missing girl is his responsibility and that he has already failed at it.",
		"knows": [
			"He has searched the mill race and the woods as far as the old boundary stone and found nothing.",
			"He is under orders to have the village's accounts ready and does not have them.",
			"He saw the nameless rider leave and did not stop him, and has told no one that.",
		],
		"relations": {
			&"smith": "A friend, in the way of men who stand near each other in silence.",
			&"elder": "Defers to him publicly and disagrees with him privately.",
			&"innkeeper": "Knows Corwin is managing him and lets it happen.",
		},
	},
	{
		"id": &"elder",
		# robes, which read as a priest's at this distance
		"outfit": "Male_Wizard",
		"prefix": "Male_Wizard",
		"hidden": [],
		"feminine": false,
		"hair": ["Hair_Balding", "Hair_Beard"],
		"name": "Father Brannoc",
		"occupation": "village priest",
		"voice": "pqHfZKP75CvOlQylNhV4",
		"pitch": 0.92,
		"stability": 0.5,
		"style": 0.35,
		"traits": ["unhurried", "fond of parable", "stubborn", "sharper than he appears"],
		"bio": "Brannoc has buried three generations of Ashmoor and christened most of the living. He speaks slowly and in circles, partly from age and partly because it makes people fill the silence. He has heard every confession in this village.",
		"knows": [
			"Someone left an offering at the chapel the night Elowen vanished, and he has not said so.",
			"The graveyard's oldest corner has been disturbed and he has told no one but Wenna.",
			"He believes the tax collector's visit and the girl's disappearance are not connected, and is losing confidence in that.",
		],
		"relations": {
			&"healer": "An old and complicated friendship. They disagree about almost everything and trust each other completely.",
			&"guard": "Thinks Hale is a good man given an impossible job.",
			&"baker": "Enjoys her and does not believe half of what she says.",
		},
	},
	{
		"id": &"healer",
		# hooded and practical, for someone who lives at the treeline
		"outfit": "Female_Ranger",
		"prefix": "Female_Ranger",
		"hidden": [],
		"feminine": true,
		"hair": ["Hair_Long"],
		"name": "Wenna",
		"occupation": "herbwife",
		"voice": "pFZP5JQG7iQjIQuC4Bku",
		"pitch": 1.03,
		"stability": 0.38,
		"style": 0.5,
		"traits": ["measured", "private", "unsentimental", "kind in practice"],
		"bio": "Wenna lives at the treeline and is called on when someone is dying or being born. The village is grateful to her and wary of her in equal measure, and she has long stopped minding. She chooses her words carefully and says less than she knows.",
		"knows": [
			"She was gathering past the treeline the night Elowen vanished and saw a second set of tracks.",
			"Elowen came to her a fortnight ago asking for something, and she refused.",
			"She told Brannoc about the disturbed graves and asked him to keep it quiet.",
		],
		"relations": {
			&"elder": "The only person here she speaks plainly to.",
			&"baker": "Aware Maud has gone cool on her and has not asked why.",
			&"guard": "Would tell him what she saw if he asked her directly. He has not.",
		},
	},
]


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var written: int = 0
	for entry: Dictionary in CAST:
		var persona: NPCPersona = NPCPersona.new()
		persona.id = entry["id"]
		persona.display_name = entry["name"]
		persona.occupation = entry["occupation"]
		persona.biography = entry["bio"]
		persona.voice_id = entry["voice"]
		persona.voice_pitch = entry["pitch"]
		persona.voice_stability = entry["stability"]
		persona.voice_style = entry["style"]
		persona.voice_similarity = 0.8
		var outfit_path: String = "res://assets/quaternius/characters/%s.gltf" % entry["outfit"]
		var outfit: PackedScene = load(outfit_path)
		if outfit == null:
			printerr("Missing outfit for %s: %s" % [entry["id"], outfit_path])
		persona.outfit = outfit
		persona.outfit_prefix = entry["prefix"]
		var hidden: PackedStringArray = PackedStringArray()
		for part: String in entry["hidden"]:
			hidden.append(part)
		persona.hidden_parts = hidden
		persona.feminine = entry["feminine"]
		var hair: PackedStringArray = PackedStringArray()
		for style: String in entry["hair"]:
			hair.append(style)
		persona.hair = hair

		var traits: PackedStringArray = PackedStringArray()
		for item: String in entry["traits"]:
			traits.append(item)
		persona.traits = traits

		var knowledge: PackedStringArray = PackedStringArray()
		for item: String in entry["knows"]:
			knowledge.append(item)
		persona.knowledge = knowledge

		var relations: Dictionary[StringName, String] = {}
		for other: StringName in entry["relations"]:
			relations[other] = entry["relations"][other]
		persona.relationships = relations

		# Anything written by hand on the existing resource is read back and kept. The
		# opening line is authored on the `.tres`, so regenerating the cast must not
		# throw it away.
		var path: String = "%s/%s.tres" % [OUTPUT_DIR, entry["id"]]
		if ResourceLoader.exists(path):
			var existing: NPCPersona = load(path)
			if existing != null:
				persona.opening_line = existing.opening_line
		var error: Error = ResourceSaver.save(persona, path)
		if error != OK:
			printerr("Could not write %s: %s" % [path, error_string(error)])
			continue
		written += 1
		print("wrote %s  (%s the %s)" % [path, entry["name"], entry["occupation"]])
	print("%d personas written." % written)
	quit(0 if written == CAST.size() else 1)
