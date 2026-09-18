class_name PixelizerGeometryState
extends RefCounted

## Per-object pixelizer state for one GeometryInstance3D, owned by
## PixelizerApplier3D (or created explicitly by the manager registration APIs).
## Replaces the old auto-created PixelizerObject3D config node: no extra Node3D,
## no deferred `_apply` and no per-mesh `_process`.
##
## All four supported node types are handled through one `_material_slots()`
## iterator that yields `{source, apply, restore}` for every authored material
## slot; `bind`, `unbind`, `collect_materials`, `uses_unsupported_custom_material`
## and the bridge all iterate that one list.

const _KIND_MULTIMESH := 0
const _KIND_GPU_PARTICLES := 1
const _KIND_CPU_PARTICLES := 2

var target: GeometryInstance3D
var manager_ref: PixelizerManager3D

# Config (same names/defaults as PixelizerObject3D).
var pixel_size := 3
var outline_id := -1
var outline_color := Color(0.0, 0.0, 0.0, 1.0)
var override_outline_color := false
var outline_enabled := true
var palette_enabled := true
var dither_enabled := true
## 0 = PER_OBJECT, 1 = UNIFIED (mirrors PixelizerObject3D.AnchorMode).
var anchor_mode := 0
var disable_shadows := true

var _applied := false
var _slots: Array = []
var _original_layers := 0
var _original_shadow_casting := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
var _shadow_applied := false
## Material instance id -> the authored Shader, so `unbind` can undo the in-place
## bridge swap (the only mutation the bridge performs).
var _bridged_shaders: Dictionary = {}
var _bridge_swapped := false


func _init(p_target: GeometryInstance3D = null) -> void:
	target = p_target


## Node types PixelizerGeometryState can configure.
static func is_supported_node(node: Node) -> bool:
	return node is MeshInstance3D or node is MultiMeshInstance3D \
		or node is GPUParticles3D or node is CPUParticles3D


func is_applied() -> bool:
	return _applied


## True when a bridge swap happened for this target (keeps the applier watchdog
## armed, as in the old per-object watcher).
func bridge_swapped() -> bool:
	return _bridge_swapped


## True when there is nothing to inspect yet (MST chunks clear their mesh on save
## and rebuild at runtime). The applier keeps such targets watched.
func has_no_material_info() -> bool:
	return _material_slots().is_empty()


## Every authored material on `target` (override first, then surface materials,
## or the MultiMesh / particle draw-pass mesh materials).
func collect_materials() -> Array:
	var out: Array = []
	for slot in _material_slots():
		out.append(slot["source"])
	return out


## True when any current material is an unregistered custom shader. The whole
## node is then left untouched so the authored colours survive and the metadata
## camera is not polluted with un-encoded colours.
func uses_unsupported_custom_material() -> bool:
	for slot in _material_slots():
		if _is_unsupported_custom_material(slot["source"]):
			return true
	return false


## Apply this state: metadata layer, shadow setting, material conversion,
## instance uniforms and the bridge lookup. Returns false (leaving the node
## untouched) when there is nothing to inspect or an unapproved custom material is
## present.
func bind(manager: PixelizerManager3D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	manager_ref = manager
	_applied = false
	_bridge_swapped = false
	var slots := _material_slots()
	if slots.is_empty():
		return false
	# Manifest lookup first: approved bridges swap shaders into the authored
	# materials in place so they become recognized/convertible at runtime.
	refresh_bridge(manager_ref)
	for slot in slots:
		if _is_unsupported_custom_material(slot["source"]):
			return false
	var factory := manager_ref.get_material_factory()
	_original_layers = target.layers
	target.set_layer_mask_value(manager_ref.metadata_layer, true)
	_apply_shadow_setting()
	if outline_id < 0:
		outline_id = manager_ref.allocate_outline_id()
	for slot in slots:
		var source: Material = slot["source"]
		if _is_pixelizer_material(source, factory.shader):
			continue
		(slot["apply"] as Callable).call(factory.get_pixelizer_material(source))
	_slots = slots
	push_instance_params()
	_applied = true
	return true


## Undo `bind`: restore the authored shaders, materials, layers and shadow
## setting. Safe to call when not applied.
func unbind() -> void:
	if not _applied:
		return
	_applied = false
	for id in _bridged_shaders.keys():
		var material := instance_from_id(id)
		if material is ShaderMaterial and is_instance_valid(material):
			var authored: Shader = _bridged_shaders[id]
			if authored != null:
				(material as ShaderMaterial).shader = authored
	_bridged_shaders.clear()
	if target == null or not is_instance_valid(target):
		_slots = []
		return
	for slot in _slots:
		(slot["restore"] as Callable).call()
	_slots = []
	target.layers = _original_layers
	if _shadow_applied:
		target.cast_shadow = _original_shadow_casting
		_shadow_applied = false


## Push the current config to the target's instance uniforms (pixel size / id /
## colour changes are live). No-op until the state has applied.
func push_instance_params() -> void:
	if not _applied or target == null or not is_instance_valid(target):
		return
	target.set_instance_shader_parameter("anchor_size", pixel_size)
	target.set_instance_shader_parameter("anchor_tag", outline_id)
	target.set_instance_shader_parameter("edge_tint", outline_color)
	target.set_instance_shader_parameter("use_grade_lut", 1 if palette_enabled else 0)
	target.set_instance_shader_parameter("anchor_mode", int(anchor_mode))
	target.set_instance_shader_parameter("use_dither", 1 if dither_enabled else 0)
	# The apply pass draws outlines from the palette, so the per-object colour
	# override and the on/off toggle must be registered by id.
	if manager_ref != null and outline_id >= 0 and outline_id <= 254:
		if not outline_enabled:
			manager_ref.set_outline_enabled(outline_id, false)
		elif override_outline_color:
			manager_ref.set_outline_color(outline_id, outline_color)
		else:
			manager_ref.set_outline_enabled(outline_id, true)


## Manifest lookup only: swap already-approved, already-generated bridge shaders
## into the authored materials in place and register them. Returns true when a
## swap happened. Never generates source.
func refresh_bridge(manager: PixelizerManager3D) -> bool:
	if manager == null or not manager.auto_bridge_custom_shaders:
		return false
	var registry := manager.get_bridge_registry()
	var swapped := false
	for slot in _material_slots():
		var material = slot["source"]
		if not (material is ShaderMaterial):
			continue
		var shader_material := material as ShaderMaterial
		# A material already running a bridge-generated shader still counts as
		# bridged: sibling objects can share one swapped material and systems
		# like MST's runtime texture baker replace materials later.
		if registry.is_generated_shader(shader_material.shader):
			if not manager.is_pixelized_material(shader_material):
				manager.register_pixelized_material(shader_material)
			swapped = true
			continue
		if not _is_unsupported_custom_material(shader_material):
			continue
		var authored_shader := shader_material.shader
		if registry.apply(shader_material):
			if not _bridged_shaders.has(shader_material.get_instance_id()):
				_bridged_shaders[shader_material.get_instance_id()] = authored_shader
			manager.register_pixelized_material(shader_material)
			swapped = true
	_bridge_swapped = _bridge_swapped or swapped
	return swapped


# ── Single material-slot iterator ───────────────────────────────────────────

func _material_slots() -> Array:
	var slots: Array = []
	if target == null or not is_instance_valid(target):
		return slots
	var override := target.material_override
	if override != null:
		slots.append({
			"source": override,
			"apply": Callable(self, "_apply_override").bind(target),
			"restore": Callable(self, "_restore_override").bind(target, override),
		})
		return slots
	if target is MeshInstance3D:
		var mi := target as MeshInstance3D
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var existing := mi.get_surface_override_material(i)
				var source: Material = existing if existing != null else mesh.surface_get_material(i)
				slots.append({
					"source": source,
					"apply": Callable(self, "_apply_surface").bind(mi, i),
					"restore": Callable(self, "_restore_surface").bind(mi, i, existing),
				})
		return slots
	if target is MultiMeshInstance3D:
		var mmi := target as MultiMeshInstance3D
		if mmi.multimesh != null and mmi.multimesh.mesh != null:
			slots = _duplicated_mesh_slots(mmi.multimesh.mesh, _KIND_MULTIMESH, mmi)
		return slots
	if target is GPUParticles3D:
		var particles := target as GPUParticles3D
		# Only draw_pass_1: querying draw_pass_2..4 when unset logs an engine error.
		if particles.draw_pass_1 != null:
			slots = _duplicated_mesh_slots(particles.draw_pass_1, _KIND_GPU_PARTICLES, particles)
		return slots
	if target is CPUParticles3D:
		var cpu := target as CPUParticles3D
		if cpu.mesh != null:
			slots = _duplicated_mesh_slots(cpu.mesh, _KIND_CPU_PARTICLES, cpu)
		return slots
	return slots


## Mesh-level types (MultiMesh/particles) have no surface override API: the mesh
## is duplicated lazily on the first conversion and assigned back.
func _duplicated_mesh_slots(original_mesh: Mesh, kind: int, owner: Node) -> Array:
	var slots: Array = []
	var holder := [null]
	for i in original_mesh.get_surface_count():
		var source: Material = original_mesh.surface_get_material(i)
		slots.append({
			"source": source,
			"apply": Callable(self, "_apply_duplicated_surface").bind(holder, owner, kind, i, original_mesh),
			"restore": Callable(self, "_restore_duplicated_mesh").bind(owner, kind, original_mesh),
		})
	return slots


## Call arguments come first, bound arguments last: `Callable.bind()` appends its
## arguments after the call arguments.
func _apply_override(converted: Material, obj: GeometryInstance3D) -> void:
	if is_instance_valid(obj):
		obj.material_override = converted


func _restore_override(obj: GeometryInstance3D, original: Material) -> void:
	if is_instance_valid(obj):
		obj.material_override = original


func _apply_surface(converted: Material, mi: MeshInstance3D, index: int) -> void:
	if is_instance_valid(mi):
		mi.set_surface_override_material(index, converted)


func _restore_surface(mi: MeshInstance3D, index: int, original: Material) -> void:
	if is_instance_valid(mi):
		mi.set_surface_override_material(index, original)


func _apply_duplicated_surface(converted: Material, holder: Array, owner: Node, kind: int, index: int, original_mesh: Mesh) -> void:
	if holder[0] == null:
		var duplicate: Mesh = original_mesh.duplicate()
		holder[0] = duplicate
		_assign_mesh(owner, kind, duplicate)
	(holder[0] as Mesh).surface_set_material(index, converted)


func _restore_duplicated_mesh(owner: Node, kind: int, original_mesh: Mesh) -> void:
	if is_instance_valid(owner):
		_assign_mesh(owner, kind, original_mesh)


func _assign_mesh(owner: Node, kind: int, mesh: Mesh) -> void:
	match kind:
		_KIND_MULTIMESH:
			(owner as MultiMeshInstance3D).multimesh.mesh = mesh
		_KIND_GPU_PARTICLES:
			(owner as GPUParticles3D).draw_pass_1 = mesh
		_KIND_CPU_PARTICLES:
			(owner as CPUParticles3D).mesh = mesh


# ── Helpers ─────────────────────────────────────────────────────────────────

## Re-apply the shadow-casting override live (the config's `disable_shadows` may
## change after the state applied).
func apply_shadow_setting() -> void:
	_apply_shadow_setting()


func _apply_shadow_setting() -> void:
	if target == null or not is_instance_valid(target):
		return
	if disable_shadows:
		if not _shadow_applied:
			_original_shadow_casting = target.cast_shadow
			_shadow_applied = true
		target.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	elif _shadow_applied:
		target.cast_shadow = _original_shadow_casting
		_shadow_applied = false


## True for custom ShaderMaterials that never opted into the anchor pipeline via
## manager.register_pixelized_material(). Null and BaseMaterial3D are convertible.
func _is_unsupported_custom_material(material: Material) -> bool:
	if material == null:
		return false
	if material is ShaderMaterial:
		if manager_ref == null:
			return true
		return not _is_pixelizer_material(material, manager_ref.get_material_factory().shader)
	return false


func _is_pixelizer_material(material: Material, pixelizer_shader: Shader) -> bool:
	if not (material is ShaderMaterial):
		return false
	if manager_ref != null and manager_ref.is_pixelized_material(material):
		return true
	return (material as ShaderMaterial).shader == pixelizer_shader
