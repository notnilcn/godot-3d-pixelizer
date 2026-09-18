extends EditorNode3DGizmo
class_name MarchingSquaresTerrainGizmo


const BrushPatternCalculator = preload("uid://bli1mnri3jwpa")

var lines : PackedVector3Array = PackedVector3Array()

var addchunk_material : Material
var removechunk_material : Material
var highlightchunk_material : Material
var brush_material : Material

var terrain_plugin : MarchingSquaresTerrainPlugin

# Hex-prism brush visual (6-sided cylinder = pointy-top hex, corners already aligned)
var brush_hex_mesh : CylinderMesh


func _redraw():
	lines.clear()
	clear()
	
	addchunk_material = get_plugin().get_material("addchunk", self)
	removechunk_material = get_plugin().get_material("removechunk", self)
	highlightchunk_material = get_plugin().get_material("highlightchunk", self)
	brush_material = get_plugin().get_material("brush", self)
	
	var terrain_system: MarchingSquaresTerrain = get_node_3d()
	terrain_plugin = MarchingSquaresTerrainPlugin.instance
	
	# Only draw the gizmo if this is the only selected node
	if len(EditorInterface.get_selection().get_selected_nodes()) != 1:
		return
	if EditorInterface.get_selection().get_selected_nodes()[0] != terrain_system:
		return
	
	# Selected chunk gizmo lines
	if terrain_plugin.mode == terrain_plugin.TerrainToolMode.CHUNK_MANAGEMENT and terrain_plugin.selected_chunk:
		if terrain_plugin.current_terrain_node.find_child("Chunk " + str(terrain_plugin.selected_chunk.chunk_coords)):
			add_chunk_lines(terrain_system, terrain_plugin.selected_chunk.chunk_coords, highlightchunk_material)
		else:
			lines.clear()
	
	# Chunk management gizmo lines
	if terrain_system.chunks.is_empty():
		if terrain_plugin.is_chunk_plane_hovered:
			add_chunk_lines(terrain_system, terrain_plugin.current_hovered_chunk, addchunk_material)
	else:
		for chunk_coords: Vector2i in terrain_system.chunks:
			for dir in range(6):
				try_add_chunk(terrain_system, chunk_coords + MSTHexMath.neighbor_offset(dir))
			try_add_chunk(terrain_system, chunk_coords)
	
	var pos : Vector3 = terrain_plugin.brush_position
	var cursor_chunk_coords : Vector2i
	var cursor_hex_coords : Vector2i
	
	if terrain_plugin.is_setting and not terrain_plugin.draw_height_set:
		terrain_plugin.draw_height_set = true
		
		var cursor_hex := MSTHexMath.world_to_hex(pos.x, pos.z, terrain_system.hex_size)
		cursor_chunk_coords = MSTHexMath.world_to_chunk(cursor_hex.x, cursor_hex.y, terrain_system.chunk_radius)
		cursor_hex_coords = MSTHexMath.hex_to_local(cursor_hex.x, cursor_hex.y, terrain_system.chunk_radius)
		
		# When setting, if there is no pattern and alt not held, go to draw mode
		var has_pattern : bool = not terrain_plugin.current_draw_pattern.is_empty()
		if not has_pattern and not Input.is_key_pressed(KEY_ALT):
			terrain_plugin.current_draw_pattern.clear()
			terrain_plugin.is_setting = false
			terrain_plugin.is_drawing = true
			terrain_plugin.draw_height = pos.y
		
		# Otherwise, drag that pattern's height
		else:
			# If alt held, ONLY drag the cursor hex
			if Input.is_key_pressed(KEY_ALT) and terrain_system.chunks.has(cursor_chunk_coords):
				var cursor_chunk : MarchingSquaresTerrainChunk = terrain_system.chunks[cursor_chunk_coords]
				terrain_plugin.current_draw_pattern.clear()
				terrain_plugin.current_draw_pattern[cursor_chunk_coords] = {}
				terrain_plugin.current_draw_pattern[cursor_chunk_coords][cursor_hex_coords] = cursor_chunk.get_elevation(cursor_hex_coords) * terrain_system.level_height
				terrain_plugin.draw_height = pos.y
			terrain_plugin.base_position = pos
	
	if terrain_plugin.is_drawing and not terrain_plugin.draw_height_set:
		terrain_plugin.draw_height_set = true
		terrain_plugin.draw_height = terrain_plugin.brush_position.y
	
	var terrain_chunk_hovered : bool = terrain_plugin.terrain_hovered
	
	# Check if we're in wall painting mode
	var is_wall_painting : bool = terrain_plugin.paint_walls_mode and terrain_plugin.mode == terrain_plugin.TerrainToolMode.VERTEX_PAINTING
	
	var hex_mesh := _get_brush_hex_mesh(terrain_system.hex_size)
	var hex_scale_basis := Basis()
	
	if terrain_chunk_hovered:
		# Brush radius visualization
		var brush_transform : Transform3D
		brush_transform = Transform3D(Vector3.RIGHT * terrain_plugin.brush_size, Vector3.UP, Vector3.BACK * terrain_plugin.brush_size, pos)
		
		if is_wall_painting:
			var viewport := EditorInterface.get_editor_viewport_3d()
			var editor_camera := viewport.get_camera_3d()
			var mouse_pos := viewport.get_mouse_position()
			
			var ray_origin := editor_camera.project_ray_origin(mouse_pos)
			var ray_dir := editor_camera.project_ray_normal(mouse_pos)
			
			var space := terrain_system.get_world_3d().direct_space_state
			var query := PhysicsRayQueryParameters3D.create(
				ray_origin,
				ray_origin + ray_dir * 10000.0
			)
			
			query.collide_with_areas = false
			query.collide_with_bodies = true
			var hit_result = space.intersect_ray(query)
			var wall_normal : Vector3 = Vector3.BACK
			if hit_result:
				wall_normal = hit_result.normal
			
			var basis := _create_brush_basis(wall_normal, terrain_plugin.brush_size)
			if wall_normal.y > 0.5:
				basis.z = Vector3.ZERO
			brush_transform = Transform3D(basis, pos)
		
		if terrain_plugin.mode == terrain_plugin.TerrainToolMode.VERTEX_PAINTING:
			if terrain_plugin.paint_walls_mode:
				add_mesh(terrain_plugin.BRUSH_RADIUS_VISUAL, null, brush_transform)
		elif terrain_plugin.mode != terrain_plugin.TerrainToolMode.SMOOTH and terrain_plugin.mode != terrain_plugin.TerrainToolMode.GRASS_MASK and terrain_plugin.mode != terrain_plugin.TerrainToolMode.DEBUG_BRUSH:
			add_mesh(terrain_plugin.BRUSH_RADIUS_VISUAL, null, brush_transform)
		
		pos = terrain_plugin.brush_position
		
		var brush_hexes : Dictionary = BrushPatternCalculator.hexes_in_brush(
			terrain_system, pos, terrain_plugin.brush_size, terrain_plugin.current_brush_index,
			terrain_plugin.falloff, terrain_plugin.falloff_curve
		)
		
		for brush_chunk_coords : Vector2i in brush_hexes:
			var chunk : MarchingSquaresTerrainChunk = terrain_system.chunks[brush_chunk_coords]
			var center := MSTHexMath.chunk_center(brush_chunk_coords.x, brush_chunk_coords.y, terrain_system.chunk_radius)
			var chunk_dict : Dictionary = brush_hexes[brush_chunk_coords]
			
			for local_hex : Vector2i in chunk_dict:
				var sample : float = chunk_dict[local_hex]
				var world_xz := MSTHexMath.hex_to_world(center.x + local_hex.x, center.y + local_hex.y, terrain_system.hex_size)
				
				var y : float
				if not terrain_plugin.current_draw_pattern.is_empty() and terrain_plugin.flatten:
					y = terrain_plugin.draw_height
				else:
					y = chunk.get_elevation(local_hex) * terrain_system.level_height
				
				hex_scale_basis = Basis().scaled(Vector3(sample, sample, sample))
				var draw_transform := Transform3D(hex_scale_basis, Vector3(world_xz.x, y, world_xz.y))
				# Only draw ground brush hexes if NOT in wall paint mode
				if not is_wall_painting:
					add_mesh(hex_mesh, brush_material, draw_transform)
				
				# Draw to current pattern
				if terrain_plugin.is_drawing:
					if not terrain_plugin.current_draw_pattern.has(brush_chunk_coords):
						terrain_plugin.current_draw_pattern[brush_chunk_coords] = {}
					if terrain_plugin.current_draw_pattern[brush_chunk_coords].has(local_hex):
						var prev_sample = terrain_plugin.current_draw_pattern[brush_chunk_coords][local_hex]
						if sample > prev_sample:
							terrain_plugin.current_draw_pattern[brush_chunk_coords][local_hex] = sample
					else:
						terrain_plugin.current_draw_pattern[brush_chunk_coords][local_hex] = sample
	
	var height_diff : float
	if terrain_plugin.is_setting and terrain_plugin.draw_height_set:
		height_diff = terrain_plugin.brush_position.y - terrain_plugin.draw_height
	
	if not terrain_plugin.current_draw_pattern.is_empty():
		for draw_chunk_coords : Vector2i in terrain_plugin.current_draw_pattern:
			var chunk = terrain_system.chunks[draw_chunk_coords]
			var center := MSTHexMath.chunk_center(draw_chunk_coords.x, draw_chunk_coords.y, terrain_system.chunk_radius)
			var draw_chunk_dict : Dictionary = terrain_plugin.current_draw_pattern[draw_chunk_coords]
			for draw_coords: Vector2i in draw_chunk_dict:
				var world_xz := MSTHexMath.hex_to_world(center.x + draw_coords.x, center.y + draw_coords.y, terrain_system.hex_size)
				var draw_y = terrain_plugin.draw_height if terrain_plugin.flatten else chunk.get_elevation(draw_coords) * terrain_system.level_height
				
				var sample : float = draw_chunk_dict[draw_coords]
				hex_scale_basis = Basis().scaled(Vector3(sample, sample, sample))
				
				# If setting, also show a hex at the height to set to
				if terrain_plugin.is_setting and terrain_plugin.draw_height_set:
					var draw_position := Vector3(world_xz.x, draw_y + height_diff * sample, world_xz.y)
					var draw_transform := Transform3D(hex_scale_basis, draw_position)
					if not is_wall_painting:
						add_mesh(hex_mesh, null, draw_transform)
				else:
					var draw_position := Vector3(world_xz.x, draw_y, world_xz.y)
					var draw_transform := Transform3D(hex_scale_basis, draw_position)
					if not is_wall_painting:
						add_mesh(hex_mesh, null, draw_transform)


func _create_brush_basis(normal: Vector3, brush_size: float) -> Basis:
	var n := normal.normalized()
	
	var tangent := Vector3.UP.cross(n)
	if tangent.length_squared() < 0.001:
		tangent = Vector3.RIGHT.cross(n)
	
	tangent = tangent.normalized()
	var bitangent := n.cross(tangent)
	
	tangent *= brush_size
	bitangent *= brush_size
	
	return Basis(tangent, n, bitangent)


# A 6-sided cylinder's ring vertices land exactly on pointy-top hex corners,
# so the prism matches the terrain's hexes with no extra rotation.
func _get_brush_hex_mesh(hex_size: float) -> CylinderMesh:
	if not brush_hex_mesh:
		brush_hex_mesh = CylinderMesh.new()
		brush_hex_mesh.radial_segments = 6
		brush_hex_mesh.rings = 0
	brush_hex_mesh.top_radius = hex_size
	brush_hex_mesh.bottom_radius = hex_size
	brush_hex_mesh.height = 1.0
	return brush_hex_mesh


func try_add_chunk(terrain_system: MarchingSquaresTerrain, coords: Vector2i):
	var terrain_plugin := MarchingSquaresTerrainPlugin.instance
	
	if Input.is_key_pressed(KEY_CTRL):
		return
	
	# Add chunk
	if (terrain_plugin.mode == terrain_plugin.TerrainToolMode.CHUNK_MANAGEMENT or Input.is_key_pressed(KEY_SHIFT)) and not terrain_system.chunks.has(coords) and terrain_plugin.is_chunk_plane_hovered and terrain_plugin.current_hovered_chunk == coords:
		add_chunk_lines(terrain_system, coords, addchunk_material)
	
	# Remove chunk (Manage Chunk tool only)
	elif terrain_plugin.mode == terrain_plugin.TerrainToolMode.CHUNK_MANAGEMENT and terrain_plugin.is_chunk_plane_hovered and terrain_plugin.current_hovered_chunk == coords:
		add_chunk_lines(terrain_system, coords, removechunk_material) 


# Draw chunk ui lines inside and around a chunk.
# The chunk outline is the hexagon through the outer corners of the chunk's hex shape:
# its corners sit at (2 * chunk_radius + 1) * hex_size from the chunk center.
func add_chunk_lines(terrain_system: MarchingSquaresTerrain, coords: Vector2i, material: Material):
	var center_hex := MSTHexMath.chunk_center(coords.x, coords.y, terrain_system.chunk_radius)
	var center_xz := MSTHexMath.hex_to_world(center_hex.x, center_hex.y, terrain_system.hex_size)
	var center := Vector3(center_xz.x, 0.0, center_xz.y)
	var outline_radius : float = (2 * terrain_system.chunk_radius + 1) * terrain_system.hex_size
	
	var corners : Array[Vector3] = []
	for dir in range(6):
		var corner_xz := MSTHexMath.hex_corner_offset(dir, outline_radius)
		corners.append(center + Vector3(corner_xz.x, 0.0, corner_xz.y))
	
	lines.clear()
	# The side between corner dir and corner dir+1 faces neighbor chunk direction dir
	for dir in range(6):
		if terrain_system.chunks.has(coords + MSTHexMath.neighbor_offset(dir)):
			continue
		lines.append(corners[dir])
		lines.append(corners[(dir + 1) % 6])
	
	if material == removechunk_material:
		lines.append(corners[0])
		lines.append(corners[3])
		lines.append(corners[1])
		lines.append(corners[4])
		lines.append(corners[2])
		lines.append(corners[5])
	
	if material == addchunk_material:
		var arm := outline_radius * 0.2
		lines.append(center + Vector3(-arm, 0, 0))
		lines.append(center + Vector3(arm, 0, 0))
		lines.append(center + Vector3(0, 0, -arm))
		lines.append(center + Vector3(0, 0, arm))
	
	if material == highlightchunk_material:
		for dir in range(6):
			lines.append(corners[dir])
			lines.append(corners[dir].lerp(corners[posmod(dir - 1, 6)], 0.15))
			lines.append(corners[dir])
			lines.append(corners[dir].lerp(corners[(dir + 1) % 6], 0.15))
	
	add_lines(lines, material, false)
