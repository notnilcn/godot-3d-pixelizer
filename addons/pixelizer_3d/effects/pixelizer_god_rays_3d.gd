class_name PixelizerGodRays3D
extends Node3D

## God-ray toggle. The ray pass itself is owned by the manager
## (`PixelizerManager3D.ray_pass` / `get_god_ray_pass()`); place this node in a
## scene to turn the rays on. A scene without it simply never enables rays.
##
## `enabled` mirrors `manager.get_god_ray_pass().rays_enabled`. For reproducible
## captures set `time_override >= 0` on the manager's `ray_pass`.

## Whether the rays render. Disabled is nearly free (the pass early-outs).
@export var enabled := false:
	set(value):
		enabled = value
		_push_enabled()

var _manager: PixelizerManager3D


func _ready() -> void:
	_manager = PixelizerManager3D.resolve_manager(self)
	if not _push_enabled():
		# The manager may create its pass after this node is ready (sibling
		# order); retry once the whole tree has finished entering.
		call_deferred("_push_enabled")


## Push `enabled` onto the manager's pass. Returns true when the manager pass
## existed (or when there is no manager, so no retry is needed).
func _push_enabled() -> bool:
	if _manager == null or not is_instance_valid(_manager):
		return true
	var god_pass := _manager.get_god_ray_pass()
	if god_pass == null:
		return false
	god_pass.rays_enabled = enabled
	return true
