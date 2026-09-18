@tool
class_name PixelizerPaletteBaker
extends RefCounted

## Editor-callable palette baking. Registered by `plugin.gd` as the Tools >
## "Bake PaletteLUT to PNG" menu item; bakes whatever PaletteLUT resource
## is currently selected in the inspector. The resource also exposes a
## "Bake LUT" inspector button, so this is a convenience path for baking
## without opening the resource.

static func bake_edited_palette(editor_interface: EditorInterface) -> bool:
	if editor_interface == null:
		return false
	var edited = editor_interface.get_inspector().get_edited_object()
	if edited is PaletteLUT:
		(edited as PaletteLUT).save_lut_png()
		return true
	push_warning("Pixelizer3D: select a PaletteLUT resource in the inspector, then use Tools > Bake PaletteLUT to PNG.")
	return false
