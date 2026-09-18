class_name PixelizerEffectBase
extends CompositorEffect

## Shared plumbing for the pixelizer compute effects: render-thread shader
## compilation, sampler creation, uniform helpers, and dispatch.

var manager: Node = null
var shader_path := ""

var rd: RenderingDevice = null
var _shader: RID
var _pipeline: RID
var _sampler: RID
var _initialized := false


func _init(p_callback_type: int = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT) -> void:
	effect_callback_type = p_callback_type
	access_resolved_color = true
	access_resolved_depth = true
	rd = RenderingServer.get_rendering_device()
	if rd != null and not shader_path.is_empty():
		# Shader compilation and RD object creation must happen on the render
		# thread (RD has a thread guard).
		RenderingServer.call_on_render_thread(_initialize_render_thread)


func _initialize_render_thread() -> void:
	if rd == null or shader_path.is_empty():
		return
	var shader_file := load(shader_path) as RDShaderFile
	if shader_file == null:
		push_error("Pixelizer3D: cannot load compute shader %s" % shader_path)
		return
	_shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)
	_create_pipeline()
	_initialized = true
	_on_render_thread_ready()


## Subclasses override for raster pipelines (which are built lazily from the
## scene-buffer framebuffer format).
func _create_pipeline() -> void:
	_pipeline = rd.compute_pipeline_create(_shader)


func _on_render_thread_ready() -> void:
	pass


func _make_sampler_uniform(p_sampler: RID, p_texture: RID, p_binding: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = p_binding
	uniform.add_id(p_sampler)
	uniform.add_id(p_texture)
	return uniform


func _make_image_uniform(p_image: RID, p_binding: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = p_binding
	uniform.add_id(p_image)
	return uniform


func _dispatch(p_uniform_set: RID, p_size: Vector2i, p_push: PackedFloat32Array = PackedFloat32Array()) -> void:
	var x_groups := int(ceil(float(p_size.x) / 8.0))
	var y_groups := int(ceil(float(p_size.y) / 8.0))
	if x_groups <= 0 or y_groups <= 0:
		return
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, p_uniform_set, 0)
	if not p_push.is_empty():
		rd.compute_list_set_push_constant(list, p_push.to_byte_array(), p_push.size() * 4)
	rd.compute_list_dispatch(list, x_groups, y_groups, 1)
	rd.compute_list_end()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		if _sampler.is_valid():
			rd.free_rid(_sampler)
		if _pipeline.is_valid():
			rd.free_rid(_pipeline)
		if _shader.is_valid():
			rd.free_rid(_shader)
