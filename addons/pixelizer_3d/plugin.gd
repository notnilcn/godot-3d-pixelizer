@tool
extends "res://addons/pixelizer_3d/editor/pixelizer_bridge_plugin.gd"

## Pixelizer3D editor entry point. Inherits PixelizerBridgePlugin so
## `build_bridge_dock()` / `destroy_bridge_dock()` run on the registered plugin
## instance (the bridge dock adds itself via `add_control_to_dock`).

const PALETTE_BAKER := preload("res://addons/pixelizer_3d/editor/palette_baker.gd")
const BAKE_MENU_ITEM := "Bake PaletteLUT to PNG"


func _enter_tree() -> void:
	add_tool_menu_item(BAKE_MENU_ITEM, _bake_palette)
	build_bridge_dock()


func _exit_tree() -> void:
	remove_tool_menu_item(BAKE_MENU_ITEM)
	destroy_bridge_dock()


func _bake_palette() -> void:
	PALETTE_BAKER.bake_edited_palette(get_editor_interface())
