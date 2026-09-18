class_name PixelizerMaterialFactory
extends RefCounted

## Builds and caches pixelizer ShaderMaterials from source materials. Materials
## are cached per source-material instance, so every object that shares a source
## material shares one pixelizer material (per-object parameters ride on instance
## uniforms instead of material duplication).

const SHADER_PATH := "res://addons/pixelizer_3d/shaders/pixelizer_object.gdshader"

var shader: Shader
var cloud_params: Dictionary = {}
var _cache: Dictionary = {}
## id -> WeakRef(source). Source-instance ids are unique while alive and not
## reused deterministically, so a dead weak ref means the cache entry is stale
## (MST chunk rebuilds / runtime material swaps) and must be dropped.
var _source_refs: Dictionary = {}


func _init() -> void:
	shader = load(SHADER_PATH) as Shader


func get_pixelizer_material(source: Material) -> ShaderMaterial:
	var key := 0
	if source != null:
		key = int(source.get_instance_id())
	if _cache.has(key):
		var ref: WeakRef = _source_refs.get(key)
		if source == null or (ref != null and ref.get_ref() != null):
			return _cache[key]
		# The source material was freed; drop the stale conversion and rebuild.
		_cache.erase(key)
		_source_refs.erase(key)
	# Custom ShaderMaterials carry their own shading (MST terrain, etc.). They
	# must opt in via manager.register_pixelized_material() — replacing one
	# with the generic pixelizer shader drops all of its appearance (white
	# mesh). Return it untouched so the caller can leave the surface as-is.
	if source is ShaderMaterial:
		push_warning("Pixelizer3D: cannot convert custom ShaderMaterial '%s' (%s); leaving it unpixelized. Register it with manager.register_pixelized_material() to opt into the anchor pipeline." % [source.resource_name if (source as ShaderMaterial).resource_name != "" else "unnamed", (source as ShaderMaterial).shader.resource_path if (source as ShaderMaterial).shader != null else "no shader"])
		return source as ShaderMaterial
	var material := ShaderMaterial.new()
	material.shader = shader
	apply_cloud_params(material)
	if source is BaseMaterial3D:
		_copy_base_material(source, material)
	_cache[key] = material
	if source != null:
		_source_refs[key] = weakref(source)
	return material


func apply_cloud_params(material: ShaderMaterial) -> void:
	for key in cloud_params:
		material.set_shader_parameter(key, cloud_params[key])


## Update the cloud-shadow uniform set on every cached material and remember it
## for materials created later.
func set_cloud_params(params: Dictionary) -> void:
	cloud_params = params
	for material in _cache.values():
		if material is ShaderMaterial:
			apply_cloud_params(material)


func _copy_base_material(source: BaseMaterial3D, target: ShaderMaterial) -> void:
	target.set_shader_parameter("albedo_color", source.albedo_color)
	if source.albedo_texture != null:
		target.set_shader_parameter("albedo_texture", source.albedo_texture)
	target.set_shader_parameter("use_vertex_color", source.vertex_color_use_as_albedo)
	match source.transparency:
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			target.set_shader_parameter("alpha_scissor", source.alpha_scissor_threshold)
		BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_HASH, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
			target.set_shader_parameter("dither_alpha", true)
	target.set_shader_parameter("roughness", source.roughness)
	target.set_shader_parameter("metallic", source.metallic)
	target.set_shader_parameter("specular_amount", source.metallic_specular)
	if source.emission_enabled:
		target.set_shader_parameter("emission_color", Color(source.emission.r, source.emission.g, source.emission.b, 1.0))
		target.set_shader_parameter("emission_energy", source.emission_energy_multiplier)
