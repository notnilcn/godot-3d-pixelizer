class_name PixelizerSkyClouds3D
extends MeshInstance3D

## Cloud field provider + optional visible banded cloud deck.
##
## Owns the 15 cloud-field parameters (`cloud_fbm.gdshaderinc` uniform contract)
## and registers itself with PixelizerManager3D via `register_cloud_provider()`.
## The manager builds the uniform dictionary from `build_cloud_params()` and
## pushes it to every cloud consumer (MST terrain, water, the deck itself, the
## god-ray pass), so shadows/rays/deck all read one field.
##
## `enabled` is the node toggle: a disabled node is equivalent to an absent one
## (it unregisters; the manager pushes neutral params). `deck_enabled` controls
## the visible sheet only — `deck_enabled = false` keeps cloud shadows/rays but
## hides the deck. Opaque alpha-scissor only.

const SHADER_PATH := "res://addons/pixelizer_3d/shaders/sky_clouds.gdshader"

## Manager whose cloud field drives the deck. Resolved via the ancestor walk /
## "pixelizer_manager" group when unset.
@export var manager: PixelizerManager3D

@export_group("Cloud Field")
## Master cloud toggle (the shader contract's `clouds_enabled`). Off means no
## shadows and no deck even while the node is enabled.
@export var clouds_enabled := false
## Seamless noise texture; generated (Perlin 0.02, seed 7) when unset.
@export var cloud_noise: Texture2D
## Height of the imaginary cloud plane the shadows project from.
@export var cloud_height := 400.0
@export var cloud_noise_scale := 0.0015
@export_range(0.0, 1.0) var cloud_threshold := 0.6
@export var cloud_bands := 3.0
@export_range(0.1, 4.0, 0.05) var cloud_tightness := 1.0
@export_range(0.1, 1.0, 0.05) var cloud_octave_drop := 0.5
@export_range(0.0, 0.45, 0.01) var cloud_gap_erosion := 0.0
@export_range(0.0, 1.0, 0.05) var cloud_detail_strength := 0.0
@export var cloud_wind := Vector2(0.01, 0.004)
@export_range(0.0, 1.0) var cloud_shadow_strength := 0.55
@export var cloud_shadow_banding_enabled := true
@export_range(1, 8) var cloud_shadow_levels := 3
@export_range(0.0, 1.0) var cloud_shadow_softness := 0.35

@export_group("Deck")
## Node toggle. Disabled unregisters this node (neutral params, no shadows).
@export var enabled := true: set = _set_enabled
## Visible cloud sheet. False = shadows/rays only.
@export var deck_enabled := true
## Deck extent; big is cheap (one quad). Keep it wider than the ortho view.
@export var plane_size := 4096.0
@export var cloud_color := Color(1.0, 1.0, 1.0, 1.0)
## Follow the camera on the XZ plane. The deck stays horizontal (no billboard:
## a camera-facing wall stabs through hillsides at shallow pitches).
@export var follow_camera := true
## Override for the deck height; <= 0 uses `cloud_height`.
@export var height := 0.0
@export var edge_fade := 0.15

var _material: ShaderMaterial
var _cloud_noise_generated: Texture2D
## Cached per-frame push values: set a shader parameter only when it changed.
var _last_noise_hi: Texture2D
var _last_cam_pos := Vector3(1e30, 1e30, 1e30)
var _last_cam_up := Vector3(1e30, 1e30, 1e30)
var _last_cam_fwd := Vector3(1e30, 1e30, 1e30)
var _last_half_h := -1.0
var _last_bound_on := -1e30


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = true
	var plane := PlaneMesh.new()
	plane.size = Vector2(plane_size, plane_size)
	mesh = plane
	_material = ShaderMaterial.new()
	_material.shader = load(SHADER_PATH) as Shader
	_material.set_shader_parameter("cloud_color", cloud_color)
	_material.set_shader_parameter("edge_fade", edge_fade)
	material_override = _material
	if manager == null:
		manager = PixelizerManager3D.resolve_manager(self)
	if not _manager_valid():
		push_warning("PixelizerSkyClouds3D: no PixelizerManager3D found; cloud deck is inert.")
		visible = false
		return
	if enabled:
		manager.register_cloud_provider(self)
	manager.register_cloud_material(_material)
	_update_transform()


func _exit_tree() -> void:
	if not _manager_valid():
		return
	manager.unregister_cloud_provider(self)
	manager.unregister_cloud_material(_material)


func _process(_delta: float) -> void:
	if not _manager_valid() or _material == null:
		return
	if follow_camera:
		_update_transform()
	_update_camera_frame()


# ── Cloud provider ───────────────────────────────────────────────────────────

## Build the shader uniform dictionary (same keys/defaults the manager used to
## own). Duck-typed provider contract; called by the manager every frame.
func build_cloud_params(sun: DirectionalLight3D) -> Dictionary:
	var sun_dir := Vector3(0.0, -1.0, 0.0)
	if sun != null and is_instance_valid(sun):
		sun_dir = -sun.global_transform.basis.z.normalized()
	if not enabled:
		return _neutral_params(sun_dir)
	return {
		"clouds_enabled": clouds_enabled,
		"cloud_noise": _effective_cloud_noise(),
		"cloud_sun_dir": sun_dir,
		"cloud_height": cloud_height,
		"cloud_noise_scale": cloud_noise_scale,
		"cloud_threshold": cloud_threshold,
		"cloud_bands": cloud_bands,
		"cloud_tightness": cloud_tightness,
		"cloud_octave_drop": cloud_octave_drop,
		"cloud_gap_erosion": cloud_gap_erosion,
		"cloud_detail_strength": cloud_detail_strength,
		"cloud_wind": cloud_wind,
		"cloud_shadow_strength": cloud_shadow_strength,
		"cloud_shadow_banding_enabled": cloud_shadow_banding_enabled,
		"cloud_shadow_levels": float(cloud_shadow_levels),
		"cloud_shadow_softness": cloud_shadow_softness,
	}


func _neutral_params(sun_dir: Vector3) -> Dictionary:
	return {
		"clouds_enabled": false,
		"cloud_noise": _effective_cloud_noise(),
		"cloud_sun_dir": sun_dir,
		"cloud_height": cloud_height,
		"cloud_noise_scale": cloud_noise_scale,
		"cloud_threshold": cloud_threshold,
		"cloud_bands": cloud_bands,
		"cloud_tightness": cloud_tightness,
		"cloud_octave_drop": cloud_octave_drop,
		"cloud_gap_erosion": cloud_gap_erosion,
		"cloud_detail_strength": cloud_detail_strength,
		"cloud_wind": cloud_wind,
		"cloud_shadow_strength": 0.0,
		"cloud_shadow_banding_enabled": cloud_shadow_banding_enabled,
		"cloud_shadow_levels": float(cloud_shadow_levels),
		"cloud_shadow_softness": cloud_shadow_softness,
	}


func _effective_cloud_noise() -> Texture2D:
	if cloud_noise != null:
		return cloud_noise
	if _cloud_noise_generated == null:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_PERLIN
		noise.frequency = 0.02
		noise.seed = 7
		var image := noise.get_seamless_image(256, 256)
		# Mipmaps: the sky cloud sheet views the deck at near-grazing angles,
		# where a mip-less 256px noise aliases into dot moiré (and the aliased
		# sheet depth makes the god-ray march jitter).
		image.generate_mipmaps()
		_cloud_noise_generated = ImageTexture.create_from_image(image)
	return _cloud_noise_generated


# ── Deck ─────────────────────────────────────────────────────────────────────

func _set_enabled(value: bool) -> void:
	if enabled == value:
		return
	enabled = value
	if not is_inside_tree() or not _manager_valid() or _material == null:
		return
	if enabled:
		manager.register_cloud_provider(self)
		manager.register_cloud_material(_material)
	else:
		manager.unregister_cloud_provider(self)
		manager.unregister_cloud_material(_material)
	_update_transform()


func _manager_valid() -> bool:
	return manager != null and is_instance_valid(manager)


func _update_transform() -> void:
	var camera := get_viewport().get_camera_3d()
	var deck_y := height if height > 0.0 else cloud_height
	if follow_camera and camera != null:
		global_position = Vector3(camera.global_position.x, deck_y, camera.global_position.z)
	else:
		global_position = Vector3(global_position.x, deck_y, global_position.z)
	visible = enabled and deck_enabled and clouds_enabled


func _update_camera_frame() -> void:
	var camera := get_viewport().get_camera_3d()
	_material.set_shader_parameter("cloud_color", cloud_color)
	_material.set_shader_parameter("edge_fade", edge_fade)
	# Mirror the manager-pushed noise into the mipmapped sampler (same texture;
	# its mipmaps smooth the deck's grazing-angle sampling).
	var noise: Texture2D = _material.get_shader_parameter("cloud_noise")
	if noise != null and noise != _last_noise_hi:
		_last_noise_hi = noise
		_material.set_shader_parameter("cloud_noise_hi", noise)
	if camera == null:
		return
	var cam_basis := camera.global_transform.basis.orthonormalized()
	var cam_up := cam_basis.y.normalized()
	var cam_pos := camera.global_position
	var half_h := camera.size * 0.5
	if camera.keep_aspect == Camera3D.KEEP_WIDTH:
		var viewport_size := get_viewport().get_visible_rect().size
		half_h = camera.size * 0.5 * viewport_size.y / maxf(viewport_size.x, 1.0)
	# Exit-line erosion only makes sense for an orthographic camera whose up
	# axis has a vertical component (cam_fwd.y = 0 parks the erosion off).
	var cam_fwd := Vector3.ZERO
	var bound_on := 0.0
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL and absf(cam_up.y) > 0.02 and absf(cam_basis.z.y) > 0.02:
		cam_fwd = -cam_basis.z.normalized()
		bound_on = (global_position.y - cam_pos.y) / cam_up.y / maxf(half_h, 0.0001)
	if cam_pos == _last_cam_pos and cam_up == _last_cam_up and cam_fwd == _last_cam_fwd \
			and half_h == _last_half_h and bound_on == _last_bound_on:
		return
	_last_cam_pos = cam_pos
	_last_cam_up = cam_up
	_last_cam_fwd = cam_fwd
	_last_half_h = half_h
	_last_bound_on = bound_on
	_material.set_shader_parameter("cam_pos", cam_pos)
	_material.set_shader_parameter("cam_up", cam_up)
	_material.set_shader_parameter("cam_fwd", cam_fwd)
	_material.set_shader_parameter("half_h", half_h)
	_material.set_shader_parameter("bound_on", bound_on)
