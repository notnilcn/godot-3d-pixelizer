class_name PixelizerGodRayEffect
extends PixelizerEffectBase

## God rays through the banded cloud layer, marched per pixel and poured
## through the coverage gaps.
##
## Runs FIRST in the manager's PRE_TRANSPARENT compositor array, before
## the snapshot pass, and writes additively into the scene colour layer, so the rays
## are part of the image the anchor-map/apply passes replicate into macro-pixels.
##
## The cloud field is pushed by the manager from the same `Effects.Cloud_Shadows`
## parameters the shadow materials use (cloud_fbm.gdshaderinc contract), so the
## rays pour through the same gaps the ground shadows come from.
##
## Tuning property names (ray_steps … ray_distance_falloff) are the main-client
## contract: PixelArtPipelineComponent fetches this object via
## `manager.get_god_ray_pass()` and `Set()`s them untyped. Do not rename.

## Master toggle; the pass early-outs when false. Owned by PixelizerManager3D
## (`ray_pass`); `PixelizerGodRays3D` toggles it, and it can be tuned directly
## through `manager.get_god_ray_pass()`.
@export var rays_enabled := false
@export_range(1, 128) var ray_steps := 24
@export var ray_max_distance := 600.0
@export var ray_intensity := 0.5
## Exponential decay of the accumulation along the normalized march.
@export var ray_decay := 2.0
## Quantize the ray intensity to this many bands (<= 1 disables).
@export var ray_quantize_bands := 4.0
## How strongly a second, slower high-threshold noise modulates the shafts.
@export_range(0.0, 1.0) var ray_dust_strength := 0.15
## Distance along the ray where the near fade-in starts (world units).
@export var ray_near_fade_start := 0.0
## Fade-in range past the start; 0 disables the near fade.
@export var ray_near_fade_range := 0.0
## Near fade curve exponent.
@export var ray_near_fade_power := 1.0
## Kill rays past this distance; 0 disables the cutoff.
@export var ray_depth_cutoff := 0.0
## Fade within this distance of the surface hit; 0 disables.
@export var ray_surface_fade := 0.0
## Clamp applied after `ray_quantum` scales the accumulation; 0 disables.
@export var ray_max_stack := 10.0
## Scale applied to the accumulation before the max-stack clamp; <= 0 -> 1.
@export var ray_quantum := 0.0
## Exponential falloff per world unit along the march; 0 disables.
@export var ray_distance_falloff := 0.0

# ── Cloud field (pushed by PixelizerManager3D; cloud_fbm.gdshaderinc parity) ──
var cloud_noise: Texture2D
var cloud_sun_dir := Vector3(0.0, -1.0, 0.0)
var cloud_height := 10.0
var cloud_noise_scale := 0.05
var cloud_threshold := 0.5
var cloud_bands := 3.0
var cloud_tightness := 1.0
var cloud_gap_erosion := 0.0
var cloud_detail_strength := 0.0
var cloud_wind := Vector2(0.02, 0.0)
var cloud_shadow_strength := 0.6
var cloud_shadow_banding_enabled := true
var cloud_shadow_levels := 3.0
var cloud_shadow_softness := 0.4
## Ray colour; the manager pushes the sun's light colour (warm fallback).
var ray_tint := Color(1.0, 0.96, 0.85)
## Cloud-field phase in seconds. < 0 uses the wall clock; >= 0 pins the phase so
## ray captures are reproducible (the demo pins 0 for `--capture`).
var time_override := -1.0

var _noise_sampler: RID
var _params_buffer: RID
var _warned_no_noise := false
## Preallocated per-frame uniform buffer staging (no resize per frame).
var _values := PackedFloat32Array()
## Last bound source RIDs and the RDUniform array built from them; rebuilt only
## when an RID changes (resize / render-target recreation).
var _last_color := RID()
var _last_depth := RID()
var _last_noise := RID()
var _uniforms: Array = []

const PARAMS_SIZE := 240 # 15 vec4s (mat4 + 11 vec4s); matches god_rays.glsl.


func _init() -> void:
	shader_path = "res://addons/pixelizer_3d/shaders/compute/god_rays.glsl"
	super._init(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT)


func _on_render_thread_ready() -> void:
	# Cloud noise tiles across the world; the depth sampler is the base class's
	# clamp/nearest one.
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_noise_sampler = rd.sampler_create(state)
	_params_buffer = rd.uniform_buffer_create(PARAMS_SIZE)
	_values.resize(PARAMS_SIZE / 4)


## Copy the manager's cloud parameter dictionary (Effects.Cloud_Shadows keys).
func set_cloud_params(params: Dictionary) -> void:
	if params.has("cloud_noise"):
		cloud_noise = params["cloud_noise"]
	if params.has("cloud_sun_dir"):
		cloud_sun_dir = params["cloud_sun_dir"]
	if params.has("cloud_height"):
		cloud_height = params["cloud_height"]
	if params.has("cloud_noise_scale"):
		cloud_noise_scale = params["cloud_noise_scale"]
	if params.has("cloud_threshold"):
		cloud_threshold = params["cloud_threshold"]
	if params.has("cloud_bands"):
		cloud_bands = params["cloud_bands"]
	if params.has("cloud_tightness"):
		cloud_tightness = params["cloud_tightness"]
	if params.has("cloud_gap_erosion"):
		cloud_gap_erosion = params["cloud_gap_erosion"]
	if params.has("cloud_detail_strength"):
		cloud_detail_strength = params["cloud_detail_strength"]
	if params.has("cloud_wind"):
		cloud_wind = params["cloud_wind"]
	if params.has("cloud_shadow_strength"):
		cloud_shadow_strength = params["cloud_shadow_strength"]
	if params.has("cloud_shadow_banding_enabled"):
		cloud_shadow_banding_enabled = params["cloud_shadow_banding_enabled"]
	if params.has("cloud_shadow_levels"):
		cloud_shadow_levels = float(params["cloud_shadow_levels"])
	if params.has("cloud_shadow_softness"):
		cloud_shadow_softness = params["cloud_shadow_softness"]


func _render_callback(p_callback_type: int, p_render_data: RenderData) -> void:
	if p_callback_type != effect_callback_type or not _initialized or manager == null:
		return
	if not rays_enabled:
		return
	if cloud_noise == null:
		if not _warned_no_noise:
			_warned_no_noise = true
			push_warning("PixelizerGodRayEffect: rays_enabled but no cloud noise assigned; pass is inert.")
		return
	var buffers := p_render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_view_count() > 1:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var color_rid := buffers.get_color_layer(0)
	var depth_rid := buffers.get_depth_layer(0)
	var noise_rid := RenderingServer.texture_get_rd_texture(cloud_noise.get_rid(), false)
	if not color_rid.is_valid() or not depth_rid.is_valid() or not noise_rid.is_valid():
		return
	var scene_data := p_render_data.get_render_scene_data()
	if scene_data == null:
		return

	# Fill the per-frame uniform buffer (15 vec4s, matches the GLSL Params block).
	var cam_xform := scene_data.get_cam_transform()
	var inv_vp: Projection = (scene_data.get_cam_projection() * Projection(cam_xform.affine_inverse())).inverse()
	var values := _values
	# Explicit field writes (no per-frame array literal).
	values[0] = inv_vp.x.x; values[1] = inv_vp.x.y; values[2] = inv_vp.x.z; values[3] = inv_vp.x.w
	values[4] = inv_vp.y.x; values[5] = inv_vp.y.y; values[6] = inv_vp.y.z; values[7] = inv_vp.y.w
	values[8] = inv_vp.z.x; values[9] = inv_vp.z.y; values[10] = inv_vp.z.z; values[11] = inv_vp.z.w
	values[12] = inv_vp.w.x; values[13] = inv_vp.w.y; values[14] = inv_vp.w.z; values[15] = inv_vp.w.w
	var i := 16
	values[i] = cam_xform.origin.x; values[i + 1] = cam_xform.origin.y; values[i + 2] = cam_xform.origin.z; i += 4
	values[i] = cloud_sun_dir.x; values[i + 1] = cloud_sun_dir.y; values[i + 2] = cloud_sun_dir.z; i += 4
	values[i] = cloud_noise_scale; values[i + 1] = cloud_threshold; values[i + 2] = cloud_bands; values[i + 3] = cloud_height; i += 4
	values[i] = cloud_tightness; values[i + 1] = cloud_shadow_softness
	values[i + 2] = cloud_shadow_levels; values[i + 3] = 1.0 if cloud_shadow_banding_enabled else 0.0; i += 4
	values[i] = cloud_gap_erosion; values[i + 1] = cloud_detail_strength
	# Wall clock otherwise: the ray field drifts with real time, which breaks
	# byte-reproducible captures (shader TIME under --fixed-fps does not).
	values[i + 2] = time_override if time_override >= 0.0 else Time.get_ticks_msec() / 1000.0; i += 4
	values[i] = cloud_wind.x; values[i + 1] = cloud_wind.y; i += 4
	values[i] = ray_max_distance; values[i + 1] = ray_intensity; values[i + 2] = ray_decay; values[i + 3] = ray_quantize_bands; i += 4
	values[i] = ray_dust_strength; values[i + 1] = float(ray_steps)
	values[i + 2] = ray_near_fade_start; values[i + 3] = ray_near_fade_range; i += 4
	values[i] = ray_near_fade_power; values[i + 1] = ray_depth_cutoff
	values[i + 2] = ray_surface_fade; values[i + 3] = ray_max_stack; i += 4
	values[i] = ray_quantum; values[i + 1] = ray_distance_falloff; i += 4
	values[i] = ray_tint.r; values[i + 1] = ray_tint.g; values[i + 2] = ray_tint.b
	rd.buffer_update(_params_buffer, 0, PARAMS_SIZE, values.to_byte_array())

	if color_rid != _last_color or depth_rid != _last_depth or noise_rid != _last_noise:
		_last_color = color_rid
		_last_depth = depth_rid
		_last_noise = noise_rid
		var u_params := RDUniform.new()
		u_params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		u_params.binding = 3
		u_params.add_id(_params_buffer)
		_uniforms = [
			_make_image_uniform(color_rid, 0),
			_make_sampler_uniform(_sampler, depth_rid, 1),
			_make_sampler_uniform(_noise_sampler, noise_rid, 2),
			u_params,
		]
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, _uniforms)
	if not uniform_set.is_valid():
		return
	_dispatch(uniform_set, size)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		if _noise_sampler.is_valid():
			rd.free_rid(_noise_sampler)
		if _params_buffer.is_valid():
			rd.free_rid(_params_buffer)
	super._notification(what)
