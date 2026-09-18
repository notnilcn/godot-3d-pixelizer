class_name PixelizerDiagnosticsOverlay
extends CanvasLayer

## Optional on-screen debug readout: pipeline state (from the manager's
## `get_debug_status_line()`) plus FPS and draw calls. Toggle with `toggle()` or
## `toggle_key` (TAB by default).
##
## Live tuning is done through Godot's remote inspector while the game runs;
## this node is HUD-only.

@export var manager: PixelizerManager3D
@export var update_interval := 0.25
## Key that toggles the overlay while its host scene runs. 0 disables the
## built-in handler (games can call `toggle()` from their own input).
@export var toggle_key: Key = KEY_TAB

var _label: Label
var _timer := 0.0


func _ready() -> void:
	layer = 100
	if manager == null:
		manager = PixelizerManager3D.resolve_manager(self)
	_label = Label.new()
	_label.position = Vector2(12.0, 8.0)
	_label.add_theme_color_override("font_color", Color(0.9, 1.0, 0.85, 0.95))
	_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_label.add_theme_constant_override("outline_size", 4)
	_label.add_theme_font_size_override("font_size", 14)
	add_child(_label)


func _process(delta: float) -> void:
	if not visible:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = update_interval
	_label.text = get_status_text()


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and toggle_key != KEY_NONE and key.keycode == toggle_key:
			toggle()
			get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	pass


func get_status_text() -> String:
	var lines: PackedStringArray = []
	if manager != null and is_instance_valid(manager):
		lines.append(manager.get_debug_status_line())
	else:
		lines.append("Pixelizer3D [no manager]")
	lines.append("fps=%d  draw_calls=%d" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	return "\n".join(lines)


func toggle() -> void:
	visible = not visible
	if visible:
		_timer = 0.0
