class_name PixelizerFireflies3D
extends Node3D

## Deterministic firefly swarm.
##
## Spawns `firefly_count` glowing points that wander a bounded volume around this
## node. Each firefly gets its own RNG stream derived from the spawner `seed` and
## its index, so the initial homes and every motion phase are identical across
## reloads for the same seed (`sample_positions(at_time)` is a pure function —
## use it to check determinism without waiting for frames).
##
## The swarm is rendered as **two** `MultiMeshInstance3D` draw calls: emissive
## sphere bodies (`Flies`) and camera-facing additive glow quads (`Glows`). There
## is no per-firefly node or material. Put the spawner under a
## PixelizerApplier3D to pixelize the bodies; the glow material is registered via
## `register_pixelized_material()` so the applier never replaces its additive
## shader.
##
## All exports are runtime editable: `firefly_count` / `seed` respawn the swarm,
## the rest apply live.

@export_range(0, 256) var firefly_count := 24: set = _set_firefly_count
## Horizontal wander radius of the spawn volume.
@export var radius := 4.0: set = _set_radius
## Vertical extent (fireflies stay between ~0 and `height`).
@export var height := 2.5: set = _set_height
## Motion speed multiplier (wander frequency).
@export var speed := 1.0: set = _set_speed
## Blinks per second.
@export var blink_rate := 1.5: set = _set_blink_rate
## Fraction of each blink cycle the firefly glows.
@export_range(0.02, 1.0) var blink_duty := 0.4: set = _set_blink_duty
## Firefly body colour (unshaded emissive).
@export var color := Color(1.0, 0.85, 0.4): set = _set_color
@export var seed := 20260914: set = _set_seed

@export_group("Body")
## Firefly body radius in world units.
@export var firefly_size := 0.07: set = _set_firefly_size
@export var emission_energy := 2.5: set = _set_emission_energy
## Wander amplitude as a fraction of radius/height.
@export_range(0.0, 1.0) var wander := 0.35

@export_group("Glow")
@export var light_volume_enabled := true: set = _set_light_volume_enabled
@export var light_radius := 0.7: set = _set_light_radius
@export var light_intensity := 0.8: set = _set_light_intensity
@export var halo_size := 0.25: set = _set_halo_size
@export var halo_intensity := 1.2: set = _set_halo_intensity

const GLOW_SHADER := "res://addons/pixelizer_3d/shaders/firefly_glow.gdshader"

var _time := 0.0
var _flies: Array[Dictionary] = []
var _bodies: MultiMeshInstance3D
var _sphere: SphereMesh
var _body_material: StandardMaterial3D
var _glows: MultiMeshInstance3D
var _glow_quad: QuadMesh
var _glow_material: ShaderMaterial
var _body_buffer := PackedFloat32Array()
var _glow_buffer := PackedFloat32Array()


func _ready() -> void:
	_rebuild()


func _process(delta: float) -> void:
	_time += delta
	_apply_motion(_time)


func _rebuild() -> void:
	# Free the old nodes synchronously: queue_free() would leave stale children
	# visible to same-frame probes.
	if _bodies != null and is_instance_valid(_bodies):
		_bodies.free()
	_bodies = null
	if _glows != null and is_instance_valid(_glows):
		_glows.free()
	_glows = null
	_unregister_glow_material()
	_flies.clear()
	if not is_inside_tree():
		return

	_body_material = StandardMaterial3D.new()
	_body_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_body_material.albedo_color = color
	_body_material.emission_enabled = true
	_body_material.emission = color
	_body_material.emission_energy_multiplier = emission_energy
	_body_material.disable_receive_shadows = true

	_sphere = SphereMesh.new()
	_sphere.radius = firefly_size
	_sphere.height = firefly_size * 2.0
	_sphere.radial_segments = 8
	_sphere.rings = 4

	var body_multimesh := MultiMesh.new()
	body_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	body_multimesh.mesh = _sphere
	body_multimesh.instance_count = firefly_count
	_bodies = MultiMeshInstance3D.new()
	_bodies.name = "Flies"
	_bodies.multimesh = body_multimesh
	_bodies.material_override = _body_material
	_bodies.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bodies)

	# Glow quads: one extra draw call for the whole swarm (no per-fly nodes).
	_glow_quad = QuadMesh.new()
	_glow_quad.size = Vector2.ONE
	_glow_material = ShaderMaterial.new()
	_glow_material.shader = load(GLOW_SHADER) as Shader
	_push_glow_params()
	var glow_multimesh := MultiMesh.new()
	glow_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	glow_multimesh.mesh = _glow_quad
	glow_multimesh.instance_count = firefly_count
	_glows = MultiMeshInstance3D.new()
	_glows.name = "Glows"
	_glows.multimesh = glow_multimesh
	_glows.material_override = _glow_material
	_glows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glows.visible = light_volume_enabled
	add_child(_glows)
	var manager := PixelizerManager3D.resolve_manager(self)
	if manager != null:
		manager.register_pixelized_material(_glow_material)

	_body_buffer.resize(firefly_count * 12)
	_glow_buffer.resize(firefly_count * 12)

	for i in firefly_count:
		var rng := RandomNumberGenerator.new()
		rng.seed = _fly_seed(seed, i)

		var angle := rng.randf_range(0.0, TAU)
		var r := sqrt(rng.randf()) * radius
		var home := Vector3(cos(angle) * r, rng.randf_range(0.15, maxf(height, 0.15)), sin(angle) * r)

		_flies.append({
			"home": home,
			"phase": Vector3(
				rng.randf_range(0.0, TAU),
				rng.randf_range(0.0, TAU),
				rng.randf_range(0.0, TAU)),
			"freq": Vector3(
				rng.randf_range(0.45, 1.0),
				rng.randf_range(0.3, 0.8),
				rng.randf_range(0.45, 1.0)),
			"blink_phase": rng.randf(),
		})

	_apply_motion(_time)


func _unregister_glow_material() -> void:
	if _glow_material == null:
		return
	var manager := PixelizerManager3D.resolve_manager(self)
	if manager != null:
		manager.unregister_pixelized_material(_glow_material)
	_glow_material = null


func _exit_tree() -> void:
	_unregister_glow_material()


## Pure, frame-independent position function: the same seed + time gives the
## same positions on every load (the verification hook).
func sample_positions(at_time: float) -> PackedVector3Array:
	var positions := PackedVector3Array()
	for fly in _flies:
		positions.append(_fly_position(fly, at_time))
	return positions


func _apply_motion(at_time: float) -> void:
	var count := _flies.size()
	if count == 0:
		return
	_apply_body_motion(at_time)
	if _glows != null and is_instance_valid(_glows) and _glows.multimesh != null:
		_apply_glow_motion(at_time)


func _apply_body_motion(at_time: float) -> void:
	if _bodies == null or not is_instance_valid(_bodies) or _bodies.multimesh == null:
		return
	# One buffer write for every instance (12 floats: 3x4 transform, row-major).
	var buffer := _body_buffer
	if buffer.size() < _flies.size() * 12:
		buffer.resize(_flies.size() * 12)
	var offset := 0
	for fly in _flies:
		var pos := _fly_position(fly, at_time)
		var pulse := _blink_pulse(fly, at_time)
		var scale := 0.0 if pulse <= 0.02 else 1.0
		buffer[offset] = scale
		buffer[offset + 1] = 0.0
		buffer[offset + 2] = 0.0
		buffer[offset + 3] = pos.x
		buffer[offset + 4] = 0.0
		buffer[offset + 5] = scale
		buffer[offset + 6] = 0.0
		buffer[offset + 7] = pos.y
		buffer[offset + 8] = 0.0
		buffer[offset + 9] = 0.0
		buffer[offset + 10] = scale
		buffer[offset + 11] = pos.z
		offset += 12
	_bodies.multimesh.buffer = buffer


func _apply_glow_motion(at_time: float) -> void:
	var buffer := _glow_buffer
	if buffer.size() < _flies.size() * 12:
		buffer.resize(_flies.size() * 12)
	var offset := 0
	for fly in _flies:
		var pos := _fly_position(fly, at_time)
		var pulse := _blink_pulse(fly, at_time)
		var scale := 0.0 if pulse <= 0.02 else pulse
		buffer[offset] = scale
		buffer[offset + 1] = 0.0
		buffer[offset + 2] = 0.0
		buffer[offset + 3] = pos.x
		buffer[offset + 4] = 0.0
		buffer[offset + 5] = scale
		buffer[offset + 6] = 0.0
		buffer[offset + 7] = pos.y
		buffer[offset + 8] = 0.0
		buffer[offset + 9] = 0.0
		buffer[offset + 10] = scale
		buffer[offset + 11] = pos.z
		offset += 12
	_glows.multimesh.buffer = buffer


func _fly_position(fly: Dictionary, at_time: float) -> Vector3:
	var home: Vector3 = fly["home"]
	var phase: Vector3 = fly["phase"]
	var freq: Vector3 = fly["freq"] * speed
	var amp := Vector3(radius * wander, height * wander * 0.6, radius * wander)
	var pos := home + Vector3(
		sin(at_time * freq.x + phase.x) * amp.x,
		sin(at_time * freq.y + phase.y) * amp.y,
		sin(at_time * freq.z + phase.z) * amp.z)
	var flat := Vector2(pos.x, pos.z)
	if flat.length() > radius:
		flat = flat.normalized() * radius
		pos.x = flat.x
		pos.z = flat.y
	pos.y = clampf(pos.y, 0.05, maxf(height, 0.05))
	return pos


func _blink_pulse(fly: Dictionary, at_time: float) -> float:
	var cycle := maxf(blink_rate, 0.0001)
	var window := clampf(blink_duty, 0.02, 1.0)
	var phase := fposmod(at_time * cycle + fly["blink_phase"], 1.0)
	if phase >= window:
		return 0.0
	return sin(phase / window * PI)


## Deterministic per-firefly RNG stream (seed mix, no engine-global state).
static func _fly_seed(base: int, index: int) -> int:
	var h := base ^ (index * 2246822519 + 3266489917)
	h = (h ^ (h >> 15)) * 2654435761
	h = (h ^ (h >> 13)) * 2246822519
	return h ^ (h >> 16)


func _push_glow_params() -> void:
	if _glow_material == null:
		return
	_glow_material.set_shader_parameter("glow_color", color)
	_glow_material.set_shader_parameter(
		"glow_radius", maxf(halo_size, 0.001) * maxf(light_radius, 0.001))
	_glow_material.set_shader_parameter(
		"glow_intensity", maxf(halo_intensity, 0.0) * maxf(light_intensity, 0.0))


func _set_firefly_count(value: int) -> void:
	firefly_count = value
	_rebuild()


func _set_seed(value: int) -> void:
	seed = value
	_rebuild()


func _set_radius(value: float) -> void:
	radius = maxf(value, 0.05)
	_apply_motion(_time)


func _set_height(value: float) -> void:
	height = value
	_apply_motion(_time)


func _set_speed(value: float) -> void:
	speed = value


func _set_blink_rate(value: float) -> void:
	blink_rate = maxf(value, 0.0001)


func _set_blink_duty(value: float) -> void:
	blink_duty = clampf(value, 0.02, 1.0)


func _set_color(value: Color) -> void:
	color = value
	if _body_material != null:
		_body_material.albedo_color = value
		_body_material.emission = value
	_push_glow_params()


func _set_firefly_size(value: float) -> void:
	firefly_size = maxf(value, 0.001)
	if _sphere != null:
		_sphere.radius = firefly_size
		_sphere.height = firefly_size * 2.0
		_rebuild()


func _set_emission_energy(value: float) -> void:
	emission_energy = value
	if _body_material != null:
		_body_material.emission_energy_multiplier = value


func _set_light_volume_enabled(value: bool) -> void:
	light_volume_enabled = value
	if _glows != null and is_instance_valid(_glows):
		_glows.visible = value


func _set_light_radius(value: float) -> void:
	light_radius = maxf(value, 0.001)
	_push_glow_params()


func _set_light_intensity(value: float) -> void:
	light_intensity = maxf(value, 0.0)
	_push_glow_params()


func _set_halo_size(value: float) -> void:
	halo_size = maxf(value, 0.001)
	_push_glow_params()


func _set_halo_intensity(value: float) -> void:
	halo_intensity = maxf(value, 0.0)
	_push_glow_params()
