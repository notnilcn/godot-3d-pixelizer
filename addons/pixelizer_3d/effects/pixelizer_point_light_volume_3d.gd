class_name PixelizerPointLightVolume3D
extends MeshInstance3D

## Additive banded point-light volume around this node's origin. Builds a sphere
## sized to the light radius and assigns `point_light_volume.gdshader`, then
## registers the material with the manager so it can safely sit under a
## PixelizerApplier3D (the metadata camera discards it; the factory never
## replaces it).
##
## Place the node at the light position; all falloff math is in the shader, the
## mesh only bounds the affected screen area.

const SHADER_PATH := "res://addons/pixelizer_3d/shaders/point_light_volume.gdshader"

@export var manager: PixelizerManager3D

@export_group("Pool")
@export var light_color := Color(1.0, 0.85, 0.5, 1.0): set = _set_light_color
@export var light_radius := 6.0: set = _set_light_radius
@export var falloff := 2.0: set = _set_falloff
@export_range(1.0, 16.0, 1.0) var band_count := 4.0: set = _set_band_count
@export var band_tightness := 4.0: set = _set_band_tightness
@export var intensity := 1.0: set = _set_intensity

@export_group("Halo")
@export var halo_color := Color(1.0, 0.92, 0.65, 1.0): set = _set_halo_color
@export var halo_size := 1.0: set = _set_halo_size
@export var halo_intensity := 1.0: set = _set_halo_intensity
@export var halo_falloff := 2.0: set = _set_halo_falloff
@export_range(1.0, 16.0, 1.0) var halo_band_count := 4.0: set = _set_halo_band_count

## Hide the whole contribution when opaque geometry sits between the camera and
## the light centre (occlusion-style: no light through walls).
@export var occlude_by_depth := true: set = _set_occlude_by_depth
## Depth slack of the visibility test (a lamp bulb mesh at the light centre
## must not occlude its own light).
@export var depth_slack := 0.5: set = _set_depth_slack

var _material: ShaderMaterial


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = false
	var extent := maxf(light_radius, halo_size) * 1.05
	var sphere := SphereMesh.new()
	sphere.radius = extent
	sphere.height = extent * 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	mesh = sphere

	_material = ShaderMaterial.new()
	_material.shader = load(SHADER_PATH) as Shader
	material_override = _material
	_push_params()

	if manager == null:
		manager = PixelizerManager3D.resolve_manager(self)
	if manager != null:
		manager.register_pixelized_material(_material)


func _exit_tree() -> void:
	if manager != null and is_instance_valid(manager) and _material != null and is_instance_valid(_material):
		manager.unregister_pixelized_material(_material)


func _push_params() -> void:
	if _material == null:
		return
	_material.set_shader_parameter("light_color", light_color)
	_material.set_shader_parameter("light_radius", light_radius)
	_material.set_shader_parameter("falloff", falloff)
	_material.set_shader_parameter("band_count", band_count)
	_material.set_shader_parameter("band_tightness", band_tightness)
	_material.set_shader_parameter("intensity", intensity)
	_material.set_shader_parameter("halo_color", halo_color)
	_material.set_shader_parameter("halo_size", halo_size)
	_material.set_shader_parameter("halo_intensity", halo_intensity)
	_material.set_shader_parameter("halo_falloff", halo_falloff)
	_material.set_shader_parameter("halo_band_count", halo_band_count)
	_material.set_shader_parameter("occlude_by_depth", occlude_by_depth)
	_material.set_shader_parameter("depth_slack", depth_slack)


func _set_light_color(value: Color) -> void:
	light_color = value
	_push_params()


func _set_light_radius(value: float) -> void:
	light_radius = value
	_push_params()


func _set_falloff(value: float) -> void:
	falloff = value
	_push_params()


func _set_band_count(value: float) -> void:
	band_count = value
	_push_params()


func _set_band_tightness(value: float) -> void:
	band_tightness = value
	_push_params()


func _set_intensity(value: float) -> void:
	intensity = value
	_push_params()


func _set_halo_color(value: Color) -> void:
	halo_color = value
	_push_params()


func _set_halo_size(value: float) -> void:
	halo_size = value
	_push_params()


func _set_halo_intensity(value: float) -> void:
	halo_intensity = value
	_push_params()


func _set_halo_falloff(value: float) -> void:
	halo_falloff = value
	_push_params()


func _set_halo_band_count(value: float) -> void:
	halo_band_count = value
	_push_params()


func _set_occlude_by_depth(value: bool) -> void:
	occlude_by_depth = value
	_push_params()


func _set_depth_slack(value: float) -> void:
	depth_slack = maxf(value, 0.0)
	_push_params()
