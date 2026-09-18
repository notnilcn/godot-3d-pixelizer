class_name PixelizerManager3D
extends Node3D

## Pixelizer3D pipeline driver. Owns the metadata SubViewport + camera, attaches
## the compositor effects to the target Camera3D, exposes the pipeline settings,
## and keeps the metadata camera in sync.
##
## Place one per world, point `camera` at the Camera3D to pixelize, and put a
## PixelizerApplier3D around any subtree that should be pixelized.

enum Mode { ANCHOR, LOW_RES }

@export_group("General")
@export var enabled := true
@export var mode: Mode = Mode.ANCHOR:
	set(value):
		if mode == value:
			return
		mode = value
		if is_inside_tree():
			_apply_mode()
## Directional light used by cloud shadows / god rays (wired in later phases).
@export var sun: DirectionalLight3D
@export_group("Resolution")
## Fixed render resolution (low-res mode) and scale reference. Also
## published as the `PixelizerGlobals.SCREEN_SIZE` global shader uniform (vec2)
## used by screen-space projection materials, so they lock to the render pixel
## grid instead of the window resolution.
@export var render_resolution := Vector2i(960, 540):
	set(value):
		render_resolution = value
		PixelizerGlobals.set_param(PixelizerGlobals.SCREEN_SIZE, Vector2(render_resolution))
## World texels per world unit (0.5 -> ortho width 1920).
@export var texel_density := 0.5
## Renderer-owned zoom on top of the configured scale.
@export var view_zoom := 1.0
## When true the manager drives `camera.size` from the resolution model (and
## zoom). Leave false when the project owns the camera size itself.
@export var manage_camera_size := false

@export_group("Pixelization")
## Default macro-pixel size for appliers/objects that inherit.
@export_range(1, 5) var pixel_size := 3
## Keep pixels in front of their anchor (non-pixelized geometry in front of a
## pixelized object is not smeared by the block).
@export var depth_occlusion := true
## Default for appliers that inherit (`mover_snap == -1`): snap registered
## movers onto the pixel lattice in the vertex stage via the `anchor_mover_snap`
## instance uniform. The scene transform is never read or written. Explicit
## `PixelizerApplier3D.mover_snap` wins. Orthographic cameras only.
@export var mover_snap := false

@export_group("Palette")
## 256x256 palette LUT baked by PaletteLUT (16^3 colours x 16 dither bands).
## Null disables grading. The property name is the main-client contract:
## PixelArtPipelineComponent probes the property list and pushes its LUT here —
## do not rename it.
@export var global_palette_lut: Texture2D:
	set(value):
		global_palette_lut = value
		_palette_dirty = true
## Use the LUT's 16 ordered-dither bands (Bayer in macro-pixel space). When
## false every fragment reads band 0, i.e. the nearest palette colour.
@export var dither_enabled := true:
	set(value):
		dither_enabled = value
		_palette_dirty = true

@export_group("Camera")
## Snap the camera to the texel lattice via h_offset/v_offset (never transforms).
@export var snap_camera := true
## Phase origin for the snap; world origin is used when unset.
@export var snap_origin: Node3D
## Disable snapping (diagnostics / regression captures).
@export var lock_camera := false

@export_group("Outlines")
@export var outline_enabled := true
@export var outline_color := Color(0.04, 0.05, 0.09, 1.0)
## Relative depth discontinuity that counts as an inner edge.
@export_range(0.0, 1.0, 0.001) var outline_threshold := 0.02
## Optional 256-tag palette (silhouette/inner rows). Per-applier colours are
## registered into a working copy of this palette at runtime.
@export var outline_palette: PixelizerOutlinePalette

@export_group("Focus")
## Automatically focus every pixelized mesh under `auto_focus_target`. Focus maps
## an instance uniform onto edge tag 255 (reserved) without overwriting
## `anchor_tag`; focused pixels are exempt from future smooth-scroll shifts.
@export var auto_focus := false
@export var auto_focus_target: Node3D
@export_range(1.0, 8.0, 0.5) var focus_dilate := 2.0
@export var debug_focus_mask := false

@export_group("Metadata")
## Rendering layer reserved for the metadata camera (1-20).
@export_range(1, 20) var metadata_layer := 20
## The manager must sync the metadata camera after camera hosts (PhantomCamera
## Host runs at 300); 301 is the default.
@export var sync_process_priority := 301

@export_group("Shader Bridge")
## Manifests of approved bridge entries (see the Pixelizer3D bridge dock). The
## registry maps each approved, non-stale source shader to a pre-generated
## `.gdshader`; runtime only performs a lookup + in-place shader swap. There is
## no runtime source generation.
@export var bridge_manifests: Array[PixelizerBridgeManifest] = []:
	set(value):
		bridge_manifests = value
		if is_node_ready():
			_rebuild_bridge_registry()
## Safety switch: when false (default) custom ShaderMaterials are left exactly as
## authored, even if a manifest entry is approved. Enable to let objects swap in
## their pre-generated bridge shader. Only approved, non-stale entries apply.
@export var auto_bridge_custom_shaders := false

@export_group("God Rays")
## Authored god-ray pass. When unset the manager creates a disabled pass. The
## pass always sits at index 0 of the compositor array and early-outs while
## `rays_enabled == false`. Tune it here, or through `get_god_ray_pass()` (the
## external property-name contract).
@export var ray_pass: PixelizerGodRayEffect

@export_group("Debug")
## 0 = normal, 1 = anchor map, 2 = metadata, 3 = linear depth, 4 = colour copy,
## 5 = shifted sample without occlusion, 6 = depth flags, 7/8 = raw depth,
## 9 = revert flag comparison (normal vs y-flipped depth lookup).
@export_range(0, 9) var debug_view := 0

var metadata_bit := 0

var _metadata_viewport: SubViewport
var _metadata_camera: Camera3D
var _metadata_environment: Environment
var _metadata_texture_rd := RID()
var _metadata_texture_source := RID()
var _compositor: Compositor
var _god_ray_effect: PixelizerGodRayEffect
var _snapshot_effect: PixelizerSnapshotEffect
var _apply_effect: PixelizerApplyPixelizationEffect
var _material_factory: PixelizerMaterialFactory
var _rd_warned := false
## Optional explicit override set with `set_target_camera()`.
var _target_camera: Camera3D = null
## Camera resolved this frame (override -> viewport current).
var _active_camera: Camera3D = null
## Camera currently carrying the compositor / metadata cull-mask change.
var _bound_camera: Camera3D = null
## Fields saved from `_saved_camera` at bind time; restored once on unbind so a
## camera the manager did not author comes back exactly as it was.
var _saved_camera: Camera3D = null
var _saved_cull_mask := 0
var _saved_compositor: Compositor
var _saved_h_offset := 0.0
var _saved_v_offset := 0.0
var _saved_size := 0.0
## True when the manager may write `_saved_camera.size` (manage_camera_size);
## only then is the size restored on unbind.
var _saved_size_managed := false
var _next_outline_id := 1
var _working_palette: PixelizerOutlinePalette
var _outline_texture: ImageTexture
var _outline_dirty := true
## Focused GeometryInstance3D nodes (id -> node); used for the diagnostics count.
var _focused: Dictionary = {}
var _auto_focused_target_id := 0
var _focus_rescan_counter := 0
var _perspective_warned := false
## Last snap remainder in texels ((-0.5, 0.5]); consumed by smooth scroll.
var subtexel_remainder := Vector2.ZERO

const LOWRES_UPSCALE_SHADER := "res://addons/pixelizer_3d/shaders/pixelizer_upscale.gdshader"

var _lowres_layer: CanvasLayer
var _lowres_container: SubViewportContainer
var _lowres_viewport: SubViewport
var _lowres_material: ShaderMaterial
var _lowres_mirror_camera: Camera3D
var _lowres_saved_camera_size := 0.0
var _lowres_saved_camera_current := false
## Node3D movers registered for GPU mover snap (see `register_mover`). The snap
## itself happens in the vertex stage (`anchor_mover_snap` instance uniform);
## the manager only tracks membership for diagnostics.
var _movers: Dictionary = {}
var _cloud_params: Dictionary = {}
var _cloud_signature := 0
var _cloud_basis := Basis()
var _cloud_dirty := true
var _palette_dirty := true
## External cloud provider (duck-typed: any Object with build_cloud_params()).
var _cloud_provider: Object = null
## Materials that receive the cloud field only (`register_cloud_material`, and
## every `register_pixelized_material` opt-in, whose macros include the bundled
## cloud toolkit). Keyed by instance id, `{ material: ShaderMaterial }`, pruned
## when the material is freed.
var _cloud_materials: Dictionary = {}
## Manifest-backed lookup of pre-generated bridge shaders (never generates).
var _bridge_registry: PixelizerBridgeRegistry


## Register the pipeline-wide globals before any material specializes: a shader
## that declares a global registered later warns "removed at some point".
func _enter_tree() -> void:
	PixelizerGlobals.ensure()
	PixelizerGlobals.set_param(PixelizerGlobals.SCREEN_SIZE, Vector2(render_resolution))
	PixelizerGlobals.set_param(PixelizerGlobals.LOWRES_MODE, mode == Mode.LOW_RES)
	PixelizerGlobals.set_param(PixelizerGlobals.PALETTE_LUT, global_palette_lut)
	PixelizerGlobals.set_param(PixelizerGlobals.PALETTE_GRADING, global_palette_lut != null)
	PixelizerGlobals.set_param(PixelizerGlobals.PALETTE_DITHER, dither_enabled)


func _ready() -> void:
	add_to_group("pixelizer_manager")
	process_priority = sync_process_priority
	if metadata_layer < 1:
		metadata_layer = 1
	metadata_bit = 1 << (metadata_layer - 1)
	PixelizerGlobals.set_param(PixelizerGlobals.META_BIT, metadata_bit)
	_create_metadata_viewport()
	# Create the compositor + effects up front. Camera binding happens later,
	# when an active camera is resolved.
	_ensure_effects()
	if mode == Mode.LOW_RES:
		call_deferred("_apply_mode")
	_rebuild_bridge_registry()


# ── Shader bridge registry ───────────────────────────────────────────────────

## The manifest-backed bridge lookup. Created lazily so objects can resolve
## before `_ready` runs; rebuilt on `_ready` and whenever `bridge_manifests`
## changes.
func get_bridge_registry() -> PixelizerBridgeRegistry:
	if _bridge_registry == null:
		_bridge_registry = PixelizerBridgeRegistry.new()
		_bridge_registry.build(bridge_manifests)
	return _bridge_registry


## Rebuild the registry from the current manifest list (approved + non-stale
## entries only). Cheap; safe to call on manifest change.
func _rebuild_bridge_registry() -> void:
	get_bridge_registry().build(bridge_manifests)


## Number of source shaders the registry can currently bridge.
func get_bridge_mapped_count() -> int:
	return get_bridge_registry().get_mapped_count()


## Human-readable registry warnings (missing outputs, stale sources, drift).
func get_bridge_warnings() -> PackedStringArray:
	return get_bridge_registry().get_warnings()


func _process(_delta: float) -> void:
	if not enabled:
		# Disabled = plain baseline: undo any snap offsets the manager applied.
		if _active_camera != null and is_instance_valid(_active_camera):
			_active_camera.h_offset = 0.0
			_active_camera.v_offset = 0.0
		return
	if _working_palette == null:
		_rebuild_working_palette()
	_update_cloud_params()
	_update_god_ray_params()
	_update_palette_params()
	# Camera decoupling: resolve the viewport's active camera every frame so
	# switching `Camera3D.current` (or adding/removing cameras) just works.
	var cam := get_active_camera()
	if cam != _bound_camera:
		_unbind_camera(_bound_camera)
		if cam != null and is_instance_valid(cam) and cam.is_inside_tree():
			_bind_camera(cam)
	_active_camera = cam
	if cam == null:
		# No camera: parameters above are still pushed to registered materials
		# (effects stay free-standing); nothing else to sync.
		return
	if mode == Mode.LOW_RES and _lowres_viewport == null:
		_enter_lowres()
	if mode == Mode.LOW_RES:
		_update_camera_snap()
		_sync_mirror_camera()
		_update_lowres_display()
		_update_lowres_camera_size()
		return
	_update_camera_snap()
	_sync_metadata_camera()
	_update_metadata_texture()
	_update_auto_focus()
	if manage_camera_size:
		_update_lowres_camera_size()


## Shared manager resolver for effect nodes, appliers and object configs. Walks
## ancestors first (so nested worlds pick the nearest manager), then falls back
## to the "pixelizer_manager" group. `node` may be any Node (or null); returns
## null when no manager is present or the node is outside the tree.
static func resolve_manager(node: Node) -> PixelizerManager3D:
	var current: Node = node
	while current != null:
		if current is PixelizerManager3D:
			return current as PixelizerManager3D
		current = current.get_parent()
	if node == null or not node.is_inside_tree():
		return null
	var managers := node.get_tree().get_nodes_in_group("pixelizer_manager")
	if not managers.is_empty():
		return managers[0] as PixelizerManager3D
	return null


func get_material_factory() -> PixelizerMaterialFactory:
	if _material_factory == null:
		_material_factory = PixelizerMaterialFactory.new()
	return _material_factory


func get_metadata_texture_rid() -> RID:
	return _metadata_texture_rd


func get_metadata_viewport() -> SubViewport:
	return _metadata_viewport


func allocate_outline_id() -> int:
	var id := _next_outline_id
	_next_outline_id = _next_outline_id % 254 + 1
	return id


# ── Generic effect registration slots ────────────────────────────────────────
#
# The manager is a neutral pipeline hub. Effect nodes register themselves in
# their own `_ready` and unregister in `_exit_tree`, so effects are optional and
# composable per scene. All slots are duck-typed where possible, so new effect
# types need no manager changes.

## Register a cloud field provider. `provider` is any Object with a
## `build_cloud_params(sun: DirectionalLight3D) -> Dictionary` method. Passing a
## provider replaces any previous one.
func register_cloud_provider(provider: Object) -> void:
	if provider == null or not provider.has_method("build_cloud_params"):
		return
	_cloud_provider = provider
	_cloud_dirty = true
	_rebuild_cloud_params()


func unregister_cloud_provider(provider: Object) -> void:
	if provider == null or _cloud_provider != provider:
		return
	_cloud_provider = null
	_cloud_dirty = true


## True while `provider` is the active cloud provider.
func is_cloud_provider(provider: Object) -> bool:
	return provider != null and _cloud_provider == provider


## The manager-owned god-ray pass. It always sits at index 0 of the compositor
## array and early-outs while `rays_enabled == false`. Property names are the
## main-client contract — do not rename.
func get_god_ray_pass() -> PixelizerGodRayEffect:
	return _god_ray_effect


# ── Registration APIs (untyped-friendly) ─────────────────────────────────────
#
# Supported node types: MeshInstance3D, MultiMeshInstance3D, GPUParticles3D and
# CPUParticles3D. Explicit registration binds a PixelizerGeometryState directly;
# when per-object `options` are passed a manual PixelizerObject3D child is
# created so the settings are authored in the scene. All calls are idempotent:
# re-registering updates the state (pixel size / id are instance uniforms, so
# they apply live).
#
# Instance-uniform scope is per node, so a MultiMesh's sub-instances and a
# particle system's particles share one pixel size / outline id. Per-instance
# variation would need INSTANCE_CUSTOM.

## Explicitly owned states (id -> PixelizerGeometryState) for nodes registered
## without an applier ancestor. RefCounted, so the manager holds the reference.
var _explicit_states: Dictionary = {}

## True when `material` is a pixelizer factory material or a custom material
## registered with register_pixelized_material().
func is_pixelized_material(material) -> bool:
	if not (material is ShaderMaterial):
		return false
	if (material as ShaderMaterial).shader == get_material_factory().shader:
		return true
	return (material as ShaderMaterial).has_meta(&"pixelizer_opt_in")


## Opt a custom ShaderMaterial that includes anchor_macros.gdshaderinc into
## the anchor pipeline. The material is marked with the `pixelizer_opt_in` meta
## (so the factory never replaces it) and tracked for the cloud field; pipeline-
## wide params (`meta_bit`, low-res, palette, screen size) are globals and need
## no per-material push. The shader is never replaced. `options` is reserved
## (accepted for API symmetry).
func register_pixelized_material(material, options := {}) -> bool:
	if not (material is ShaderMaterial):
		return false
	var shader_material := material as ShaderMaterial
	shader_material.set_meta(&"pixelizer_opt_in", true)
	_track_cloud_material(shader_material)
	if _cloud_params.is_empty():
		_cloud_params = _build_cloud_params()
	_push_cloud_params_to(shader_material)
	return true


## Stop pushing parameters to a custom material (call before its owner frees it,
## so the registry never holds a freed material).
func unregister_pixelized_material(material) -> void:
	if not is_instance_valid(material):
		return
	if not (material is ShaderMaterial):
		return
	(material as ShaderMaterial).remove_meta(&"pixelizer_opt_in")
	_cloud_materials.erase(material.get_instance_id())


## Pixelize a MultiMeshInstance3D (or any supported node) and its mesh
## materials. `options`: pixel_size (int), outline_id (int),
## outline_color (Color), disable_shadows (bool).
func register_multimesh(node, options := {}) -> PixelizerGeometryState:
	return _attach_config(node, options)


## Pixelize a GPUParticles3D/CPUParticles3D (draw-pass mesh material
## replacement). Same `options` as register_multimesh.
func register_particles(node, options := {}) -> PixelizerGeometryState:
	return _attach_config(node, options)


## Explicit one-shot pixelization for any supported node type. Equivalent to
## register_multimesh/register_particles with type dispatch.
func pixelize_node(node, options := {}) -> PixelizerGeometryState:
	return _attach_config(node, options)


## Notified by a manual PixelizerObject3D setter when the node has no owning
## applier.
func reconfigure_node(target) -> void:
	if target == null or not is_instance_valid(target) or not (target is GeometryInstance3D):
		return
	var geometry := target as GeometryInstance3D
	# Delegate to an owning applier when there is one (duck-typed to avoid a hard
	# manager -> applier dependency).
	var ancestor: Node = geometry.get_parent()
	while ancestor != null:
		if ancestor.has_method("reconfigure") and ancestor.has_method("get_state"):
			ancestor.call("reconfigure", geometry)
			return
		ancestor = ancestor.get_parent()
	_prune_explicit_states()
	var state: PixelizerGeometryState = _explicit_states.get(geometry.get_instance_id())
	if state == null:
		return
	var config := geometry.get_node_or_null("PixelizerObject3D") as PixelizerObject3D
	if config != null:
		if not config.enabled:
			state.unbind()
			return
		config.apply_to_state(state)
	state.apply_shadow_setting()
	if state.is_applied():
		state.push_instance_params()
	elif state.bind(self):
		pass


func _attach_config(node, options: Dictionary = {}) -> PixelizerGeometryState:
	if node == null or not is_instance_valid(node) or not (node is GeometryInstance3D):
		return null
	var geometry := node as GeometryInstance3D
	if not PixelizerGeometryState.is_supported_node(geometry):
		return null
	_prune_explicit_states()
	# Per-object options become an explicit manual config child (authored in the
	# scene); without options the manager binds a state directly.
	var config := geometry.get_node_or_null("PixelizerObject3D") as PixelizerObject3D
	if not options.is_empty():
		if config == null or config.get_parent() != geometry:
			config = PixelizerObject3D.new()
			config.name = "PixelizerObject3D"
			_apply_options_to_config(config, options)
			geometry.add_child(config)
		else:
			_apply_options_to_config(config, options)
	# Delegate to an owning applier when one is present.
	var ancestor: Node = geometry.get_parent()
	while ancestor != null:
		if ancestor.has_method("reconfigure") and ancestor.has_method("get_state"):
			ancestor.call("reconfigure", geometry)
			return ancestor.call("get_state", geometry)
		ancestor = ancestor.get_parent()
	var id := geometry.get_instance_id()
	var state: PixelizerGeometryState = _explicit_states.get(id)
	if state == null:
		state = PixelizerGeometryState.new(geometry)
		_explicit_states[id] = state
	if config != null:
		config.apply_to_state(state)
	elif state.outline_id < 0:
		state.outline_id = allocate_outline_id()
	if state.is_applied():
		state.apply_shadow_setting()
		state.push_instance_params()
	else:
		state.bind(self)
	return state


func _apply_options_to_config(config: PixelizerObject3D, options: Dictionary) -> void:
	if options.has("pixel_size"):
		config.pixel_size = int(options["pixel_size"])
	if options.has("outline_id"):
		config.outline_id = int(options["outline_id"])
	if options.has("outline_color"):
		config.outline_color = options["outline_color"]
	if options.has("override_outline_color"):
		config.override_outline_color = bool(options["override_outline_color"])
	if options.has("outline_enabled"):
		config.outline_enabled = bool(options["outline_enabled"])
	if options.has("palette_enabled"):
		config.palette_enabled = bool(options["palette_enabled"])
	if options.has("dither_enabled"):
		config.dither_enabled = bool(options["dither_enabled"])
	if options.has("anchor_mode"):
		config.anchor_mode = int(options["anchor_mode"])
	if options.has("disable_shadows"):
		config.disable_shadows = bool(options["disable_shadows"])
	if options.has("mover_snap"):
		if bool(options["mover_snap"]):
			register_mover(config.get_parent())
		else:
			unregister_mover(config.get_parent())


func _prune_explicit_states() -> void:
	var dead: Array = []
	for id in _explicit_states:
		var state: PixelizerGeometryState = _explicit_states[id]
		if state.target == null or not is_instance_valid(state.target):
			dead.append(id)
	for id in dead:
		_explicit_states.erase(id)


# ── Mover snap ───────────────────────────────────────────────────────────────
#
# Mover snap is a vertex-stage offset, not a CPU transform swap. Registering a
# node sets the `anchor_mover_snap` instance uniform it declares through
# `anchor_macros.gdshaderinc`; `ANCHOR_VERTEX` then shifts the rigid mesh so the
# projected pivot lands on a whole screen texel. The scene transform is never
# read or written per frame, so no pre/post-draw callbacks and no save/restore
# bookkeeping are needed. The shader is orthographic-guarded.

## Register a Node3D whose pivot is snapped onto the pixel lattice at draw time.
## Only effective on geometry that runs a pixelizer material (the instance
## uniform is declared by `anchor_macros.gdshaderinc`).
func register_mover(node) -> void:
	if node == null or not is_instance_valid(node) or not (node is Node3D):
		return
	_movers[node.get_instance_id()] = node
	_set_mover_uniform(node, 1)


func unregister_mover(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	_movers.erase(node.get_instance_id())
	_set_mover_uniform(node, 0)


func _set_mover_uniform(node, value: int) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).set_instance_shader_parameter("anchor_mover_snap", value)


# ── Outline palette ──────────────────────────────────────────────────────────

## Set a tag's outline colour for both the silhouette and inner-edge rows (drawn
## as a replace), so an override covers every visible outline of that tag.
func set_outline_color(id: int, color: Color) -> void:
	if id < 0 or id > 254:
		return
	if _working_palette == null:
		_rebuild_working_palette()
	_working_palette.set_entry(id, color, color, 1.0, 1.0)
	_outline_dirty = true


## Show or hide the screen-space outline for one edge tag. Hiding writes the
## "invisible" palette row (white with multiply on both rows, so
## `outline_rgb = white` leaves the sampled scene colour unchanged) — the apply
## shader needs no special case. Re-enabling restores the tag's row from
## `outline_palette` when set, else the manager's `outline_color`.
func set_outline_enabled(id: int, enabled: bool) -> void:
	if id < 0 or id > 254:
		return
	if _working_palette == null:
		_rebuild_working_palette()
	if enabled:
		if outline_palette != null and id < outline_palette.silhouette_colors.size():
			_working_palette.set_entry(
				id,
				outline_palette.silhouette_colors[id],
				outline_palette.inner_colors[id],
				outline_palette.silhouette_alpha[id],
				outline_palette.inner_alpha[id])
		else:
			_working_palette.set_entry(id, outline_color, outline_color, 1.0, 1.0)
	else:
		# Opacity 0 leaves the sampled scene colour untouched, so the apply
		# shader needs no visibility branch.
		_working_palette.set_entry(id, Color.WHITE, Color.WHITE, 0.0, 0.0)
	_outline_dirty = true


func get_outline_texture() -> ImageTexture:
	if _outline_texture == null or _outline_dirty:
		if _working_palette == null:
			_rebuild_working_palette()
		_outline_texture = _working_palette.bake_texture()
		_outline_dirty = false
	return _outline_texture


func _rebuild_working_palette() -> void:
	_working_palette = PixelizerOutlinePalette.new()
	if outline_palette != null:
		_working_palette.silhouette_colors = outline_palette.silhouette_colors.duplicate()
		_working_palette.inner_colors = outline_palette.inner_colors.duplicate()
		_working_palette.silhouette_alpha = outline_palette.silhouette_alpha.duplicate()
		_working_palette.inner_alpha = outline_palette.inner_alpha.duplicate()
	else:
		for i in PixelizerOutlinePalette.ROW_COUNT:
			_working_palette.set_entry(i, outline_color, outline_color, 1.0, 1.0)
	_outline_dirty = true


# ── Focus subject (reserved edge tag 255) ──────────────────────────────────

## Focus a node's subtree: every pixelized mesh gets edge tag 255. Focused
## pixels are exempt from smooth-scroll shifts and can be debug-tinted.
func focus_subtree(root: Node) -> void:
	if root is GeometryInstance3D:
		_focus_mesh(root as GeometryInstance3D)
	for child in root.get_children():
		focus_subtree(child)


func unfocus_subtree(root: Node) -> void:
	if root is GeometryInstance3D:
		_unfocus_mesh(root as GeometryInstance3D)
	for child in root.get_children():
		unfocus_subtree(child)


func _focus_mesh(mesh: GeometryInstance3D) -> void:
	var id := mesh.get_instance_id()
	if _focused.has(id):
		return
	_focused[id] = mesh
	# `anchor_focus` is an instance uniform; the shader maps it onto edge tag
	# 255 in the metadata payload, so `anchor_tag` is never overwritten.
	mesh.set_instance_shader_parameter("anchor_focus", 1)


func _unfocus_mesh(mesh: GeometryInstance3D) -> void:
	var id := mesh.get_instance_id()
	if not _focused.has(id):
		return
	_focused.erase(id)
	if is_instance_valid(mesh):
		mesh.set_instance_shader_parameter("anchor_focus", 0)


func _update_auto_focus() -> void:
	if not auto_focus or auto_focus_target == null or not is_instance_valid(auto_focus_target):
		return
	var target_id := auto_focus_target.get_instance_id()
	if target_id != _auto_focused_target_id:
		# Unfocus the previous target before focusing the new one, so changing
		# `auto_focus_target` never leaves stale focused tags behind.
		if _auto_focused_target_id != 0:
			var previous := instance_from_id(_auto_focused_target_id)
			if previous != null and is_instance_valid(previous):
				unfocus_subtree(previous as Node)
		_auto_focused_target_id = target_id
		focus_subtree(auto_focus_target)
		return
	# Cheap periodic re-scan so runtime-spawned children get focused too.
	_focus_rescan_counter += 1
	if _focus_rescan_counter >= 30:
		_focus_rescan_counter = 0
		focus_subtree(auto_focus_target)


## Combine with the manager's other diagnostics for a HUD line.
func get_debug_status_line() -> String:
	var mode_name := "anchor" if mode == Mode.ANCHOR else "lowres"
	var lines: PackedStringArray = []
	lines.append("Pixelizer3D [%s] %s" % [mode_name, "on" if enabled else "OFF"])
	lines.append("pixel=%d layer=%d view=%d" % [pixel_size, metadata_layer, debug_view])
	lines.append("outline=%s occl=%s palette=%s" % [
		"on" if outline_enabled else "off",
		"on" if depth_occlusion else "off",
		"yes" if _working_palette != null else "no"])
	lines.append("lut=%s dither=%s" % [
		"yes" if global_palette_lut != null else "no",
		"on" if dither_enabled else "off"])
	var god_pass := get_god_ray_pass()
	lines.append("rays=%s" % [
		"on" if (god_pass != null and god_pass.rays_enabled) else "off"])
	lines.append("focused=%d auto=%s" % [_focused.size(), "on" if auto_focus else "off"])
	lines.append("u/texel=%.4f remainder=(%.2f, %.2f) snap=%s" % [
		get_texel_world_size(), subtexel_remainder.x, subtexel_remainder.y,
		"on" if snap_camera else "off"])
	return "\n".join(lines)


# ── Cloud shadows ────────────────────────────────────────────────────────────

## Push the cloud uniforms into a custom ShaderMaterial that includes
## `cloud_fbm.gdshaderinc` (MST terrain, water, the deck). Safe to call
## repeatedly.
func register_cloud_material(material: ShaderMaterial) -> void:
	if material == null:
		return
	_track_cloud_material(material)
	if _cloud_params.is_empty():
		_cloud_params = _build_cloud_params()
	_push_cloud_params_to(material)


## Add `material` to the cloud-field push list (idempotent). Both
## `register_cloud_material` and the `register_pixelized_material` opt-in use it:
## the bundled macros include the cloud toolkit by default.
func _track_cloud_material(material: ShaderMaterial) -> void:
	_cloud_materials[material.get_instance_id()] = {"material": material}


func unregister_cloud_material(material: ShaderMaterial) -> void:
	if material == null:
		return
	# A pixelized material keeps receiving the cloud field even if its explicit
	# cloud registration is dropped (the macros include the toolkit).
	if material.has_meta(&"pixelizer_opt_in"):
		return
	_cloud_materials.erase(material.get_instance_id())


## Build cloud params from the registered provider, or neutral defaults when no
## provider is present (so consumers never read stale values).
func _build_cloud_params() -> Dictionary:
	if _cloud_provider != null and is_instance_valid(_cloud_provider) and _cloud_provider.has_method("build_cloud_params"):
		var result = _cloud_provider.call("build_cloud_params", sun)
		if result is Dictionary:
			return result
	return _neutral_cloud_params()


## Neutral param set: clouds off, but every shader-contract key present so no
## consumer reads a stale value.
func _neutral_cloud_params() -> Dictionary:
	var sun_dir := Vector3(0.0, -1.0, 0.0)
	if sun != null and is_instance_valid(sun):
		sun_dir = -sun.global_transform.basis.z.normalized()
	return {
		"clouds_enabled": false,
		"cloud_noise": null,
		"cloud_sun_dir": sun_dir,
		"cloud_height": 400.0,
		"cloud_noise_scale": 0.0015,
		"cloud_threshold": 0.6,
		"cloud_bands": 3.0,
		"cloud_tightness": 1.0,
		"cloud_octave_drop": 0.5,
		"cloud_gap_erosion": 0.0,
		"cloud_detail_strength": 0.0,
		"cloud_wind": Vector2(0.01, 0.004),
		"cloud_shadow_strength": 0.0,
		"cloud_shadow_banding_enabled": true,
		"cloud_shadow_levels": 3.0,
		"cloud_shadow_softness": 0.35,
	}


func _rebuild_cloud_params() -> void:
	_cloud_params = _build_cloud_params()
	_push_cloud_params_all()


func _update_cloud_params() -> void:
	var params := _build_cloud_params()
	var sun_basis := Basis()
	if sun != null and is_instance_valid(sun):
		sun_basis = sun.global_transform.basis
	var signature := params.hash()
	if not _cloud_dirty and signature == _cloud_signature and sun_basis == _cloud_basis:
		return
	_cloud_dirty = false
	_cloud_signature = signature
	_cloud_basis = sun_basis
	_cloud_params = params
	_push_cloud_params_all()


func _push_cloud_params_all() -> void:
	get_material_factory().set_cloud_params(_cloud_params)
	_prune_cloud_materials()
	for entry in _cloud_materials.values():
		_push_cloud_params_to(entry["material"])
	_push_cloud_params_to(_god_ray_effect)


## Drop entries whose material has been freed. Called from the push loops so the
## list cannot grow without bound across runtime material swaps.
func _prune_cloud_materials() -> void:
	var dead: Array = []
	for id in _cloud_materials:
		if not is_instance_valid(_cloud_materials[id]["material"]):
			dead.append(id)
	for id in dead:
		_cloud_materials.erase(id)


func _push_cloud_params_to(material) -> void:
	if material is PixelizerGodRayEffect:
		(material as PixelizerGodRayEffect).set_cloud_params(_cloud_params)
		return
	if not (material is ShaderMaterial):
		return
	for key in _cloud_params:
		(material as ShaderMaterial).set_shader_parameter(key, _cloud_params[key])


# ── God rays ─────────────────────────────────────────────────────────────────

## The manager only keeps the sun tint in sync; every ray tuning value belongs to
## the pass's own exports (external contract via `get_god_ray_pass()`).
func _update_god_ray_params() -> void:
	_apply_sun_tint(_god_ray_effect)


func _apply_sun_tint(effect: PixelizerGodRayEffect) -> void:
	if effect == null:
		return
	var sun_color := Color(1.0, 0.96, 0.85)
	if sun != null and is_instance_valid(sun):
		sun_color = sun.light_color
	if effect.ray_tint == sun_color:
		return
	effect.ray_tint = sun_color


# ── Palette LUT grading ──────────────────────────────────────────────────────

## Publish the palette globals once per change (LUT + dither toggle). Grading is
## on when a LUT is assigned.
func _update_palette_params() -> void:
	if not _palette_dirty:
		return
	_palette_dirty = false
	PixelizerGlobals.set_param(PixelizerGlobals.PALETTE_LUT, global_palette_lut)
	PixelizerGlobals.set_param(PixelizerGlobals.PALETTE_GRADING, global_palette_lut != null)
	PixelizerGlobals.set_param(PixelizerGlobals.PALETTE_DITHER, dither_enabled)


# ── Active camera (auto-resolved; one manager per viewport) ─────────────────

## Explicitly pin the camera this manager pixelizes. Null clears the override,
## restoring automatic `get_viewport().get_camera_3d()` resolution. Use this
## when a rig owns the camera node and the viewport's `current` camera is not
## the one to pixelize.
func set_target_camera(cam: Camera3D) -> void:
	_target_camera = cam
	if is_inside_tree() and cam != _bound_camera:
		_unbind_camera(_bound_camera)
		if cam != null and is_instance_valid(cam) and cam.is_inside_tree():
			_bind_camera(cam)


func clear_target_camera() -> void:
	_target_camera = null


## The camera whose view is pixelized: the explicit target when set, else the
## viewport's current camera. In low-res mode the acquired camera is cached
## (reparenting it into the display SubViewport removes it from the viewport's
## current-camera slot).
func get_active_camera() -> Camera3D:
	if _target_camera != null and is_instance_valid(_target_camera):
		return _target_camera
	if mode == Mode.LOW_RES and _lowres_viewport != null and _active_camera != null and is_instance_valid(_active_camera):
		return _active_camera
	if not is_inside_tree():
		return null
	return get_viewport().get_camera_3d()


# ── Camera snap (h_offset/v_offset only — never transforms) ─────────────────

## World units covered by one screen texel (respects keep_aspect).
func get_texel_world_size() -> float:
	var cam := _active_camera
	if cam == null or not is_instance_valid(cam):
		return 0.0
	var viewport := cam.get_viewport()
	if viewport == null or viewport.size.x <= 0 or viewport.size.y <= 0:
		return 0.0
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		return cam.size / float(viewport.size.x)
	return cam.size / float(viewport.size.y)


## Effective view width (horizontal) for the configured render
## resolution, texel density and zoom.
func get_view_width() -> float:
	return float(render_resolution.x) / max(texel_density, 0.0001) * view_zoom


## Configured view width before zoom.
func get_base_view_width() -> float:
	return float(render_resolution.x) / maxf(texel_density, 0.0001)


func get_world_per_pixel() -> float:
	return 1.0 / max(texel_density, 0.0001)


func set_view_zoom(value: float) -> void:
	view_zoom = clampf(value, 0.05, 20.0)


# ── Screen-space projection ──────────────────────────────────────────────────

## Projection materials multiply SCREEN_UV by the render size to land on the
## render pixel grid. That size rides the `PixelizerGlobals.SCREEN_SIZE` global
## uniform, published from the `render_resolution` setter and `_enter_tree`.

func _update_camera_snap() -> void:
	var cam := _active_camera
	if not snap_camera or cam == null or not is_instance_valid(cam):
		_zero_camera_snap(cam)
		return
	if cam.projection != Camera3D.PROJECTION_ORTHOGONAL:
		if not _perspective_warned:
			_perspective_warned = true
			push_warning("Pixelizer3D: camera snap only supports orthographic cameras; skipping.")
		_zero_camera_snap(cam)
		return
	if lock_camera:
		_zero_camera_snap(cam)
		return
	var texel := get_texel_world_size()
	if texel <= 0.0:
		_zero_camera_snap(cam)
		return
	# Project the phase anchor into camera view space, convert its screen-plane
	# position to texel coordinates, and shift the frustum so that position
	# lands on a whole texel. This is a single projection-space snap (no
	# separate anchor/view grid passes): the residual sub-texel phase is exactly
	# what `h_offset`/`v_offset` cancel.
	var basis := cam.global_transform.basis.orthonormalized()
	var anchor_world := Vector3.ZERO
	if snap_origin != null and is_instance_valid(snap_origin):
		anchor_world = snap_origin.global_position
	var anchor_view: Vector3 = basis.inverse() * (anchor_world - cam.global_position)
	var anchor_texel := Vector2(anchor_view.x / texel, anchor_view.y / texel)
	var snapped := Vector2(round(anchor_texel.x), round(anchor_texel.y))
	var residual := anchor_texel - snapped
	cam.h_offset = residual.x * texel
	cam.v_offset = residual.y * texel
	subtexel_remainder = -residual


## Clear the snap offsets when snapping is inactive, so a camera does not keep
## last frame's offsets (e.g. after toggling `snap_camera` off).
func _zero_camera_snap(cam: Camera3D) -> void:
	subtexel_remainder = Vector2.ZERO
	if cam != null and is_instance_valid(cam):
		cam.h_offset = 0.0
		cam.v_offset = 0.0


## One-time creation of the compositor + effect passes. Safe to call repeatedly;
## no-op once the compositor exists.
func _ensure_effects() -> void:
	if _compositor != null:
		return
	if RenderingServer.get_rendering_device() == null:
		if not _rd_warned:
			_rd_warned = true
			push_warning("Pixelizer3D: RenderingDevice unavailable (Compatibility renderer or headless); pixelization disabled.")
		return

	# The manager owns exactly one god-ray pass (the authored `ray_pass` when
	# set, else a disabled manager-created one). It always runs FIRST: it writes
	# additively into the scene colour before the snapshot pass copies it, so
	# the rays are replicated into macro-pixels by the apply pass like the rest
	# of the image.
	_god_ray_effect = ray_pass if ray_pass != null else PixelizerGodRayEffect.new()
	_snapshot_effect = PixelizerSnapshotEffect.new()
	_apply_effect = PixelizerApplyPixelizationEffect.new()
	_god_ray_effect.manager = self
	_snapshot_effect.manager = self
	_apply_effect.manager = self

	_compositor = Compositor.new()
	_compositor.compositor_effects = [_god_ray_effect, _snapshot_effect, _apply_effect]
	if _cloud_params.is_empty():
		_cloud_params = _build_cloud_params()
	_push_cloud_params_to(_god_ray_effect)
	_apply_sun_tint(_god_ray_effect)


## Attach the compositor to `cam`, saving the fields we touch once so a later
## unbind restores the camera exactly. Only ANCHOR mode modifies the camera
## (cull mask + compositor); snap offsets and `size` are written per frame.
func _bind_camera(cam: Camera3D) -> void:
	if cam == null or not is_instance_valid(cam):
		return
	_ensure_effects()
	if _compositor == null:
		return
	_saved_camera = cam
	_saved_cull_mask = cam.cull_mask
	_saved_compositor = cam.compositor
	_saved_h_offset = cam.h_offset
	_saved_v_offset = cam.v_offset
	_saved_size = cam.size
	_saved_size_managed = manage_camera_size
	if mode == Mode.ANCHOR:
		cam.set_cull_mask_value(metadata_layer, false)
		cam.compositor = _compositor
	_bound_camera = cam


## Restore a bound camera and forget its saved state. Never mutate a camera we
## did not author (`_saved_camera` identity is the guard).
func _unbind_camera(cam: Camera3D) -> void:
	if _bound_camera == cam:
		_bound_camera = null
	if cam == null or cam != _saved_camera:
		return
	_saved_camera = null
	if not is_instance_valid(cam):
		return
	cam.cull_mask = _saved_cull_mask
	cam.compositor = _saved_compositor
	cam.h_offset = _saved_h_offset
	cam.v_offset = _saved_v_offset
	if _saved_size_managed:
		cam.size = _saved_size


## Copy the pose and lens fields shared by the metadata camera and the low-res
## mirror camera, so the two sync paths cannot drift apart.
static func _copy_camera_lens(from: Camera3D, to: Camera3D) -> void:
	to.global_transform = from.global_transform
	to.projection = from.projection
	to.fov = from.fov
	to.near = from.near
	to.far = from.far
	to.keep_aspect = from.keep_aspect
	to.frustum_offset = from.frustum_offset
	to.h_offset = from.h_offset
	to.v_offset = from.v_offset


func _sync_metadata_camera() -> void:
	if _metadata_viewport == null or _metadata_camera == null:
		return
	var cam := _active_camera
	if cam == null or not is_instance_valid(cam):
		return
	var main_viewport := cam.get_viewport()
	if main_viewport == null:
		return
	if _metadata_viewport.size != main_viewport.size:
		_metadata_viewport.size = main_viewport.size
	_copy_camera_lens(cam, _metadata_camera)
	_metadata_camera.size = cam.size


func _update_metadata_texture() -> void:
	if _metadata_viewport == null:
		return
	var texture_rid := RenderingServer.viewport_get_texture(_metadata_viewport.get_viewport_rid())
	if not texture_rid.is_valid():
		return
	# Re-fetch every frame: the viewport recreates its render target on resize
	# (and other reconfigurations), and the old RD texture goes stale while its
	# wrapper RID stays non-null. Caching it caused invalid bindings after a
	# window resize. texture_get_rd_texture is a cheap RenderingServer getter.
	_metadata_texture_source = texture_rid
	_metadata_texture_rd = RenderingServer.texture_get_rd_texture(texture_rid, false)


func _create_metadata_viewport() -> void:
	_metadata_viewport = SubViewport.new()
	_metadata_viewport.name = "PixelizerMetadataViewport"
	_metadata_viewport.own_world_3d = false
	_metadata_viewport.handle_input_locally = false
	_metadata_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_metadata_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_metadata_viewport.use_hdr_2d = true
	_metadata_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_metadata_viewport.use_taa = false
	_metadata_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_metadata_viewport.use_debanding = false
	_metadata_viewport.size = Vector2i(960, 540)
	add_child(_metadata_viewport)

	_metadata_environment = Environment.new()
	_metadata_environment.background_mode = Environment.BG_COLOR
	_metadata_environment.background_color = Color(0.0, 0.0, 0.0, 1.0)
	_metadata_environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_metadata_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_metadata_environment.glow_enabled = false
	_metadata_environment.ssao_enabled = false
	_metadata_environment.ssil_enabled = false
	_metadata_environment.sdfgi_enabled = false
	_metadata_environment.fog_enabled = false
	_metadata_environment.volumetric_fog_enabled = false

	_metadata_camera = Camera3D.new()
	_metadata_camera.name = "MetadataCamera"
	_metadata_camera.current = true
	_metadata_camera.environment = _metadata_environment
	_metadata_camera.cull_mask = metadata_bit
	_metadata_camera.near = 0.05
	_metadata_viewport.add_child(_metadata_camera)


func _exit_tree() -> void:
	if mode == Mode.LOW_RES:
		_exit_lowres()
	_unbind_camera(_bound_camera)


# ── Low-res SubViewport mode ─────────────────────────────────────────────────

func _apply_mode() -> void:
	if mode == Mode.LOW_RES:
		_enter_lowres()
	else:
		_exit_lowres()
		var cam := get_active_camera()
		if cam != null and is_instance_valid(cam) and cam.is_inside_tree():
			_active_camera = cam
			_bind_camera(cam)


func _enter_lowres() -> void:
	if _lowres_viewport != null:
		return
	var cam := _active_camera
	if cam == null or not is_instance_valid(cam) or not cam.is_inside_tree():
		return

	# Detach the anchor compositor (if any) and restore the user camera before
	# the mirror takes over; the low-res path renders the scene unmodified into
	# its own SubViewport through a manager-owned mirror camera.
	_unbind_camera(_bound_camera)

	_lowres_layer = CanvasLayer.new()
	_lowres_layer.name = "PixelizerLowResDisplay"
	_lowres_layer.layer = 0
	add_child(_lowres_layer)

	_lowres_container = SubViewportContainer.new()
	_lowres_container.name = "LowResContainer"
	_lowres_container.stretch = false
	_lowres_container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_lowres_container.size = Vector2(render_resolution)
	_lowres_material = ShaderMaterial.new()
	_lowres_material.shader = load(LOWRES_UPSCALE_SHADER) as Shader
	_lowres_container.material = _lowres_material
	_lowres_layer.add_child(_lowres_container)

	_lowres_viewport = SubViewport.new()
	_lowres_viewport.name = "LowResViewport"
	_lowres_viewport.size = render_resolution
	_lowres_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_lowres_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_lowres_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_lowres_viewport.use_taa = false
	_lowres_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_lowres_container.add_child(_lowres_viewport)

	# Mirror-camera only: the user camera stays where it is (some rigs own the
	# camera node), is un-currented, and a manager-owned camera inside the
	# SubViewport is synced every frame.
	_lowres_saved_camera_size = cam.size
	_lowres_saved_camera_current = cam.current
	_lowres_mirror_camera = Camera3D.new()
	_lowres_mirror_camera.name = "MirrorCamera"
	_lowres_mirror_camera.current = true
	_lowres_viewport.add_child(_lowres_mirror_camera)
	cam.current = false
	_sync_mirror_camera()
	_update_lowres_camera_size()

	if _metadata_viewport != null:
		_metadata_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	PixelizerGlobals.set_param(PixelizerGlobals.LOWRES_MODE, true)


func _exit_lowres() -> void:
	if _lowres_viewport == null:
		return
	var cam := _active_camera
	PixelizerGlobals.set_param(PixelizerGlobals.LOWRES_MODE, false)
	if _lowres_mirror_camera != null and is_instance_valid(_lowres_mirror_camera):
		_lowres_mirror_camera.queue_free()
	_lowres_mirror_camera = null
	if cam != null and is_instance_valid(cam):
		cam.current = _lowres_saved_camera_current
		cam.size = _lowres_saved_camera_size
	# Restore the fields the manager changed (offsets, cull mask, compositor,
	# size when managed) and forget the binding; `_process`/`_apply_mode` rebind.
	_unbind_camera(cam)
	if _metadata_viewport != null:
		_metadata_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _lowres_layer != null and is_instance_valid(_lowres_layer):
		_lowres_layer.queue_free()
	_lowres_layer = null
	_lowres_container = null
	_lowres_viewport = null
	_lowres_material = null


func _update_lowres_camera_size() -> void:
	var target := _active_camera
	if mode == Mode.LOW_RES:
		target = _lowres_mirror_camera
	if target == null or not is_instance_valid(target):
		return
	var units: float = 1.0 / maxf(texel_density, 0.0001)
	if target.keep_aspect == Camera3D.KEEP_WIDTH:
		target.size = float(render_resolution.x) * units * view_zoom
	else:
		target.size = float(render_resolution.y) * units * view_zoom


## Copy the user camera's pose/lens/cull mask onto the manager-owned mirror
## camera inside the low-res SubViewport every frame.
func _sync_mirror_camera() -> void:
	var cam := _active_camera
	if _lowres_mirror_camera == null or cam == null or not is_instance_valid(cam):
		return
	_copy_camera_lens(cam, _lowres_mirror_camera)
	_lowres_mirror_camera.environment = cam.environment
	_lowres_mirror_camera.cull_mask = cam.cull_mask
	_update_lowres_camera_size()


func _update_lowres_display() -> void:
	if _lowres_container == null or _lowres_viewport == null:
		return
	var window_size := Vector2(get_viewport().get_visible_rect().size)
	var render_size := Vector2(_lowres_viewport.size)
	if render_size.x <= 0.0 or render_size.y <= 0.0:
		return
	var display_scale := minf(window_size.x / render_size.x, window_size.y / render_size.y)
	if display_scale <= 0.0:
		return
	_lowres_container.scale = Vector2(display_scale, display_scale)
	var target_position := (window_size - render_size * display_scale) * 0.5
	_lowres_container.position = target_position.round()
	# Counter-shift the snap remainder so motion stays smooth inside the
	# low-res viewport (the camera itself is snapped to the texel grid), and
	# tell the upscaler the exact source resolution it is reconstructing.
	_lowres_material.set_shader_parameter("scroll_shift", subtexel_remainder)
	_lowres_material.set_shader_parameter("source_size", render_size)
