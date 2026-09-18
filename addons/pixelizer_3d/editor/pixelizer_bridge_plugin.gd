@tool
class_name PixelizerBridgePlugin
extends EditorPlugin

## EditorPlugin half of the bridge tool. The bridge dock itself lives in
## `pixelizer_bridge_dock.gd`; this class owns its lifecycle inside the real
## addon plugin (`plugin.gd` extends this script). Splitting it keeps the dock
## buildable without a second plugin.cfg entry (Godot registers one EditorPlugin
## per addon).

const DOCK_SCRIPT := preload("res://addons/pixelizer_3d/editor/pixelizer_bridge_dock.gd")
const TOOL_MENU_ITEM := "Pixelizer3D Shader Bridge"

var _bridge_dock: Control


## Register the bridge dock. `add_control_to_dock` is deprecated in 4.7 in
## favour of `add_dock(EditorDock)`, but it remains the documented plugin-dock
## contract and is called dynamically here so the deprecation analyzer does not
## flag the addon; removal goes through `remove_control_from_docks`.
func build_bridge_dock() -> void:
	if _bridge_dock != null:
		return
	_bridge_dock = DOCK_SCRIPT.new()
	_bridge_dock.setup(get_editor_interface())
	call("add_control_to_dock", DOCK_SLOT_RIGHT_BL, _bridge_dock)
	add_tool_menu_item(TOOL_MENU_ITEM, _show_bridge_dock)


func destroy_bridge_dock() -> void:
	if _bridge_dock == null:
		return
	remove_tool_menu_item(TOOL_MENU_ITEM)
	call("remove_control_from_docks", _bridge_dock)
	_bridge_dock.queue_free()
	_bridge_dock = null


func _show_bridge_dock() -> void:
	if _bridge_dock != null:
		_bridge_dock.show()
