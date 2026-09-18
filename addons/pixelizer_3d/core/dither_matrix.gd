@tool
class_name DitherMatrix
extends Resource

## A 4x4 ordered dither threshold matrix, stored as 16 floats in [0, 1].
##
## The default values are generated from [method bayer_index] (the recursive
## Bayer construction) rather than pasted as a literal table, so the resource
## and the GLSL `anchor_bayer_index()` in `anchor_macros.gdshaderinc` share one
## algorithmic definition. Indexing is x-major: `index = 4 * (x % 4) + (y % 4)`.

const SIZE := 4

## 16 threshold values, x-major: `values[4 * x + y]`.
@export var values: PackedFloat32Array = _default_values():
	set(value):
		values = value
		if values.size() != 16:
			push_warning("DitherMatrix expects exactly 16 values (4x4).")
		emit_changed()


## The base 2x2 Bayer cell, indexed `(x, y)` -> value:
##   (0,0)=0  (0,1)=2  (1,0)=3  (1,1)=1
static func bayer2(x: int, y: int) -> int:
	if x == 0:
		return 0 if y == 0 else 2
	return 3 if y == 0 else 1


## Recursive 4x4 Bayer index in [0, 15] (`M4(x,y) = 4*M2(low) + M2(high)`).
static func bayer_index(x: int, y: int) -> int:
	return bayer2(x & 1, y & 1) * 4 + bayer2((x >> 1) & 1, (y >> 1) & 1)


## The default threshold table, generated in x-major order.
static func _default_values() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(16)
	for x in 4:
		for y in 4:
			out[4 * x + y] = float(bayer_index(x, y)) / 17.0
	return out


func dither_index(off_x: int, off_y: int) -> int:
	return 4 * posmod(off_x, 4) + posmod(off_y, 4)


## Returns true if the first colour should be picked for the given mix fraction
## at the given pattern index, i.e. threshold > fraction.
func pick_first(fraction: float, index: int) -> bool:
	if values.size() != 16:
		return true
	return values[clampi(index, 0, 15)] > fraction


## The classic 4x4 ordered dither pattern (values n/17).
static func ordered_4x4() -> DitherMatrix:
	return DitherMatrix.new()
