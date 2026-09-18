@tool
extends RefCounted
class_name MSTJsonIO
## Versioned JSON export/import of hex terrain.
## Uses absolute axial coords (chunk-agnostic, directly consumable server-side).


const FORMAT : String = "mst-hex-terrain"
const VERSION : int = 1


## Export the terrain's hexes to a JSON file. Returns the number of chunks written, or -1 on error.
static func export_to_json(terrain: MarchingSquaresTerrain, path: String, chunk_filter = null) -> int:
	var chunks_array : Array = []
	for chunk_coords in terrain.chunks:
		if chunk_filter != null and not chunk_coords in chunk_filter:
			continue
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[chunk_coords]
		var center := MSTHexMath.chunk_center(chunk_coords.x, chunk_coords.y, terrain.chunk_radius)
		
		var hexes_array : Array = []
		for local_hex in chunk.hex_data:
			var record : Dictionary = chunk.hex_data[local_hex]
			var hex_dict : Dictionary = {}
			# Absolute axial coords, stable key order
			hex_dict["q"] = center.x + local_hex.x
			hex_dict["r"] = center.y + local_hex.y
			# Per-hex defaults are omitted to keep files diff-friendly
			var elevation : int = record.get("elevation", 0)
			var ground : int = record.get("ground", 0)
			var wall : int = record.get("wall", 0)
			var grass : bool = record.get("grass", false)
			var edges : int = record.get("edges", 0)
			if elevation != 0:
				hex_dict["elevation"] = elevation
			if ground != 0:
				hex_dict["ground"] = ground
			if wall != terrain.default_wall_texture:
				hex_dict["wall"] = wall
			if grass:
				hex_dict["grass"] = true
			if edges != 0:
				# 6 edge kinds in server neighbor-delta order
				var edges_array : Array = []
				for dir in range(6):
					edges_array.append(MarchingSquaresTerrainChunk.get_edge_kind(edges, dir))
				hex_dict["edges"] = edges_array
			hexes_array.append(hex_dict)
		
		hexes_array.sort_custom(func(a, b): return a.r < b.r if a.q == b.q else a.q < b.q)
		chunks_array.append({"chunk": [chunk_coords.x, chunk_coords.y], "hexes": hexes_array})
	
	chunks_array.sort_custom(func(a, b): return a.chunk[1] < b.chunk[1] if a.chunk[0] == b.chunk[0] else a.chunk[0] < b.chunk[0])
	
	# Advisory slot mapping so consumers can map slot ints to their own texture ids
	var texture_slots : Dictionary = {}
	for i in range(15):
		var tex : Texture2D = terrain.get("texture_" + str(i + 1))
		if tex and not tex.resource_path.is_empty():
			texture_slots[str(i)] = tex.resource_path
	
	var data : Dictionary = {
		"format": FORMAT,
		"version": VERSION,
		"settings": {
			"hex_size": terrain.hex_size,
			"level_height": terrain.level_height,
			"chunk_radius": terrain.chunk_radius,
			"orientation": "pointy-top",
			"axes": "axial q=+x, r=+z (server convention)",
			"texture_preset": terrain.current_texture_preset.preset_name if terrain.current_texture_preset else "",
		},
		"texture_slots": texture_slots,
		"chunks": chunks_array,
	}
	
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("MSTJsonIO: Failed to open " + path + " for writing: " + error_string(FileAccess.get_open_error()))
		return -1
	file.store_string(JSON.stringify(data, "  "))
	file.close()
	print("MSTJsonIO: Exported ", chunks_array.size(), " chunk(s) to ", ProjectSettings.globalize_path(path))
	return chunks_array.size()


## Import hexes from a JSON file into the terrain. Hexes are bucketed into chunks by
## absolute axial coord, so an unknown chunk_radius in the file is fine. Only hexes
## present in the file are written (a restore, not a merge): records they replace are
## overwritten, hexes the file doesn't mention keep their current records. Re-import
## is idempotent. Missing chunks are created through the undo-aware add path when a
## plugin is provided, or directly otherwise.
static func import_from_json(terrain: MarchingSquaresTerrain, path: String, plugin = null) -> Error:
	if not FileAccess.file_exists(path):
		push_error("MSTJsonIO: File not found: " + path)
		return ERR_FILE_NOT_FOUND
	
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return FileAccess.get_open_error()
	var text := file.get_as_text()
	file.close()
	
	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("MSTJsonIO: JSON parse error in " + path + " at line " + str(json.get_error_line()))
		return ERR_PARSE_ERROR
	if not json.data is Dictionary:
		push_error("MSTJsonIO: Root of " + path + " is not a JSON object")
		return ERR_INVALID_DATA
	var data : Dictionary = json.data
	if data.get("format", "") != FORMAT:
		push_error("MSTJsonIO: " + path + " is not a " + FORMAT + " file")
		return ERR_INVALID_DATA
	if int(data.get("version", 0)) != VERSION:
		push_error("MSTJsonIO: Unsupported version " + str(data.get("version")) + " in " + path)
		return ERR_INVALID_DATA
	
	var created_count := 0
	var hex_count := 0
	var affected_chunks : Dictionary = {}
	for chunk_entry in data.get("chunks", []):
		for hex_entry in chunk_entry.get("hexes", []):
			var q : int = hex_entry.get("q", 0)
			var r : int = hex_entry.get("r", 0)
			var chunk_coords := MSTHexMath.world_to_chunk(q, r, terrain.chunk_radius)
			if not terrain.chunks.has(chunk_coords):
				if plugin:
					plugin.get_undo_redo().create_action("import add chunk")
					plugin.get_undo_redo().add_do_method(terrain, "add_new_chunk", chunk_coords.x, chunk_coords.y, plugin)
					plugin.get_undo_redo().add_undo_method(terrain, "remove_chunk", chunk_coords.x, chunk_coords.y, plugin)
					plugin.get_undo_redo().commit_action()
				else:
					terrain.add_new_chunk(chunk_coords.x, chunk_coords.y, null)
				created_count += 1
			
			var chunk : MarchingSquaresTerrainChunk = terrain.chunks[chunk_coords]
			var local := MSTHexMath.hex_to_local(q, r, terrain.chunk_radius)
			var record := {
				"elevation": int(hex_entry.get("elevation", 0)),
				"ground": int(hex_entry.get("ground", 0)),
				"wall": int(hex_entry.get("wall", terrain.default_wall_texture)),
				"grass": bool(hex_entry.get("grass", false)),
				"edges": 0,
			}
			if hex_entry.has("edges"):
				var edges_array : Array = hex_entry["edges"]
				var edges := 0
				for dir in range(mini(edges_array.size(), 6)):
					edges = MarchingSquaresTerrainChunk.set_edge_kind(edges, dir, int(edges_array[dir]))
				record["edges"] = edges
			
			chunk.hex_data[local] = record
			chunk.mark_dirty()
			affected_chunks[chunk_coords] = chunk
			hex_count += 1
	
	for chunk in affected_chunks.values():
		chunk.regenerate_mesh()
	
	print("MSTJsonIO: Imported ", hex_count, " hex(es) from ", path, " (", created_count, " chunk(s) created, ", affected_chunks.size(), " chunk(s) regenerated)")
	return OK
