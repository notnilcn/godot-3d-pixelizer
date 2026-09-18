@tool
extends MultiMeshInstance3D
class_name MarchingSquaresGrassPlanter


# Alpha values for grass sprites by texture ID (1-6)
const GRASS_ALPHA_VALUES := [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]

# Grass points stay this far inside the hex border (fraction of hex_size), keeping them off cliff rims
const GRASS_BORDER_INSET : float = 0.85

var _chunk : MarchingSquaresTerrainChunk
var terrain_system : MarchingSquaresTerrain


func setup(chunk: MarchingSquaresTerrainChunk, redo: bool = true):
	_chunk = chunk
	terrain_system = _chunk.terrain_system
	
	if not _chunk or not terrain_system:
		push_error("SETUP FAILED - no chunk or terrain system found for GrassPlanter")
		return
	
	if (redo and multimesh) or !multimesh:
		multimesh = MultiMesh.new()
	multimesh.instance_count = 0
	
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	var hex_count : int = 3 * terrain_system.chunk_radius * (terrain_system.chunk_radius + 1) + 1
	multimesh.instance_count = hex_count * terrain_system.grass_subdivisions * terrain_system.grass_subdivisions
	if terrain_system.grass_mesh:
		multimesh.mesh = terrain_system.grass_mesh
	else:
		multimesh.mesh = QuadMesh.new() # Create a temporary quad
	multimesh.mesh.size = terrain_system.grass_size * terrain_system.hex_size / 2.0
	multimesh.mesh.center_offset.y = multimesh.mesh.size.y / 2.0
	
	cast_shadow = SHADOW_CASTING_SETTING_OFF


## Regenerate all grass instances of the chunk from its hex records.
## Grass grows on hexes whose grass flag is set and whose ground texture allows it
## (textures 1-6, i.e. ground slots 0-5). Points are rejection-sampled inside the
## hex top polygon, seeded per hex so regeneration is stable.
func regenerate_grass() -> void:
	# Safety checks
	if not _chunk:
		push_error("_chunk not set while regenerating grass")
		return
	
	if not terrain_system:
		push_error("terrain_system not set while regenerating grass")
		return
	
	if not multimesh:
		setup(_chunk)
	
	var hex_size : float = terrain_system.hex_size
	var level_height : float = terrain_system.level_height
	var per_hex : int = terrain_system.grass_subdivisions * terrain_system.grass_subdivisions
	var chunk_origin : Vector3 = _chunk.global_position if _chunk.is_inside_tree() else _chunk.position
	var index := 0
	
	# The multimesh may pre-exist with a stale instance count (loaded bake, changed
	# settings) - resize through 0 so leftover instances are cleared, not just hidden
	var needed_count : int = (3 * _chunk.get_chunk_radius() * (_chunk.get_chunk_radius() + 1) + 1) * per_hex
	if multimesh.instance_count != needed_count:
		multimesh.instance_count = 0
		multimesh.instance_count = needed_count
	
	for local_hex in MSTHexMath.hex_range(_chunk.get_chunk_radius()):
		var record : Dictionary = _chunk.hex_data.get(local_hex, {})
		var center_xz := MSTHexMath.hex_to_world(local_hex.x, local_hex.y, hex_size)
		var hex_top := Vector3(center_xz.x, int(record.get("elevation", 0)) * level_height, center_xz.y)
		# Texture ids are the ground slot + 1 (ground slot 0 = texture 1)
		var texture_id : int = int(record.get("ground", 0)) + 1
		
		var rng := RandomNumberGenerator.new()
		rng.seed = _hex_seed(local_hex)
		
		for i in range(per_hex):
			if index >= multimesh.instance_count:
				return
			if record.get("grass", false) and _has_grass_for_texture(texture_id):
				var local_point := hex_top + _random_point_in_hex(rng, hex_size * GRASS_BORDER_INSET)
				_create_grass_instance(index, local_point, chunk_origin + local_point, texture_id)
			else:
				_hide_grass_instance(index)
			index += 1


# Deterministic per-hex seed so regeneration scatters identical points.
func _hex_seed(local_hex: Vector2i) -> int:
	return hash(_chunk.chunk_coords) ^ hash(local_hex)


# Rejection-sample a uniform point inside a pointy-top hexagon of outer radius s.
# Inside iff |x| <= s * sqrt(3)/2 and |z| <= s - |x| / sqrt(3).
func _random_point_in_hex(rng: RandomNumberGenerator, s: float) -> Vector3:
	var half_width : float = s * 0.8660254
	while true:
		var x := rng.randf_range(-half_width, half_width)
		var z := rng.randf_range(-s, s)
		if absf(z) <= s - absf(x) * 0.5773503:
			return Vector3(x, 0.0, z)
	return Vector3.ZERO


#region grass property getters

func _get_terrain_image(texture_id: int) -> Image:
	var terrain_texture : Texture2D = null
	var material := terrain_system.terrain_material
	match texture_id:
		2:
			terrain_texture = material.get_shader_parameter("vc_tex_rg")
		3:
			terrain_texture = material.get_shader_parameter("vc_tex_rb")
		4:
			terrain_texture = material.get_shader_parameter("vc_tex_ra")
		5:
			terrain_texture = material.get_shader_parameter("vc_tex_gr")
		6:
			terrain_texture = material.get_shader_parameter("vc_tex_gg")
		_: # Base grass
			terrain_texture = material.get_shader_parameter("vc_tex_rr")
	if terrain_texture == null:
		return null
	
	var img : Image = terrain_texture.get_image()
	if img:
		img.decompress()
	return img


## Checks if the given texture ID (1-16) should have grass placed on it.
func _has_grass_for_texture(texture_id: int) -> bool:
	if texture_id == 1:
		return true  # Base grass always has grass
	if texture_id < 2 or texture_id > 6:
		return false
	
	# Data-driven lookup instead of match
	var has_grass_flags := [
		terrain_system.tex2_has_grass,
		terrain_system.tex3_has_grass,
		terrain_system.tex4_has_grass,
		terrain_system.tex5_has_grass,
		terrain_system.tex6_has_grass
	]
	return has_grass_flags[texture_id - 2]


## Gets the texture scale for the given texture ID.
func _get_texture_scale(texture_id: int) -> float:
	var scales := [
		terrain_system.texture_scale_1,
		terrain_system.texture_scale_2,
		terrain_system.texture_scale_3,
		terrain_system.texture_scale_4,
		terrain_system.texture_scale_5,
		terrain_system.texture_scale_6
	]
	var idx := clampi(texture_id - 1, 0, 5)
	return scales[idx]


## Gets the grass sprite alpha value for the given texture ID.
func _get_grass_alpha(texture_id: int) -> float:
	var idx := clampi(texture_id - 1, 0, 5)
	return GRASS_ALPHA_VALUES[idx]


## Samples the terrain texture color at the given world position.
func _sample_terrain_texture_color(world_pos: Vector3, texture_id: int, tex_scale: float) -> Color:
	var terrain_image := _get_terrain_image(texture_id)
	if not terrain_image:
		return Color.WHITE
	
	# The terrain shader tiles textures at 1 world unit, scaled per texture
	var uv := Vector2(world_pos.x, world_pos.z) * tex_scale
	uv.x = fposmod(uv.x, 1.0)
	uv.y = fposmod(uv.y, 1.0)
	
	var px := int(uv.x * (terrain_image.get_width() - 1))
	var py := int(uv.y * (terrain_image.get_height() - 1))
	var color := terrain_image.get_pixelv(Vector2i(px, py))
	if _format_needs_conversion(terrain_image.get_format()):
		return color.srgb_to_linear()
	return color


func _format_needs_conversion(fmt: Image.Format) -> bool:
	match(fmt):
		Image.FORMAT_RGB8, \
		Image.FORMAT_RGBA8, \
		Image.FORMAT_DXT1, \
		Image.FORMAT_DXT3, \
		Image.FORMAT_DXT5, \
		Image.FORMAT_BPTC_RGBA, \
		Image.FORMAT_ETC2_RGB8 , \
		Image.FORMAT_ETC2_RGBA8 , \
		Image.FORMAT_ETC2_RGB8A1 : return true
	return false

#endregion

#region grass placement helpers

## Creates a grass instance at the given position with proper transform and color.
## Hex tops are flat, so the instance normal is always up. The shader rebuilds the
## blade position from the camera (spherical billboarding) and only reads the
## instance origin, but it discards blades whose world normal points away from up -
## so the basis z axis must be UP, not DOWN.
func _create_grass_instance(index: int, local_pos: Vector3, world_pos: Vector3, texture_id: int) -> void:
	var right := Vector3.FORWARD.cross(Vector3.UP).normalized()
	var forward := Vector3.UP.cross(Vector3.RIGHT).normalized()
	var instance_basis := Basis(right, forward, Vector3.UP)
	
	multimesh.set_instance_transform(index, Transform3D(instance_basis, local_pos))
	
	var tex_scale := _get_texture_scale(texture_id)
	var instance_color := _sample_terrain_texture_color(world_pos, texture_id, tex_scale)
	instance_color.a = _get_grass_alpha(texture_id)
	
	multimesh.set_instance_custom_data(index, instance_color)


## Hides a grass instance by scaling it to zero.
func _hide_grass_instance(index: int) -> void:
	multimesh.set_instance_transform(index, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))

#endregion
