@tool
class_name PaletteLUT
extends Resource

## Bakes the 256x256 palette LUT used by the pixelizer material's colour
## grading.
##
## LUT layout (matches the runtime sampler in anchor_macros.gdshaderinc):
##   x = r + 16 * b      (r low nibble, b high nibble)
##   y = g + 16 * band   (band = ordered-dither pattern index 0..15)
## with r/g/b quantised to the 16 levels 0/15..15/15 (16^3 = 4096 input
## colours x 16 dither bands). Every texel stores one exact palette colour.
##
## Bake from the editor with the inspector button or Tools > "Bake PaletteLUT
## to PNG"; the demo also bakes at runtime through build_lut_image().
##
## Runtime only needs the baked texture (assigned to
## `PixelizerManager3D.global_palette_lut`); the match metric is bake-time only.

enum MatchMetric {
	NEAREST_RGB, ## Nearest palette colour in RGB space.
	NEAREST_HSV, ## Nearest in HSV space (squared terms).
	WEIGHTED_HSV, ## HSV, weighted by [member weights].
	WEIGHTED_HSV_SQUARED, ## HSV squared distance, weighted.
	NEAREST_VALUE, ## Nearest by Value after mapping input through [member brightness_curve].
	NEAREST_LAB, ## Nearest in CIE Lab space (CIE76, perceptually uniform).
}

const RESOLUTION := 16
const DITHER_PATTERN_SIZE := 16

## Source texture holding the palette colours (every distinct pixel is a swatch).
@export var source: Texture2D

@export var match_metric: MatchMetric = MatchMetric.NEAREST_HSV

## Weights for hue / saturation / brightness (WEIGHTED_HSV* metrics).
@export var weights := Vector3.ONE

## Maps input Value to comparison Value (NEAREST_VALUE only).
@export var brightness_curve: Curve

@export var use_ordered_dither := true

## Dither matrix used when baking the LUT bands.
@export var dither_matrix: DitherMatrix

## Where save_lut_png() writes the baked PNG.
@export_file("*.png") var output_path := "res://palette_LUT.png"

@export_tool_button("Bake LUT", "VisualShader") var bake_button := save_lut_png


## Builds a 1-row swatch texture from `colors` (convenience for demos/tests).
static func source_texture_from_colors(colors: PackedColorArray) -> ImageTexture:
	var image := Image.create_empty(maxi(colors.size(), 1), 1, false, Image.FORMAT_RGBA8)
	for i in colors.size():
		image.set_pixel(i, 0, colors[i])
	return ImageTexture.create_from_image(image)


## The distinct colours of `image`, indexed for nearest-colour matching.
class SwatchSet:
	var colors: Array[Color] = []
	# Feature vectors per metric, built once. Baking walks every swatch for each
	# of the 4096 input colours, so the per-metric conversion must not run inside
	# that loop; the cache makes it a per-bake cost.
	var _vectors: Dictionary = {}

	func _init(palette_image: Image) -> void:
		if palette_image == null:
			push_error("PaletteLUT: source texture has no image.")
			colors = [Color.MAGENTA]
			return
		var seen := {}
		for y in palette_image.get_height():
			for x in palette_image.get_width():
				var c: Color = palette_image.get_pixel(x, y)
				var key := c.to_rgba32()
				if not seen.has(key):
					seen[key] = true
					colors.append(c)
		if colors.is_empty():
			push_error("PaletteLUT: source texture has no pixels.")
			colors.append(Color.MAGENTA)

	# Rec.709 luma, used only to order the two dither colours darker -> lighter.
	static func _luma(c: Color) -> float:
		return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722

	# sRGB -> linear -> XYZ (sRGB D65) -> CIE Lab (CIE76, white point D65).
	static func _srgb_to_lab(c: Color) -> Vector3:
		var lin := Vector3(
			c.r / 12.92 if c.r <= 0.04045 else pow((c.r + 0.055) / 1.055, 2.4),
			c.g / 12.92 if c.g <= 0.04045 else pow((c.g + 0.055) / 1.055, 2.4),
			c.b / 12.92 if c.b <= 0.04045 else pow((c.b + 0.055) / 1.055, 2.4))
		var xyz := Vector3(
			0.4124564 * lin.x + 0.3575761 * lin.y + 0.1804375 * lin.z,
			0.2126729 * lin.x + 0.7151522 * lin.y + 0.0721750 * lin.z,
			0.0193339 * lin.x + 0.1191920 * lin.y + 0.9503041 * lin.z)
		xyz /= Vector3(0.95047, 1.0, 1.08883)
		var f := Vector3(
			pow(xyz.x, 1.0 / 3.0) if xyz.x > 0.008856 else (xyz.x / 0.128418) + 0.137931,
			pow(xyz.y, 1.0 / 3.0) if xyz.y > 0.008856 else (xyz.y / 0.128418) + 0.137931,
			pow(xyz.z, 1.0 / 3.0) if xyz.z > 0.008856 else (xyz.z / 0.128418) + 0.137931)
		return Vector3(116.0 * f.y - 16.0, 500.0 * (f.x - f.y), 200.0 * (f.y - f.z))

	# The comparison vector for a colour under `metric`. Extracting features
	# once turns the per-metric if/else chain into the single distance routine
	# below.
	func _vector(c: Color, metric: MatchMetric, curve: Curve) -> Vector3:
		match metric:
			MatchMetric.NEAREST_RGB:
				return Vector3(c.r, c.g, c.b)
			MatchMetric.NEAREST_LAB:
				return _srgb_to_lab(c)
			MatchMetric.NEAREST_VALUE:
				var v := _luma(c)
				if curve != null:
					v = curve.sample(clampf(v, 0.0, 1.0))
				return Vector3(v, 0.0, 0.0)
			_:
				return Vector3(c.h, c.s, c.v)

	# Cached per-swatch feature vectors. A NEAREST_VALUE curve is a bake-time
	# input, not part of the metric id, so that variant is not cached.
	func _swatch_vectors(metric: MatchMetric, curve: Curve) -> Array:
		if metric == MatchMetric.NEAREST_VALUE and curve != null:
			var curved: Array = []
			for c in colors:
				curved.append(_vector(c, metric, curve))
			return curved
		var key := int(metric)
		if not _vectors.has(key):
			var built: Array = []
			for c in colors:
				built.append(_vector(c, metric, curve))
			_vectors[key] = built
		return _vectors[key]

	# Hue is circular, so its delta is the short way around the wheel.
	static func _hue_delta(h: float) -> float:
		var d := absf(h)
		return minf(d, 1.0 - d)

	func _gap(a: Vector3, b: Vector3, metric: MatchMetric, p_weights: Vector3) -> float:
		var d := a - b
		match metric:
			MatchMetric.NEAREST_RGB, MatchMetric.NEAREST_LAB:
				return d.length_squared()
			MatchMetric.NEAREST_VALUE:
				return absf(d.x)
			MatchMetric.NEAREST_HSV:
				var hd := _hue_delta(d.x)
				return hd * hd + d.y * d.y + d.z * d.z
			MatchMetric.WEIGHTED_HSV:
				return p_weights.x * _hue_delta(d.x) + p_weights.y * absf(d.y) + p_weights.z * absf(d.z)
			MatchMetric.WEIGHTED_HSV_SQUARED:
				var hd := _hue_delta(d.x)
				return p_weights.x * hd * hd + p_weights.y * d.y * d.y + p_weights.z * d.z * d.z
		return 0.0

	## The two closest swatches of `input` ([closest, second_closest]).
	func closest_pair(input: Color, p_metric: MatchMetric, p_weights: Vector3, curve: Curve) -> Array:
		var input_vec := _vector(input, p_metric, curve)
		var vectors := _swatch_vectors(p_metric, curve)
		var best := 0
		var best_gap := INF
		for i in vectors.size():
			var d: float = _gap(input_vec, vectors[i], p_metric, p_weights)
			if d < best_gap:
				best_gap = d
				best = i
		var second := best
		var second_gap := INF
		for i in vectors.size():
			if i == best:
				continue
			var d: float = _gap(input_vec, vectors[i], p_metric, p_weights)
			if d < second_gap:
				second_gap = d
				second = i
		return [colors[best], colors[second]]

	# Which metrics compare on the (circular) hue channel.
	static func _uses_hue(metric: MatchMetric) -> bool:
		return metric == MatchMetric.NEAREST_HSV \
			or metric == MatchMetric.WEIGHTED_HSV \
			or metric == MatchMetric.WEIGHTED_HSV_SQUARED

	# Wrap a delta into [-0.5, 0.5).
	static func _wrap_half(d: float) -> float:
		return d - floor(d + 0.5)

	# The best A->B mix fraction for `input`: the closed-form projection of the
	# input onto the A-B segment of the metric's feature space (the optimum of
	# the squared error, not a scan of candidate fractions). Hue is unwrapped
	# onto the short arc before projecting.
	func _mix_fraction(input: Color, a: Color, b: Color, metric: MatchMetric, curve: Curve) -> float:
		var x := _vector(input, metric, curve)
		var av := _vector(a, metric, curve)
		var bv := _vector(b, metric, curve)
		if _uses_hue(metric):
			bv.x = av.x + _wrap_half(bv.x - av.x)
			x.x = av.x + _wrap_half(x.x - av.x)
		var ab := bv - av
		var denom := ab.dot(ab)
		if denom <= 1e-12:
			return 0.0
		return clampf((x - av).dot(ab) / denom, 0.0, 1.0)

	## Band-independent part of a LUT entry: [closest, color_a, color_b,
	## best_fraction]. A is the darker of the two-most-similar swatches, and
	## best_fraction is the A->B mix that best reproduces `input`. The dither
	## band only decides the final A/B pick, so this is computed once per input
	## colour (not once per band).
	func solve_entry(input: Color, p_metric: MatchMetric, p_weights: Vector3, curve: Curve) -> Array:
		var both := closest_pair(input, p_metric, p_weights, curve)
		var closest: Color = both[0]
		var c_a: Color = both[0]
		var c_b: Color = both[1]
		if _luma(c_b) < _luma(c_a):
			c_a = both[1]
			c_b = both[0]
		var fraction := _mix_fraction(input, c_a, c_b, p_metric, curve)
		return [closest, c_a, c_b, round(fraction * 15.0) / 15.0]


## Builds the LUT into a new 256x256 RGBA8 image (no file I/O; runtime-friendly).
## Returns null on failure.
func build_lut_image() -> Image:
	if source == null:
		push_error("PaletteLUT: assign a source texture before baking.")
		return null
	var source_image := source.get_image()
	if source_image == null:
		push_error("PaletteLUT: could not read source texture.")
		return null
	var swatches := SwatchSet.new(source_image)
	var matrix: DitherMatrix = dither_matrix if use_ordered_dither else null

	# Per-input-colour entries, indexed r + 16*g + 256*b (band-independent).
	const CELLS := RESOLUTION * RESOLUTION * RESOLUTION
	var entry_closest := PackedColorArray()
	var entry_a := PackedColorArray()
	var entry_b := PackedColorArray()
	var entry_fraction := PackedFloat32Array()
	entry_closest.resize(CELLS)
	entry_a.resize(CELLS)
	entry_b.resize(CELLS)
	entry_fraction.resize(CELLS)
	for b in RESOLUTION:
		for g in RESOLUTION:
			for r in RESOLUTION:
				var original := Color(r / float(RESOLUTION), g / float(RESOLUTION), b / float(RESOLUTION), 1.0)
				var entry := swatches.solve_entry(original, match_metric, weights, brightness_curve)
				var index := r + g * RESOLUTION + b * RESOLUTION * RESOLUTION
				entry_closest[index] = entry[0]
				entry_a[index] = entry[1]
				entry_b[index] = entry[2]
				entry_fraction[index] = entry[3]

	var generated := Image.create_empty(RESOLUTION * RESOLUTION, RESOLUTION * DITHER_PATTERN_SIZE, false, Image.FORMAT_RGBA8)
	for band in DITHER_PATTERN_SIZE:
		for b in RESOLUTION:
			var offset := b * RESOLUTION
			for g in RESOLUTION:
				for r in RESOLUTION:
					var index := r + g * RESOLUTION + b * RESOLUTION * RESOLUTION
					var color: Color = entry_closest[index]
					if matrix != null:
						color = entry_a[index] if matrix.pick_first(entry_fraction[index], band) else entry_b[index]
					generated.set_pixel(r + offset, g + band * RESOLUTION, color)
	return generated


## Bakes the LUT and writes it to [member output_path] (editor path).
func save_lut_png() -> void:
	var generated := build_lut_image()
	if generated == null:
		return
	var err := generated.save_png(output_path)
	if err != OK:
		push_error("PaletteLUT: failed to save LUT to %s (error %d)." % [output_path, err])
		return
	print("PaletteLUT: LUT saved to %s" % output_path)
	# Reimport through the editor filesystem when running as a @tool script.
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		var editor_interface = Engine.get_singleton("EditorInterface")
		if editor_interface != null:
			editor_interface.get_resource_filesystem().scan()
