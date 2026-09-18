class_name PixelizerObject3D
extends Node

## Manual per-object pixelizer configuration. Place one as a child of a
## supported GeometryInstance3D (MeshInstance3D / MultiMeshInstance3D /
## GPUParticles3D / CPUParticles3D) to override the applier's settings for that
## object. The applier never creates these automatically any more; without one,
## per-object state lives in an applier/manager-owned `PixelizerGeometryState`.
##
## Setter changes notify the owning applier (ancestor walk) or, outside an
## applier, the manager (`reconfigure_node`), which re-applies the state live.

## Anchor lattice mode. PER_OBJECT anchors each object's macro blocks to its
## own projected pivot (stable while moving); UNIFIED anchors them to the world
## origin so every object in a group lands on one common lattice.
enum AnchorMode { PER_OBJECT, UNIFIED }

## Editable live: disabling restores the authored materials/layers, re-enabling
## re-applies the pixelizer.
@export var enabled := true:
	set(value):
		enabled = value
		_notify_owner()
## Macro-pixel size in screen pixels (1-5). 1 disables the anchor clip.
@export_range(1, 5) var pixel_size := 3:
	set(value):
		pixel_size = value
		_notify_owner()
## Outline id (1-254); 255 is reserved for the focus subject.
@export var outline_id := -1:
	set(value):
		outline_id = value
		_notify_owner()
@export var outline_color := Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		outline_color = value
		_notify_owner()
## Register `outline_color` for this object's id in the manager's outline
## palette (the apply pass samples the palette, not the instance uniform).
@export var override_outline_color := false:
	set(value):
		override_outline_color = value
		_notify_owner()
## Per-object outline toggle: false hides this object's tag outline entirely.
@export var outline_enabled := true:
	set(value):
		outline_enabled = value
		_notify_owner()
## Per-object opt-out from the manager's palette LUT grading.
@export var palette_enabled := true:
	set(value):
		palette_enabled = value
		_notify_owner()
## Per-object anchor mode (see AnchorMode).
@export var anchor_mode: AnchorMode = AnchorMode.PER_OBJECT:
	set(value):
		anchor_mode = value
		_notify_owner()
## Per-object ordered-dither toggle (alpha dither + palette LUT dither band).
@export var dither_enabled := true:
	set(value):
		dither_enabled = value
		_notify_owner()
## Pixelized meshes are anchor-clipped, so their shadow maps contain only anchor
## dots; disable shadow casting until replicated-depth shadow support lands.
@export var disable_shadows := true:
	set(value):
		disable_shadows = value
		_notify_owner()

var _owner_applier: Node


## Node types this config can drive. Forwarding wrapper around
## `PixelizerGeometryState.is_supported_node` for compatibility.
static func is_supported_node(node: Node) -> bool:
	return PixelizerGeometryState.is_supported_node(node)


## Copy this config's fields onto a geometry state (applier/manager call this on
## bind and on every live setter notification).
func apply_to_state(state: PixelizerGeometryState) -> void:
	if state == null:
		return
	state.pixel_size = pixel_size
	state.outline_id = outline_id
	state.outline_color = outline_color
	state.override_outline_color = override_outline_color
	state.outline_enabled = outline_enabled
	state.palette_enabled = palette_enabled
	state.dither_enabled = dither_enabled
	state.anchor_mode = int(anchor_mode)
	state.disable_shadows = disable_shadows


func _exit_tree() -> void:
	_owner_applier = null


## Resolve the owning applier (ancestor walk, cached) and ask it to reconfigure
## the parent geometry; fall back to the manager when there is no applier.
func _notify_owner() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	var parent := get_parent()
	if parent == null or not (parent is GeometryInstance3D):
		return
	if _owner_applier == null or not is_instance_valid(_owner_applier):
		_owner_applier = _find_applier()
	if _owner_applier != null:
		_owner_applier.call("reconfigure", parent)
		return
	var manager := PixelizerManager3D.resolve_manager(self)
	if manager != null:
		manager.reconfigure_node(parent)


func _find_applier() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node is PixelizerApplier3D:
			return node
		node = node.get_parent()
	return null
