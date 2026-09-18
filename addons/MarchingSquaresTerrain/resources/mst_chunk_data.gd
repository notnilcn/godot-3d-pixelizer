@tool
## chunk data for external storage with source data needed to reconstruct terrain at runtime.
class_name MSTChunkData
extends Resource


## Chunk coordinates in the chunk grid
@export var chunk_coords : Vector2i

## Hexes from the chunk center to its edge at save time
@export var chunk_radius : int

## Local axial offsets of each stored hex, interleaved q, r
@export var local_offsets : PackedInt32Array

## Elevation level per hex
@export var elevations : PackedInt32Array

## Ground texture slot (0-15) per hex
@export var ground_idx : PackedByteArray

## Wall texture slot (0-15) per hex
@export var wall_idx : PackedByteArray

## Grass flag per hex
@export var grass : PackedByteArray

## Packed 6x2-bit edge transitions per hex
@export var edges : PackedByteArray

# Ephemeral data saved for caching but regenerated on load if missing
@export var mesh : Mesh
@export var collision_faces : PackedVector3Array
@export var grass_multimesh : MultiMesh


## Helper to set collision from a ConcavePolygonShape3D
func set_collision_from_shape(shape: ConcavePolygonShape3D) -> void:
	if shape:
		collision_faces = shape.get_faces()


## Helper to create ConcavePolygonShape3D from stored collision data
func get_collision_shape() -> ConcavePolygonShape3D:
	if collision_faces.is_empty():
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(collision_faces)
	return shape


## Check if this is V3 hex format. V2 square-grid data is not migrated (hard format break).
func is_v3_format() -> bool:
	return local_offsets.size() == elevations.size() * 2
