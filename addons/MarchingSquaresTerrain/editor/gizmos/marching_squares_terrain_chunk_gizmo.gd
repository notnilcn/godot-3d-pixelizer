# This gizmo will have a handle for every hex in the chunk.
# Mostly for debugging.

extends EditorNode3DGizmo
class_name MarchingSquaresTerrainChunkGizmo


func _redraw():
	clear()
	
	var chunk : MarchingSquaresTerrainChunk = get_node_3d()
	
	# Only draw the gizmo if this is the only selected node
	if len(EditorInterface.get_selection().get_selected_nodes()) != 1:
		return
	if EditorInterface.get_selection().get_selected_nodes()[0] != chunk:
		return
	
	# Handles for raising/lowering terrain (one per hex, at hex centers)
	var hex_size := chunk.get_hex_size()
	var level_height := chunk.get_level_height()
	var corners := PackedVector3Array()
	var ids := PackedInt32Array()
	var offsets := MSTHexMath.hex_range(chunk.get_chunk_radius())
	for i in range(offsets.size()):
		var center_xz := MSTHexMath.hex_to_world(offsets[i].x, offsets[i].y, hex_size)
		corners.append(Vector3(center_xz.x, chunk.get_elevation(offsets[i]) * level_height, center_xz.y))
		ids.append(i)
	add_handles(corners, get_plugin().get_material("handles", self), ids)


func _get_handle_name(handle_id: int, secondary: bool) -> String:
	return str(handle_id);


func _get_handle_value(handle_id: int, secondary: bool) -> Variant:
	var chunk : MarchingSquaresTerrainChunk = get_node_3d()
	return chunk.get_elevation(_offset_for_handle(chunk, handle_id)) * chunk.get_level_height();


func _commit_handle(handle_id: int, secondary: bool, restore: Variant, cancel: bool) -> void:
	var chunk : MarchingSquaresTerrainChunk = get_node_3d()
	
	if cancel:
		move_terrain_point(chunk, handle_id, restore)
	else:
		var undo_redo := MarchingSquaresTerrainPlugin.instance.get_undo_redo()
		
		var do_value : float = chunk.get_elevation(_offset_for_handle(chunk, handle_id)) * chunk.get_level_height()
	
		undo_redo.create_action("move terrain point")
		undo_redo.add_do_method(self, "move_terrain_point", chunk, handle_id, do_value)
		undo_redo.add_undo_method(self, "move_terrain_point", chunk, handle_id, restore)
		undo_redo.commit_action()
		
	chunk.update_gizmos()


func move_terrain_point(chunk: MarchingSquaresTerrainChunk, handle_id: int, height: float):
	chunk.draw_elevation(_offset_for_handle(chunk, handle_id), int(round(height / chunk.get_level_height())))
	chunk.regenerate_mesh()
	chunk.update_gizmos()


# Handle ids index into the deterministic MSTHexMath.hex_range order.
func _offset_for_handle(chunk: MarchingSquaresTerrainChunk, handle_id: int) -> Vector2i:
	var offsets := MSTHexMath.hex_range(chunk.get_chunk_radius())
	if handle_id < 0 or handle_id >= offsets.size():
		return Vector2i.ZERO
	return offsets[handle_id]


func _set_handle(handle_id: int, secondary: bool, camera: Camera3D, screen_pos: Vector2) -> void:
	var chunk : MarchingSquaresTerrainChunk = get_node_3d()
	var offset := _offset_for_handle(chunk, handle_id)
	var hex_size := chunk.get_hex_size()
	var level_height := chunk.get_level_height()
	var center_xz := MSTHexMath.hex_to_world(offset.x, offset.y, hex_size)
	# Get handle position
	var handle_position = chunk.to_global(Vector3(center_xz.x, chunk.get_elevation(offset) * level_height, center_xz.y))
	
	# Convert mouse movement to 3D world coordinates using raycasting
	var ray_origin = camera.project_ray_origin(screen_pos)
	var ray_dir = camera.project_ray_normal(screen_pos)
	
	# We want the movement restricted to the Y-axis.
	# Create a plane that is parallel to the XZ plane (normal pointing along Y-axis)
	var plane = Plane(Vector3(ray_dir.x, 0, ray_dir.z), handle_position)
	var intersection = plane.intersects_ray(ray_origin, ray_dir)
	
	if intersection:
		intersection = chunk.to_local(intersection)
		chunk.draw_elevation(offset, int(round(intersection.y / level_height)))
		chunk.regenerate_mesh()
		chunk.update_gizmos()
