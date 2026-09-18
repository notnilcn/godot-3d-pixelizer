class_name PixelizerDayNight3D
extends Node3D

## Day/night rig: a DirectionalLight3D driven by a normalized time of day, plus
## the matching WorldEnvironment ramps (ambient, procedural sky, fog).
##
## The rig writes directly to the sun node, and PixelizerManager3D reads the sun
## every frame — cloud shadows, the cloud deck and the god-ray tint all follow
## without extra wiring. Registering the sun with the manager (`manager.sun`) is
## done automatically when the rig resolves its references.
##
## Time mapping: 0.0 = midnight, 0.25 = sunrise, 0.5 = noon, 0.75 = sunset,
## 1.0 = midnight again. The default elevation curve is a sine arc; override
## `elevation_curve` / `azimuth_curve` to author a different sun path. Every
## colour/energy is a Gradient/Curve sampled at `time_of_day`, so the whole rig
## is art-directable in the inspector.
##
## Testing: `set_time_of_day()` is runtime-callable, and `fast_forward` advances
## the clock at `fast_forward_speed` × real time even when `auto_advance` is off.

@export_group("Time")
## Normalized time of day (0 = midnight, 0.25 = sunrise, 0.5 = noon,
## 0.75 = sunset). Wraps at 1.
@export_range(0.0, 1.0, 0.0001) var time_of_day := 0.35:
	set(value):
		time_of_day = fposmod(value, 1.0)
		_apply()
## Advance the clock in `_process`. Off by default so tests/captures stay put.
@export var auto_advance := false
## Real seconds for a full day at 1× speed.
@export var day_length_seconds := 120.0
## Testing flag: advance the clock regardless of `auto_advance`.
@export var fast_forward := false
@export var fast_forward_speed := 60.0

@export_group("Wiring")
## Manager whose sun/cloud/ray path follows this rig. Found from the
## "pixelizer_manager" group when unset.
@export var manager: PixelizerManager3D
## Sun to drive; defaults to `manager.sun`, then a "Sun" node in the tree.
@export var sun: DirectionalLight3D
## Environment to drive; defaults to the first node in the "world_environment"
## group, then the manager's viewport environment.
@export var world_environment: WorldEnvironment

@export_group("Sun arc")
@export_range(0.0, 90.0) var max_elevation_deg := 78.0
## Total yaw swept over one day (the azimuth curve is normalized to this).
@export var azimuth_sweep_deg := 360.0
@export var azimuth_offset_deg := 0.0
## Normalized elevation in [-1, 1]; null = sine arc.
@export var elevation_curve: Curve
## Normalized azimuth in [0, 1] scaled by `azimuth_sweep_deg`; null = linear.
@export var azimuth_curve: Curve

@export_group("Sun ramps")
@export var sun_color_ramp: Gradient
@export var sun_energy_ramp: Curve

@export_group("Ambient ramps")
@export var ambient_color_ramp: Gradient
@export var ambient_energy_ramp: Curve

@export_group("Sky ramps")
@export var sky_top_ramp: Gradient
@export var sky_horizon_ramp: Gradient
@export var sky_ground_ramp: Gradient
@export var background_energy_ramp: Curve

@export_group("Fog ramps")
## Apply the fog ramps when the WorldEnvironment has fog enabled.
@export var apply_fog := true
@export var fog_color_ramp: Gradient
@export var fog_density_ramp: Curve
## Multiplier for the normalized density curve.
@export var fog_density_scale := 0.004


func _ready() -> void:
	_apply()


func _process(delta: float) -> void:
	if not auto_advance and not fast_forward:
		return
	var speed := fast_forward_speed if fast_forward else 1.0
	var rate := speed / maxf(day_length_seconds, 0.001)
	time_of_day = time_of_day + delta * rate


# ── Runtime API ──────────────────────────────────────────────────────────────

## Jump to a normalized time of day (wraps). Re-applies the whole rig.
func set_time_of_day(value: float) -> void:
	time_of_day = value


func get_time_of_day() -> float:
	return time_of_day


## Advance the clock by `seconds` of real time at the configured day length.
func advance_time(seconds: float) -> void:
	time_of_day = time_of_day + seconds / maxf(day_length_seconds, 0.001)


## Turn the accelerated test clock on/off (optionally retune the multiplier).
func set_fast_forward(enabled: bool, speed := -1.0) -> void:
	if speed > 0.0:
		fast_forward_speed = speed
	fast_forward = enabled


## Sun elevation in degrees for the current time (-90..90).
func get_sun_elevation_deg() -> float:
	return _elevation_deg(time_of_day)


## Sun yaw in degrees for the current time.
func get_sun_azimuth_deg() -> float:
	return _azimuth_deg(time_of_day)


# ── Application ──────────────────────────────────────────────────────────────

func _apply() -> void:
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	_resolve_refs()
	_ensure_ramps()
	var t := time_of_day
	if sun != null and is_instance_valid(sun):
		sun.rotation_degrees = Vector3(-_elevation_deg(t), _azimuth_deg(t), 0.0)
		sun.light_color = sun_color_ramp.sample(t)
		sun.light_energy = maxf(0.0, sun_energy_ramp.sample(t))
	if world_environment != null and is_instance_valid(world_environment):
		_apply_environment(world_environment.environment, t)


func _elevation_deg(t: float) -> float:
	if elevation_curve != null:
		return elevation_curve.sample(t) * max_elevation_deg
	return sin((t - 0.25) * TAU) * max_elevation_deg


func _azimuth_deg(t: float) -> float:
	if azimuth_curve != null:
		return azimuth_curve.sample(t) * azimuth_sweep_deg + azimuth_offset_deg
	return t * azimuth_sweep_deg + azimuth_offset_deg


func _apply_environment(env: Environment, t: float) -> void:
	if env == null:
		return
	env.ambient_light_color = ambient_color_ramp.sample(t)
	env.ambient_light_energy = maxf(0.0, ambient_energy_ramp.sample(t))
	env.background_energy_multiplier = maxf(0.0, background_energy_ramp.sample(t))
	var sky := env.sky
	if sky != null and sky.sky_material is ProceduralSkyMaterial:
		var sky_material := sky.sky_material as ProceduralSkyMaterial
		var horizon := sky_horizon_ramp.sample(t)
		sky_material.sky_top_color = sky_top_ramp.sample(t)
		sky_material.sky_horizon_color = horizon
		sky_material.ground_horizon_color = horizon.darkened(0.35)
		sky_material.ground_bottom_color = sky_ground_ramp.sample(t)
	if apply_fog and env.fog_enabled:
		env.fog_light_color = fog_color_ramp.sample(t)
		env.fog_density = maxf(0.0, fog_density_ramp.sample(t) * fog_density_scale)


func _resolve_refs() -> void:
	if manager == null or not is_instance_valid(manager):
		manager = PixelizerManager3D.resolve_manager(self)
	if sun == null or not is_instance_valid(sun):
		if manager != null and manager.sun != null:
			sun = manager.sun
		else:
			sun = get_tree().get_root().find_child("Sun", true, false) as DirectionalLight3D
	if sun != null and manager != null and is_instance_valid(manager):
		# The manager reads the sun node every frame; making sure they are the
		# same object is the whole "wiring".
		manager.sun = sun
	if world_environment == null or not is_instance_valid(world_environment):
		world_environment = get_tree().get_first_node_in_group("world_environment") as WorldEnvironment


# ── Default ramps (created lazily so the inspector shows authored values) ────

func _ensure_ramps() -> void:
	# `elevation_curve` / `azimuth_curve` stay null by default: null means the
	# analytic sine arc / linear sweep, which needs no authored resource.
	if sun_color_ramp == null:
		sun_color_ramp = _ramp([
			[0.0, Color(0.04, 0.06, 0.19)],
			[0.2, Color(0.08, 0.13, 0.29)],
			[0.25, Color(0.88, 0.39, 0.18)],
			[0.3, Color(1.0, 0.79, 0.54)],
			[0.5, Color(1.0, 0.96, 0.9)],
			[0.7, Color(1.0, 0.79, 0.54)],
			[0.75, Color(0.88, 0.39, 0.18)],
			[0.8, Color(0.08, 0.13, 0.29)],
			[1.0, Color(0.04, 0.06, 0.19)],
		])
	if sun_energy_ramp == null:
		sun_energy_ramp = _curve([
			[0.0, 0.0], [0.2, 0.02], [0.25, 0.35], [0.3, 0.85], [0.5, 1.25],
			[0.7, 0.85], [0.75, 0.35], [0.8, 0.02], [1.0, 0.0],
		])
	if ambient_color_ramp == null:
		ambient_color_ramp = _ramp([
			[0.0, Color(0.08, 0.11, 0.2)],
			[0.25, Color(0.29, 0.23, 0.33)],
			[0.3, Color(0.66, 0.69, 0.78)],
			[0.5, Color(0.85, 0.89, 0.96)],
			[0.7, Color(0.66, 0.69, 0.78)],
			[0.75, Color(0.29, 0.23, 0.33)],
			[1.0, Color(0.08, 0.11, 0.2)],
		])
	if ambient_energy_ramp == null:
		ambient_energy_ramp = _curve([
			[0.0, 0.06], [0.22, 0.1], [0.3, 0.35], [0.5, 0.5], [0.7, 0.35],
			[0.78, 0.1], [1.0, 0.06],
		])
	if sky_top_ramp == null:
		sky_top_ramp = _ramp([
			[0.0, Color(0.02, 0.03, 0.06)],
			[0.22, Color(0.06, 0.1, 0.2)],
			[0.3, Color(0.24, 0.42, 0.63)],
			[0.5, Color(0.25, 0.47, 0.72)],
			[0.7, Color(0.24, 0.42, 0.63)],
			[0.78, Color(0.06, 0.1, 0.2)],
			[1.0, Color(0.02, 0.03, 0.06)],
		])
	if sky_horizon_ramp == null:
		sky_horizon_ramp = _ramp([
			[0.0, Color(0.04, 0.06, 0.13)],
			[0.22, Color(0.13, 0.16, 0.28)],
			[0.25, Color(0.85, 0.41, 0.24)],
			[0.3, Color(1.0, 0.85, 0.66)],
			[0.5, Color(0.74, 0.85, 0.94)],
			[0.7, Color(1.0, 0.85, 0.66)],
			[0.75, Color(0.85, 0.41, 0.24)],
			[0.78, Color(0.13, 0.16, 0.28)],
			[1.0, Color(0.04, 0.06, 0.13)],
		])
	if sky_ground_ramp == null:
		sky_ground_ramp = _ramp([
			[0.0, Color(0.03, 0.04, 0.09)],
			[0.25, Color(0.19, 0.15, 0.18)],
			[0.3, Color(0.42, 0.42, 0.35)],
			[0.5, Color(0.48, 0.52, 0.44)],
			[0.7, Color(0.42, 0.42, 0.35)],
			[0.75, Color(0.19, 0.15, 0.18)],
			[1.0, Color(0.03, 0.04, 0.09)],
		])
	if background_energy_ramp == null:
		background_energy_ramp = _curve([
			[0.0, 0.4], [0.25, 0.6], [0.3, 1.0], [0.7, 1.0], [0.75, 0.6],
			[1.0, 0.4],
		])
	if fog_color_ramp == null:
		fog_color_ramp = _ramp([
			[0.0, Color(0.04, 0.07, 0.13)],
			[0.25, Color(0.35, 0.19, 0.23)],
			[0.3, Color(0.85, 0.69, 0.56)],
			[0.5, Color(0.81, 0.88, 0.93)],
			[0.7, Color(0.85, 0.69, 0.56)],
			[0.75, Color(0.35, 0.19, 0.23)],
			[1.0, Color(0.04, 0.07, 0.13)],
		])
	if fog_density_ramp == null:
		fog_density_ramp = _curve([
			[0.0, 0.7], [0.25, 0.5], [0.5, 0.25], [0.75, 0.5], [1.0, 0.7],
		])


func _ramp(keys: Array) -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([float(keys[0][0]), float(keys[1][0])])
	gradient.colors = PackedColorArray([keys[0][1], keys[1][1]])
	for i in range(2, keys.size()):
		gradient.add_point(float(keys[i][0]), keys[i][1])
	return gradient


## Linear-interpolated curve through the keys. Godot 4.7 dropped
## `Curve.interpolation_mode`; the same result comes from per-point linear
## tangents (`TANGENT_LINEAR`), which make segment interpolation straight.
func _curve(keys: Array) -> Curve:
	var curve := Curve.new()
	curve.clear_points()
	for key in keys:
		var index := curve.add_point(Vector2(key[0], key[1]))
		curve.set_point_left_mode(index, Curve.TANGENT_LINEAR)
		curve.set_point_right_mode(index, Curve.TANGENT_LINEAR)
	return curve
