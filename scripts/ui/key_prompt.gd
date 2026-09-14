class_name KeyPrompt
extends CanvasLayer
## Asks the player for their own API keys, on the web build where there are none.
##
## A desktop build reads keys from `.env` or the environment. A page served from GitHub
## Pages has neither, and shipping keys inside the build would mean publishing them: the
## `.pck` is a download, so anything in it is public, and every visitor would be spending
## somebody else's quota. So the web build ships with no keys and the village runs on its
## committed voice bank, which is what the authored opening lines are for.
##
## A player who wants more than the opening can paste in their own keys. They are held in
## memory and, if asked, in `user://secrets.cfg`, which on the web is the browser's own
## storage for this origin: it never leaves the machine and nothing is sent anywhere but
## the two APIs themselves.
##
## Both APIs allow this. ElevenLabs answers browser requests from any origin, and the
## Claude API allows them when the request carries
## `anthropic-dangerous-direct-browser-access`. Anthropic calls that dangerous for good
## reason, and it is worth being plain about what it means here: a key typed into a web
## page can be read by anything running on that page. It is the player's own key, spent
## on their own conversation, and a key scoped to this and rotated afterwards is a very
## different thing from a production credential.

## The player supplied at least one key.
signal keys_entered()

## Shown once per session unless the player has already stored keys.
@export var show_on_start: bool = true

var _panel: PanelContainer
var _anthropic: LineEdit
var _elevenlabs: LineEdit
var _remember: CheckBox
var _status: Label


func _ready() -> void:
	layer = 40
	_build()
	visible = false
	if show_on_start and OS.has_feature("web"):
		# Deferred so Secrets has finished looking for keys before we decide to ask.
		_show_if_needed.call_deferred()


## Opens the prompt. Bound to nothing by default; call it from a menu or a key.
func open() -> void:
	_anthropic.text = ""
	_elevenlabs.text = ""
	_status.text = ""
	visible = true
	_anthropic.grab_focus()


func _show_if_needed() -> void:
	if Secrets.has_key("anthropic") or Secrets.has_key("elevenlabs"):
		return
	open()


func _build() -> void:
	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.03, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var centre: CenterContainer = CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	_panel = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.11, 0.98)
	style.border_color = Color(0.35, 0.32, 0.26)
	style.set_border_width_all(1)
	style.set_content_margin_all(26.0)
	style.set_corner_radius_all(5)
	_panel.add_theme_stylebox_override("panel", style)
	centre.add_child(_panel)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.custom_minimum_size = Vector2(560.0, 0.0)
	_panel.add_child(column)

	column.add_child(_heading("Ashmoor"))
	column.add_child(_body(
		"The villagers will say their opening lines without anything from you. Beyond "
		+ "that they are written by Claude while you play and spoken by ElevenLabs, and "
		+ "this page ships with no keys of its own, because anything inside a web build "
		+ "is public."
	))
	column.add_child(_body(
		"Paste your own to hear the rest. They stay in this browser and go nowhere but "
		+ "those two APIs. A key you can rotate afterwards is the sensible thing to use."
	))

	column.add_child(_label("Anthropic API key, for the dialogue"))
	_anthropic = _field("sk-ant-...")
	column.add_child(_anthropic)

	column.add_child(_label("ElevenLabs API key, for the voices and push to talk"))
	_elevenlabs = _field("sk_...")
	column.add_child(_elevenlabs)

	_remember = CheckBox.new()
	_remember.text = "Remember them in this browser"
	_remember.button_pressed = true
	column.add_child(_remember)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	_status.add_theme_color_override("font_color", Color(0.85, 0.6, 0.45))
	column.add_child(_status)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)

	var skip: Button = Button.new()
	skip.text = "Play without them"
	skip.pressed.connect(func() -> void: visible = false)
	buttons.add_child(skip)

	var accept: Button = Button.new()
	accept.text = "Use these keys"
	accept.pressed.connect(_on_accept)
	buttons.add_child(accept)


func _heading(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", Color(0.93, 0.88, 0.74))
	return label


func _body(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(560.0, 0.0)
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.78, 0.77, 0.74))
	return label


func _label(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.72, 0.70, 0.66))
	return label


## Secret, so it is masked as it is typed. There is nothing to be done about a key being
## readable once it is in the page, but it need not also be readable over a shoulder.
func _field(placeholder: String) -> LineEdit:
	var field: LineEdit = LineEdit.new()
	field.placeholder_text = placeholder
	field.secret = true
	field.custom_minimum_size = Vector2(560.0, 0.0)
	return field


func _on_accept() -> void:
	var anthropic: String = _anthropic.text.strip_edges()
	var elevenlabs: String = _elevenlabs.text.strip_edges()
	if anthropic.is_empty() and elevenlabs.is_empty():
		_status.text = "Enter at least one, or play without them."
		return

	Secrets.set_key("anthropic", anthropic, _remember.button_pressed)
	Secrets.set_key("elevenlabs", elevenlabs, _remember.button_pressed)
	# The services decided whether they were usable when they started, before any of this
	# existed, so they are told to look again rather than the player having to reload.
	ConversationDirector.rearm()
	VoiceService.rearm()
	SpeechService.rearm()
	visible = false
	keys_entered.emit()
