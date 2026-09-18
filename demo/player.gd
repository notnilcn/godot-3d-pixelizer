extends CharacterBody3D
## demo2 player: WASD moves the character (camera-relative), arcball camera.
## Arrow keys orbit the camera (yaw/pitch). Mouse drag also orbits, wheel zooms.
##
## Movement follows the twin-stick pattern from the reference game: read a
## Vector2 from named InputMap actions (Input.get_vector, the GDScript twin of
## C# Input.GetVector), rotate it by the camera yaw, and drive velocity with
## move_and_slide. The character visual faces the input direction.
##
## Actions are registered at runtime (idempotent, like demo.gd's keybinds) so
## project.godot needs no [input] entries.
##
## The Camera3D child follows the body automatically (it is a child node), so
## this script only maintains the orbit offset + look-at target. The body itself
## is never rotated -- only the Knight visual turns to face movement -- so the
## child camera offset stays stable.

## Movement actions (WASD) and camera actions (arrows), created in _ready.
const ACT_FORWARD := "player_forward"
const ACT_BACK := "player_back"
const ACT_LEFT := "player_left"
const ACT_RIGHT := "player_right"
const ACT_JUMP := "player_jump"
const ACT_CAM_LEFT := "camera_orbit_left"
const ACT_CAM_RIGHT := "camera_orbit_right"
const ACT_CAM_UP := "camera_orbit_up"
const ACT_CAM_DOWN := "camera_orbit_down"

const ACTION_KEYS := {
	ACT_FORWARD: KEY_W,
	ACT_BACK: KEY_S,
	ACT_LEFT: KEY_A,
	ACT_RIGHT: KEY_D,
	ACT_JUMP: KEY_SPACE,
	ACT_CAM_LEFT: KEY_LEFT,
	ACT_CAM_RIGHT: KEY_RIGHT,
	ACT_CAM_UP: KEY_UP,
	ACT_CAM_DOWN: KEY_DOWN,
}

@export_group("Movement")
@export var move_speed := 5.0
@export var acceleration := 12.0
@export var jump_velocity := 4.5
@export var gravity_scale := 1.0
@export var turn_speed := 10.0

@export_group("Arcball Camera")
@export var camera_path: NodePath = ^"Camera3D"
@export var visual_path: NodePath = ^"Knight"
@export var pivot_height := 1.5
@export var orbit_distance := 6.0
@export var min_distance := 2.0
@export var max_distance := 14.0
@export var yaw_deg := 0.0
@export var pitch_deg := 20.0
@export var pitch_min_deg := -30.0
@export var pitch_max_deg := 80.0
@export var keyboard_orbit_speed := 120.0
@export var mouse_orbit_sensitivity := 0.4
@export var zoom_step := 0.5

var _yaw := 0.0
var _pitch := 0.0
var _distance := 6.0
var _dragging := false

@onready var _camera: Camera3D = get_node_or_null(camera_path) as Camera3D
@onready var _visual: Node3D = get_node_or_null(visual_path) as Node3D


func _ready() -> void:
	_ensure_input_actions()
	_yaw = deg_to_rad(yaw_deg)
	_pitch = deg_to_rad(clampf(pitch_deg, pitch_min_deg, pitch_max_deg))
	_distance = clampf(orbit_distance, min_distance, max_distance)
	if _camera != null:
		_camera.current = true
	_update_camera()


## Runtime keybind actions (same idempotent pattern as demo.gd's
## _ensure_keybind_actions): create once, bind the physical key once.
func _ensure_input_actions() -> void:
	for action in ACTION_KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var keycode: int = ACTION_KEYS[action]
		var has_event := false
		for event in InputMap.action_get_events(action):
			if event is InputEventKey and (event as InputEventKey).physical_keycode == keycode:
				has_event = true
				break
		if not has_event:
			var key := InputEventKey.new()
			key.physical_keycode = keycode
			InputMap.action_add_event(action, key)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_distance = clampf(_distance - zoom_step, min_distance, max_distance)
			_update_camera()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_distance = clampf(_distance + zoom_step, min_distance, max_distance)
			_update_camera()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_orbit_pixels(mm.relative)


func _physics_process(delta: float) -> void:
	# Arrow-key arcball (actions, so held keys orbit smoothly).
	var orbit := Input.get_vector(ACT_CAM_LEFT, ACT_CAM_RIGHT, ACT_CAM_UP, ACT_CAM_DOWN)
	if orbit.length_squared() > 0.0:
		_yaw -= orbit.x * deg_to_rad(keyboard_orbit_speed) * delta
		_pitch = clampf(_pitch - orbit.y * deg_to_rad(keyboard_orbit_speed) * delta, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))

	# Twin-stick style movement: 2D input vector rotated by the camera yaw.
	# raw.x = strafe (right +), raw.y = back (+) / forward (-), so
	# Vector2(raw.x, -raw.y) is (right, forward); rotating it by _yaw and
	# mapping (x, y) -> (x, 0, -y) gives the camera-relative world direction:
	# yaw 0 faces -Z, yaw +90 deg faces -X, matching the arcball forward.
	var raw := Input.get_vector(ACT_LEFT, ACT_RIGHT, ACT_FORWARD, ACT_BACK)
	var planar := Vector2(raw.x, -raw.y).rotated(_yaw)
	var wish_dir := Vector3(planar.x, 0.0, -planar.y)
	if wish_dir.length_squared() > 1.0:
		wish_dir = wish_dir.normalized()

	var gravity := ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) as float
	if not is_on_floor():
		velocity.y -= gravity * gravity_scale * delta
	elif Input.is_action_pressed(ACT_JUMP):
		velocity.y = jump_velocity

	var target_planar := wish_dir * move_speed
	velocity.x = lerpf(velocity.x, target_planar.x, clampf(acceleration * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, target_planar.z, clampf(acceleration * delta, 0.0, 1.0))
	move_and_slide()

	# Face the input direction with the visual only (reference: Rotation = yaw
	# while moving; rotating the body would swing the child camera with it).
	if _visual != null and wish_dir.length_squared() > 0.001:
		var face_yaw := atan2(-wish_dir.x, -wish_dir.z)
		_visual.rotation.y = lerp_angle(_visual.rotation.y, face_yaw + PI, clampf(turn_speed * delta, 0.0, 1.0))

	_update_camera()


func _orbit_pixels(relative: Vector2) -> void:
	_yaw -= relative.x * deg_to_rad(mouse_orbit_sensitivity)
	_pitch = clampf(_pitch + relative.y * deg_to_rad(mouse_orbit_sensitivity), deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
	_update_camera()


func _update_camera() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var offset := Vector3(0.0, 0.0, _distance)
	offset = offset.rotated(Vector3.RIGHT, -_pitch)
	offset = offset.rotated(Vector3.UP, _yaw)
	# Body has no rotation/scale, so local offset == global offset direction.
	_camera.position = offset + Vector3(0.0, pivot_height, 0.0)
	_camera.look_at(global_position + Vector3(0.0, pivot_height, 0.0))
