@tool
class_name BrushPatternCalculator

## Calculates which hexes fall within a brush and their falloff samples.
## Used by both plugin (for editing) and gizmo (for visualization).


## Axial bounding box of the brush circle in global hex coords, padded by one hex.
static func calculate_bounds(pos: Vector3, brush_size: float, terrain: MarchingSquaresTerrain) -> Dictionary:
	var reach : float = brush_size * 0.5 + terrain.hex_size
	var brush_pos := Vector2(pos.x, pos.z)
	var q_min := 0
	var q_max := 0
	var r_min := 0
	var r_max := 0
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var hex := MSTHexMath.world_to_hex(brush_pos.x + corner.x * reach, brush_pos.y + corner.y * reach, terrain.hex_size)
		q_min = mini(q_min, hex.x)
		q_max = maxi(q_max, hex.x)
		r_min = mini(r_min, hex.y)
		r_max = maxi(r_max, hex.y)
	return {"q_min": q_min - 1, "q_max": q_max + 1, "r_min": r_min - 1, "r_max": r_max + 1}


static func calculate_max_distance(brush_size: float, brush_index: int) -> float:
	var max_distance : float = brush_size / 2
	match brush_index:
		0: # Round brush
			max_distance *= max_distance
		1: # Square brush
			max_distance *= max_distance * 2
	return max_distance


static func calculate_falloff_sample(
	world_pos: Vector2,
	brush_pos: Vector2,
	brush_size: float,
	brush_index: int,
	max_distance: float,
	use_falloff: bool,
	falloff_curve: Curve
	) -> float:
	
	var distance_squared := brush_pos.distance_squared_to(world_pos)
	if distance_squared > max_distance:
		return -1.0  # Outside brush
	
	if not use_falloff:
		return 1.0
	
	var t : float
	match brush_index:
		0: # Round brush
			var d : float = (max_distance - distance_squared) / max_distance
			t = clamp(d, 0.0, 1.0)
		1: # Square brush
			var local := world_pos - brush_pos
			var uv := local / (brush_size * 0.5)
			var d : float = max(abs(uv.x), abs(uv.y))
			t = 1.0 - clamp(d, 0.2, 1.0)
	
	return falloff_curve.sample(clamp(t, 0.001, 0.999))


## World XZ position of a hex's center in global axial coords.
static func hex_to_world_pos(hex: Vector2i, terrain: MarchingSquaresTerrain) -> Vector2:
	return MSTHexMath.hex_to_world(hex.x, hex.y, terrain.hex_size)


## All hexes covered by the brush on existing chunks, sampled at hex centers.
## Returns chunk_coords → Dictionary of local axial offset → falloff sample.
static func hexes_in_brush(terrain: MarchingSquaresTerrain, center: Vector3, brush_size: float, brush_index: int, use_falloff: bool, falloff_curve: Curve) -> Dictionary:
	var brush_pos := Vector2(center.x, center.z)
	var max_distance := calculate_max_distance(brush_size, brush_index)
	var bounds := calculate_bounds(center, brush_size, terrain)
	var hexes : Dictionary = {}
	
	for q in range(bounds.q_min, bounds.q_max + 1):
		for r in range(bounds.r_min, bounds.r_max + 1):
			var sample := calculate_falloff_sample(
				MSTHexMath.hex_to_world(q, r, terrain.hex_size), brush_pos,
				brush_size, brush_index, max_distance, use_falloff, falloff_curve
			)
			if sample < 0:
				continue  # Outside brush
			var chunk_coords := MSTHexMath.world_to_chunk(q, r, terrain.chunk_radius)
			if not terrain.chunks.has(chunk_coords):
				continue
			if not hexes.has(chunk_coords):
				hexes[chunk_coords] = {}
			hexes[chunk_coords][MSTHexMath.hex_to_local(q, r, terrain.chunk_radius)] = sample
	
	return hexes
