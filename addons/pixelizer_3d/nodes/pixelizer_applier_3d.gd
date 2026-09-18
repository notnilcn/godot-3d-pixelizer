class_name PixelizerApplier3D
extends Node3D

## Subtree pixelizer. Every supported geometry node (MeshInstance3D,
## MultiMeshInstance3D, GPUParticles3D, CPUParticles3D) under this node is bound
## through a `PixelizerGeometryState`; a child `PixelizerObject3D` placed
## manually overrides the applier's settings for that object. A nested
## PixelizerApplier3D owns its own subtree (child appliers override the parent).
## Properties left at their inherit value (-1) take the nearest ancestor
## applier's value, or the manager's default.
##
## Runtime additions are picked up through `SceneTree.node_added` (filtered by
## `is_ancestor_of`) and drained in `_process`, so children finish `_ready`
## before they are bound. `rescan()` is a manual fallback.

@export var enabled := true
## -1 inherits from the parent applier or the manager default.
@export_range(-1, 5) var pixel_size := -1:
	set(value):
		pixel_size = value
		_refresh_children()
## Outline id shared by every mesh in this subtree (no internal seams); -1
## auto-allocates from the manager. 255 is reserved for the focus subject.
@export_range(-1, 254) var outline_id := -1:
	set(value):
		outline_id = value
		_refresh_children()
## Register `outline_color` for this subtree's id in the outline palette.
@export var override_outline_color := false:
	set(value):
		override_outline_color = value
		_refresh_children()
@export var outline_color := Color(0.04, 0.05, 0.09, 1.0):
	set(value):
		outline_color = value
		_refresh_children()
## -1 inherits (parent applier, then the manager's `outline_enabled`); 0 hides
## this subtree's screen-space outline entirely, 1 forces it on.
@export_range(-1, 1) var outline_enabled := -1:
	set(value):
		outline_enabled = value
		_refresh_children()
## -1 inherits from the parent applier or the manager default.
@export_range(-1, 1) var palette_enabled := -1:
	set(value):
		palette_enabled = value
		_refresh_children()
## -1 inherits from the parent applier or the manager default.
@export_range(-1, 1) var dither_enabled := -1:
	set(value):
		dither_enabled = value
		_refresh_children()
## -1 inherits; 0 = PER_OBJECT, 1 = UNIFIED (see PixelizerObject3D.AnchorMode).
@export_range(-1, 1) var anchor_mode := -1:
	set(value):
		anchor_mode = value
		_refresh_children()
## 0 = keep shadow casting, 1 = force off (the safe default for anchor-clipped
## meshes). -1 inherits.
@export_range(-1, 1) var shadow_casting := -1:
	set(value):
		shadow_casting = value
		_refresh_children()
## Opt-in periodic re-scan in seconds (0 disables). Covers nodes that move into
## the subtree without emitting `node_added` (rare).
@export_range(0.0, 10.0, 0.1) var rescan_interval := 0.0:
	set(value):
		rescan_interval = value
		if _ready_done:
			set_process(rescan_interval > 0.0)
## -1 inherits; 0 = off, 1 = snap this subtree's geometry onto the pixel lattice
## every frame (manager.register_mover). Orthographic cameras only.
@export_range(-1, 1) var mover_snap := -1:
	set(value):
		mover_snap = value
		_refresh_children()
## Skip subtrees whose root is in this group (lights, markers, custom content).
@export var ignore_group: StringName = &"pixelizer_ignore"

const BRIDGE_WATCH_INTERVAL := 0.25

var manager: PixelizerManager3D

## geometry instance id -> PixelizerGeometryState.
var _states: Dictionary = {}
## instance id -> state that needs the throttled bridge poll (nothing to inspect
## yet, or a bridge swap actually happened).
var _watch_ids: Dictionary = {}
## Nodes added under this applier this frame; drained in `_process` (after their
## `_ready`) so material registration in child `_ready` has run.
var _queue: Array = []
var _rescan_accum := 0.0
var _watch_elapsed := 0.0
var _ready_done := false
var _rescan_queued := false
## Resolved effective values, computed once per rescan so `_pixelize_geometry`
## does not re-walk the ancestor chain for every geometry node.
var _eff_pixel_size := 3
var _eff_palette_enabled := true
var _eff_dither_enabled := true
var _eff_anchor_mode := 0
var _eff_outline_enabled := true
var _eff_shadow_off := true
var _eff_mover_snap := false


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	var tree := get_tree()
	if tree != null and not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not enabled:
		return
	_find_manager()
	if manager == null:
		push_warning("Pixelizer3D: PixelizerApplier3D at %s found no PixelizerManager3D." % get_path())
		return
	if outline_id < 0:
		outline_id = manager.allocate_outline_id()
	_ready_done = true
	if override_outline_color:
		manager.set_outline_color(outline_id, outline_color)
	set_process(rescan_interval > 0.0)
	_resolve_effective()
	_scan(self)


func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)
	for state in _states.values():
		(state as PixelizerGeometryState).unbind()
	_states.clear()
	_watch_ids.clear()
	_queue.clear()


func _process(delta: float) -> void:
	if manager == null:
		set_process(false)
		return
	if rescan_interval > 0.0:
		_rescan_accum += delta
		if _rescan_accum >= rescan_interval:
			_rescan_accum = 0.0
			_scan(self)
	if not _queue.is_empty():
		var nodes: Array = _queue
		_queue = []
		for node in nodes:
			if is_instance_valid(node) and is_ancestor_of(node):
				_scan(node)
	if not _watch_ids.is_empty():
		_watch_elapsed += delta
		if _watch_elapsed >= BRIDGE_WATCH_INTERVAL:
			_watch_elapsed = 0.0
			_poll_bridge_watch()
	if _queue.is_empty() and _watch_ids.is_empty() and rescan_interval <= 0.0:
		set_process(false)


## Deferred by nature: node_added fires during tree entry; draining in `_process`
## preserves the old "children finish `_ready` before bind" ordering (important
## for fireflies / glow material registration).
func _on_node_added(node: Node) -> void:
	if not enabled or manager == null:
		return
	if node == self or not is_ancestor_of(node):
		return
	_queue.append(node)
	set_process(true)


## Re-configure live when an applier property changes after _ready. Coalesced:
## a burst of setters queues one deferred rescan instead of running a full
## subtree scan per setter.
func _refresh_children() -> void:
	if not _ready_done or manager == null or not is_inside_tree():
		return
	if _rescan_queued:
		return
	_rescan_queued = true
	call_deferred("_flush_rescan")


func _flush_rescan() -> void:
	_rescan_queued = false
	if not _ready_done or manager == null or not is_inside_tree():
		return
	rescan()


## Manual fallback: re-scans the subtree (the live watcher normally handles
## runtime additions). Nested appliers are re-derived too, so an inherited
## property change on this applier propagates down.
func rescan() -> void:
	if manager == null:
		return
	_resolve_effective()
	_scan(self)
	for child in get_children():
		if child is PixelizerApplier3D and child != self:
			(child as PixelizerApplier3D).rescan()


## Called by a manual `PixelizerObject3D` setter (and `manager.reconfigure_node`)
## to apply the config live.
func reconfigure(geometry: GeometryInstance3D) -> void:
	if manager == null or geometry == null or not is_instance_valid(geometry):
		return
	if not is_ancestor_of(geometry):
		return
	var id := geometry.get_instance_id()
	var state: PixelizerGeometryState = _states.get(id)
	if state == null:
		_queue.append(geometry)
		set_process(true)
		return
	var config := geometry.get_node_or_null("PixelizerObject3D") as PixelizerObject3D
	if config != null and not config.enabled:
		if state.is_applied():
			state.unbind()
		return
	if config != null:
		config.apply_to_state(state)
	else:
		_apply_effective_to_state(state)
	state.apply_shadow_setting()
	if state.is_applied():
		state.push_instance_params()
		_apply_mover(geometry)
		return
	if state.bind(manager):
		_apply_mover(geometry)
		return
	if state.has_no_material_info() or state.bridge_swapped():
		_watch_ids[id] = state
		set_process(true)
	_apply_mover(geometry)


## The state for `geometry`, or null when this applier does not own it.
func get_state(geometry: GeometryInstance3D) -> PixelizerGeometryState:
	if geometry == null:
		return null
	return _states.get(geometry.get_instance_id())


func _find_manager() -> void:
	manager = PixelizerManager3D.resolve_manager(self)


func _scan(root: Node) -> void:
	_prune_states()
	# The watcher hands entered children straight to `_scan`, so the skips the
	# child loop applies must also guard the entry point (nested appliers own
	# their subtree; ignored nodes stay untouched).
	if root != self:
		if root is PixelizerApplier3D or root is PixelizerObject3D:
			return
		if root is Node and root.is_in_group(ignore_group):
			return
	if PixelizerGeometryState.is_supported_node(root):
		_pixelize_geometry(root as GeometryInstance3D)
	for child in root.get_children():
		if child is PixelizerObject3D:
			continue
		if child is PixelizerApplier3D and child != self:
			continue
		if child is Node and child.is_in_group(ignore_group):
			continue
		_scan(child)


func _pixelize_geometry(instance: GeometryInstance3D) -> void:
	if manager == null:
		return
	var id := instance.get_instance_id()
	var state: PixelizerGeometryState = _states.get(id)
	if state == null:
		state = PixelizerGeometryState.new(instance)
		_states[id] = state
	var config := instance.get_node_or_null("PixelizerObject3D") as PixelizerObject3D
	if config != null:
		if not config.enabled:
			if state.is_applied():
				state.unbind()
			return
		config.apply_to_state(state)
	else:
		_apply_effective_to_state(state)
	if state.is_applied():
		state.apply_shadow_setting()
		state.push_instance_params()
		_apply_mover(instance)
		return
	if state.bind(manager):
		_apply_mover(instance)
		return
	if state.has_no_material_info() or state.bridge_swapped():
		_watch_ids[id] = state
		set_process(true)
	_apply_mover(instance)


func _apply_effective_to_state(state: PixelizerGeometryState) -> void:
	state.pixel_size = _eff_pixel_size
	state.outline_id = outline_id
	state.override_outline_color = override_outline_color
	state.outline_color = outline_color
	state.outline_enabled = _eff_outline_enabled
	state.palette_enabled = _eff_palette_enabled
	state.dither_enabled = _eff_dither_enabled
	state.anchor_mode = _eff_anchor_mode
	state.disable_shadows = _eff_shadow_off


func _apply_mover(instance: GeometryInstance3D) -> void:
	if manager == null:
		return
	if _eff_mover_snap:
		manager.register_mover(instance)
	else:
		manager.unregister_mover(instance)


## Throttled bridge poll over the watched states: retry the bind while there is
## nothing to inspect yet, and re-run the manifest lookup on already-applied
## states (MST's runtime texture baker swaps materials after the first bind).
func _poll_bridge_watch() -> void:
	var dead: Array = []
	for id in _watch_ids:
		var state: PixelizerGeometryState = _watch_ids[id]
		if state.target == null or not is_instance_valid(state.target):
			dead.append(id)
			continue
		if not state.is_applied():
			if state.bind(manager):
				continue
			if not (state.has_no_material_info() or state.bridge_swapped()):
				dead.append(id)
			continue
		state.refresh_bridge(manager)
	for id in dead:
		_watch_ids.erase(id)


## Drop states whose target was freed or left this subtree (restoring authored
## materials when it did).
func _prune_states() -> void:
	var dead: Array = []
	for id in _states:
		var state: PixelizerGeometryState = _states[id]
		var target := state.target
		if target == null or not is_instance_valid(target) or not is_ancestor_of(target):
			dead.append(id)
	for id in dead:
		var state: PixelizerGeometryState = _states[id]
		state.unbind()
		_states.erase(id)
		_watch_ids.erase(id)


# ── Inheritance resolution ───────────────────────────────────────────────────

## Resolve the inherited values once; `_apply_effective_to_state` reads these
## instead of re-walking the ancestor chain per node.
func _resolve_effective() -> void:
	_eff_pixel_size = get_effective_pixel_size()
	_eff_palette_enabled = get_effective_palette_enabled()
	_eff_dither_enabled = get_effective_dither_enabled()
	_eff_anchor_mode = get_effective_anchor_mode()
	_eff_outline_enabled = get_effective_outline_enabled()
	_eff_shadow_off = get_effective_shadow_off()
	_eff_mover_snap = get_effective_mover_snap()


func get_effective_pixel_size() -> int:
	if pixel_size > 0:
		return pixel_size
	var parent := _parent_applier()
	while parent != null:
		if parent.pixel_size > 0:
			return parent.pixel_size
		parent = parent._parent_applier()
	if manager != null:
		return manager.pixel_size
	return 3


func _parent_applier() -> PixelizerApplier3D:
	var node: Node = get_parent()
	while node != null:
		if node is PixelizerApplier3D:
			return node as PixelizerApplier3D
		node = node.get_parent()
	return null


## Nearest ancestor applier that explicitly sets a value, or the manager default.
func get_effective_palette_enabled() -> bool:
	if palette_enabled >= 0:
		return palette_enabled != 0
	var parent := _parent_applier()
	if parent != null:
		return parent.get_effective_palette_enabled()
	return true


func get_effective_dither_enabled() -> bool:
	if dither_enabled >= 0:
		return dither_enabled != 0
	var parent := _parent_applier()
	if parent != null:
		return parent.get_effective_dither_enabled()
	if manager != null:
		return manager.dither_enabled
	return true


func get_effective_anchor_mode() -> int:
	if anchor_mode >= 0:
		return anchor_mode
	var parent := _parent_applier()
	if parent != null:
		return parent.get_effective_anchor_mode()
	return PixelizerObject3D.AnchorMode.PER_OBJECT


## True when this subtree's tag draws a screen-space outline.
func get_effective_outline_enabled() -> bool:
	if outline_enabled >= 0:
		return outline_enabled != 0
	var parent := _parent_applier()
	if parent != null:
		return parent.get_effective_outline_enabled()
	if manager != null:
		return manager.outline_enabled
	return true


## True when this subtree's meshes should stop casting shadows.
func get_effective_shadow_off() -> bool:
	if shadow_casting >= 0:
		return shadow_casting != 0
	var parent := _parent_applier()
	if parent != null:
		return parent.get_effective_shadow_off()
	return true


## True when this subtree's geometry should be snapped as movers.
func get_effective_mover_snap() -> bool:
	if mover_snap >= 0:
		return mover_snap != 0
	var parent := _parent_applier()
	if parent != null:
		return parent.get_effective_mover_snap()
	if manager != null:
		return manager.mover_snap
	return false
