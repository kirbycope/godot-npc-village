extends Node
## Resolves API credentials without ever committing them to the repository.
##
## Autoloaded as `Secrets`. Three sources are consulted in order, first hit wins:
##
## 1. The process environment, so a CI run or a shell export takes precedence.
## 2. A `.env` file, searched from the project directory upwards. The shared
##    `C:\GitHub\.env` / `/Users/<user>/GitHub/.env` is found this way without the
##    project holding a copy of it.
## 3. `user://secrets.cfg`, which is where a player of an exported build would put
##    their own keys.
##
## Nothing here writes a key anywhere. A build exported with no key present simply
## runs with the voice and dialogue services disabled, which every caller handles.

## Emitted once the search has finished, whether or not anything was found.
signal loaded()

## How many parent directories above the project to search for a `.env`.
const ENV_SEARCH_DEPTH: int = 6

## Keys are looked up under every spelling listed here. The shared `.env` spells the
## TinyPNG key `TINY_PNY_API_KEY` and the ElevenLabs key `ELEVEN_LABS_API_KEY`, so a
## single canonical name would miss them.
const ALIASES: Dictionary = {
	"anthropic": ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"],
	"elevenlabs": ["ELEVEN_LABS_API_KEY", "ELEVENLABS_API_KEY", "XI_API_KEY"],
}

var _values: Dictionary[String, String] = {}
var _is_loaded: bool = false


func _ready() -> void:
	_load()


## The key for `service` ("anthropic" or "elevenlabs"), or "" when none was found.
func get_key(service: String) -> String:
	if not _is_loaded:
		_load()
	return _values.get(service, "")


## Whether a usable key exists for `service`.
func has_key(service: String) -> bool:
	return not get_key(service).is_empty()


## Re-runs the search. Useful after the player edits `user://secrets.cfg` in game.
func reload() -> void:
	_values.clear()
	_is_loaded = false
	_load()


func _load() -> void:
	_is_loaded = true
	var from_env: Dictionary[String, String] = _read_env_file()
	for service: String in ALIASES:
		var names: Array = ALIASES[service]
		for alias: String in names:
			var value: String = OS.get_environment(alias)
			if value.is_empty():
				value = from_env.get(alias, "")
			if not value.is_empty():
				_values[service] = value
				break
	_read_user_config()
	for service: String in ALIASES:
		if _values.has(service):
			print("[Secrets] %s key loaded (%d chars)" % [service, _values[service].length()])
		else:
			push_warning("[Secrets] No %s key found. That service will stay disabled." % service)
	loaded.emit()


## Walks up from the project directory looking for a `.env`, returning every
## `NAME=value` pair it holds. Values may be quoted; `#` comments and blanks are skipped.
func _read_env_file() -> Dictionary[String, String]:
	var pairs: Dictionary[String, String] = {}
	var dir: String = ProjectSettings.globalize_path("res://").rstrip("/")
	for _i: int in ENV_SEARCH_DEPTH:
		var candidate: String = dir.path_join(".env")
		if FileAccess.file_exists(candidate):
			var file: FileAccess = FileAccess.open(candidate, FileAccess.READ)
			if file == null:
				break
			while not file.eof_reached():
				var line: String = file.get_line().strip_edges()
				if line.is_empty() or line.begins_with("#") or not line.contains("="):
					continue
				var split: int = line.find("=")
				var key: String = line.substr(0, split).strip_edges()
				var value: String = line.substr(split + 1).strip_edges()
				if value.length() >= 2 and (
					(value.begins_with("\"") and value.ends_with("\""))
					or (value.begins_with("'") and value.ends_with("'"))
				):
					value = value.substr(1, value.length() - 2)
				if not key.is_empty():
					pairs[key] = value
			file.close()
			break
		var parent: String = dir.get_base_dir()
		if parent == dir or parent.is_empty():
			break
		dir = parent
	return pairs


## `user://secrets.cfg` is only consulted for services the earlier sources missed, so a
## shell export always wins over a stale file a player left behind.
func _read_user_config() -> void:
	var config: ConfigFile = ConfigFile.new()
	if config.load("user://secrets.cfg") != OK:
		return
	for service: String in ALIASES:
		if _values.has(service):
			continue
		var value: String = str(config.get_value("api_keys", service, ""))
		if not value.is_empty():
			_values[service] = value
