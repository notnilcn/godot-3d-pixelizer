class_name PixelizerOutlinePalette
extends Resource

## 256-row outline palette. Each edge tag has a silhouette (exterior) and an
## inner (id/depth edge) colour, plus a per-row opacity.
##
## Baked into a 256x2 RGBA8 texture where RGB is the outline colour and the
## alpha channel is an *opacity*: the apply pass composites
## `mix(scene_color, palette.rgb, palette.a)`. An opacity of 0 hides the outline
## (the scene is left untouched); 1 replaces it. This keeps colour and blend
## weight in separate channels instead of overloading alpha as a boolean
## multiply flag.

const ROW_COUNT := 256
const DEFAULT_COLOR := Color(0.04, 0.05, 0.09, 1.0)

@export var silhouette_colors: PackedColorArray
@export var inner_colors: PackedColorArray
## Per-row outline opacity in [0, 1]; 0 hides that row.
@export var silhouette_alpha: PackedFloat32Array
@export var inner_alpha: PackedFloat32Array


func _init() -> void:
	reset()


func reset() -> void:
	silhouette_colors.resize(ROW_COUNT)
	inner_colors.resize(ROW_COUNT)
	silhouette_alpha.resize(ROW_COUNT)
	inner_alpha.resize(ROW_COUNT)
	for i in ROW_COUNT:
		silhouette_colors[i] = DEFAULT_COLOR
		inner_colors[i] = DEFAULT_COLOR
		silhouette_alpha[i] = 1.0
		inner_alpha[i] = 1.0


func set_entry(id: int, silhouette: Color, inner: Color, silhouette_opacity: float = 1.0, inner_opacity: float = 1.0) -> void:
	if id < 0 or id >= ROW_COUNT:
		return
	silhouette_colors[id] = silhouette
	inner_colors[id] = inner
	silhouette_alpha[id] = silhouette_opacity
	inner_alpha[id] = inner_opacity


func set_silhouette_color(id: int, color: Color) -> void:
	if id < 0 or id >= ROW_COUNT:
		return
	silhouette_colors[id] = color


func get_silhouette_color(id: int) -> Color:
	if id < 0 or id >= ROW_COUNT:
		return DEFAULT_COLOR
	return silhouette_colors[id]


func bake_image() -> Image:
	var image := Image.create(ROW_COUNT, 2, false, Image.FORMAT_RGBA8)
	for i in ROW_COUNT:
		var silhouette: Color = silhouette_colors[i]
		var inner: Color = inner_colors[i]
		image.set_pixel(i, 0, Color(silhouette.r, silhouette.g, silhouette.b, clampf(silhouette_alpha[i], 0.0, 1.0)))
		image.set_pixel(i, 1, Color(inner.r, inner.g, inner.b, clampf(inner_alpha[i], 0.0, 1.0)))
	return image


func bake_texture() -> ImageTexture:
	return ImageTexture.create_from_image(bake_image())
