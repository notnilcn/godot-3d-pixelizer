class_name PixelizerCameraController3D
extends Node3D

## Input-agnostic orbit / yaw-step / zoom controller for Pixelizer3D. Zoom is
## applied through the manager-owned `view_zoom` (never by writing camera.size
## directly), so the renderer stays the single owner of the projection.
## Optional built-in input: Q/E yaw steps, mouse wheel zoom, middle-drag orbit.

@export var camera: Camera3D
@export var manager: PixelizerManager3D
@export var pivot: Node3D
@export var orbit_distance := 17.0
@export var yaw_step_degrees := 45.0
@export var zoom_step := 1.15
@export var min_ortho_width := 480.0
@export var max_ortho_width := 3840.0
@export var smoothing := 8.0
@export var input_enabled := true
@export var orbit_mouse_button := MOUSE_BUTTON_MIDDLE
@export var orbit_sensitivity := 0.15
@export_range(5.0, 89.0) var pitch_min_degrees := 10.0
@export_range(5.0, 89.0) var pitch_max_degrees := 80.0

@export_group("Pan")
## WASD pans the pivot on the ground plane; Space/Ctrl moves it vertically.
@export var pan_enabled := true
## Pivot speed in world units per second.
@export var pan_speed := 10.0
@export var vertical_speed := 6.0

var target_yaw := 0.0
var target_pitch := 42.0
var current_yaw := 0.0
var current_pitch := 42.0
var target_view_zoom := 1.0

var _orbiting := false


func _ready() -> void:
	if manager != null:
		target_view_zoom = manager.view_zoom
	current_yaw = target_yaw
	current_pitch = target_pitch
	_apply_transform()


func _process(delta: float) -> void:
	var blend := 1.0 - exp(-smoothing * delta)
	current_yaw = lerp_angle(current_yaw, target_yaw, blend)
	current_pitch = lerpf(current_pitch, target_pitch, blend)
	if manager != null:
		manager.set_view_zoom(lerpf(manager.view_zoom, target_view_zoom, blend))
	if pan_enabled and input_enabled:
		_update_pan(delta)
	_apply_transform()


## WASD / Space / Ctrl pivot pan (keyboard polling so held keys pan smoothly).
func _update_pan(delta: float) -> void:
	var yaw_radians := deg_to_rad(current_yaw)
	var forward := Vector3(-sin(yaw_radians), 0.0, -cos(yaw_radians))
	var right := forward.cross(Vector3.UP)
	var direction := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		direction += forward
	if Input.is_physical_key_pressed(KEY_S):
		direction -= forward
	if Input.is_physical_key_pressed(KEY_D):
		direction += right
	if Input.is_physical_key_pressed(KEY_A):
		direction -= right
	if direction.length_squared() > 0.0:
		_pivot_node().global_position += direction.normalized() * pan_speed * delta
	if Input.is_physical_key_pressed(KEY_SPACE):
		_vertical_pan(1.0, delta)
	if Input.is_physical_key_pressed(KEY_CTRL):
		_vertical_pan(-1.0, delta)


func _vertical_pan(direction: float, delta: float) -> void:
	_pivot_node().global_position += Vector3.UP * direction * vertical_speed * delta


func _pivot_node() -> Node3D:
	if pivot != null and is_instance_valid(pivot):
		return pivot
	return self


## Step the orbit yaw on the grid: snap to the nearest step first, otherwise
## step one grid increment from the snapped position.
func step_yaw(direction: int) -> void:
	var step_radians := deg_to_rad(yaw_step_degrees)
	var nearest := roundf(target_yaw / step_radians) * step_radians
	if absf(target_yaw - nearest) <= deg_to_rad(0.5):
		target_yaw = nearest + float(direction) * step_radians
	else:
		target_yaw = nearest


func add_zoom_steps(steps: float) -> void:
	if manager == null:
		return
	var current_width := manager.get_view_width()
	var target_width := clampf(current_width * pow(zoom_step, steps), min_ortho_width, max_ortho_width)
	target_view_zoom = target_width / maxf(manager.get_base_view_width(), 0.0001)


func orbit(delta_pixels: Vector2) -> void:
	target_yaw -= delta_pixels.x * orbit_sensitivity
	target_pitch = clampf(target_pitch + delta_pixels.y * orbit_sensitivity, pitch_min_degrees, pitch_max_degrees)


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q:
			step_yaw(-1)
		elif event.keycode == KEY_E:
			step_yaw(1)
	elif event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			add_zoom_steps(1.0)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			add_zoom_steps(-1.0)
		elif event.button_index == orbit_mouse_button:
			_orbiting = event.pressed
	elif event is InputEventMouseMotion and _orbiting:
		orbit(event.relative)


func _apply_transform() -> void:
	if camera == null or not is_instance_valid(camera):
		return
	var pivot_position := Vector3.ZERO
	if pivot != null and is_instance_valid(pivot):
		pivot_position = pivot.global_position
	var yaw_radians := deg_to_rad(current_yaw)
	var pitch_radians := deg_to_rad(current_pitch)
	var offset := Vector3(0.0, 0.0, orbit_distance)
	offset = offset.rotated(Vector3.RIGHT, -pitch_radians)
	offset = offset.rotated(Vector3.UP, yaw_radians)
	camera.global_position = pivot_position + offset
	camera.look_at(pivot_position, Vector3.UP)
