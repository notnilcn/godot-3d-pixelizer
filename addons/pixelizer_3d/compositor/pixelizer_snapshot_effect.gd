class_name PixelizerSnapshotEffect
extends PixelizerEffectBase

## Snapshots the scene colour and depth into named render-scene-buffer textures
## in a single dispatch (two storage images). The apply pass samples both copies
## while writing the scene colour/depth attachments in place.

const CONTEXT := &"pixelizer"
const COLOR_TEXTURE := &"color_copy"
const DEPTH_TEXTURE := &"depth_copy"

## Last bound source RIDs and the RDUniform array built from them; rebuilt only
## when an RID changes (resize / render-target recreation).
var _last_color := RID()
var _last_depth := RID()
var _last_color_copy := RID()
var _last_depth_copy := RID()
var _uniforms: Array = []


func _init() -> void:
	shader_path = "res://addons/pixelizer_3d/shaders/compute/copy_scene.glsl"
	super._init(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT)


func _render_callback(p_callback_type: int, p_render_data: RenderData) -> void:
	if p_callback_type != effect_callback_type or not _initialized or manager == null:
		return
	var buffers := p_render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_view_count() > 1:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var color_rid := buffers.get_color_layer(0)
	var depth_rid := buffers.get_depth_layer(0)
	var color_copy := _get_color_copy(buffers)
	var depth_copy := _get_depth_copy(buffers)
	if not color_rid.is_valid() or not depth_rid.is_valid() or not color_copy.is_valid() or not depth_copy.is_valid():
		return
	if color_rid != _last_color or depth_rid != _last_depth or color_copy != _last_color_copy or depth_copy != _last_depth_copy:
		_last_color = color_rid
		_last_depth = depth_rid
		_last_color_copy = color_copy
		_last_depth_copy = depth_copy
		_uniforms = [
			_make_sampler_uniform(_sampler, color_rid, 0),
			_make_sampler_uniform(_sampler, depth_rid, 1),
			_make_image_uniform(color_copy, 2),
			_make_image_uniform(depth_copy, 3),
		]
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, _uniforms)
	_dispatch(uniform_set, size)


func _get_color_copy(buffers: RenderSceneBuffersRD) -> RID:
	if buffers.has_texture(CONTEXT, COLOR_TEXTURE):
		return buffers.get_texture(CONTEXT, COLOR_TEXTURE)
	return buffers.create_texture(
		CONTEXT,
		COLOR_TEXTURE,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
		RenderingDevice.TEXTURE_SAMPLES_1,
		Vector2i.ZERO,
		0,
		1,
		false,
		false)


func _get_depth_copy(buffers: RenderSceneBuffersRD) -> RID:
	if buffers.has_texture(CONTEXT, DEPTH_TEXTURE):
		return buffers.get_texture(CONTEXT, DEPTH_TEXTURE)
	return buffers.create_texture(
		CONTEXT,
		DEPTH_TEXTURE,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
		RenderingDevice.TEXTURE_SAMPLES_1,
		Vector2i.ZERO,
		0,
		1,
		false,
		false)
