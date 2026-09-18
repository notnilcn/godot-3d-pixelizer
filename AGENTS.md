# AGENTS.md — godot-pixelizer-3d

Pixelizer3D: consolidated Godot 4.7 (Forward+) 3D pixel-art addon
(`addons/pixelizer_3d/`).

## Build / test

Godot binary: `C:/Users/Clinton/g/Godot/Godot-stable_mono_win64_console.exe`
(4.7.1 mono, use the `_console` variant).

```bash
# 1. Import + parse check (REQUIRED after every .glsl edit — SPIR-V is baked at
#    import; a stale cache silently runs the old shader or errors at load).
"C:/Users/Clinton/g/Godot/Godot-stable_mono_win64_console.exe" --headless --editor --quit --path .

# 2. Run the demo (real GPU, interactive).
"C:/Users/Clinton/g/Godot/Godot-stable_mono_win64_console.exe" --path .

# 3. Shader-bridge fixtures (headless, no GPU): scan/generate, include
#    flattening, determinism, manifest round-trip, registry gating, cloud-owner
#    vs bundled-cloud injection, and "the scanned addon is never written".
#    Exit 0 = all pass. Fixtures wipe/rebuild
#    tests/bridge/generated/.
"C:/Users/Clinton/g/Godot/Godot-stable_mono_win64_console.exe" --headless --path . --script res://tests/bridge/bridge_fixtures.gd

# 4. (Re)generate the MST bridge shaders. Run after ANY MST shader change:
#    writes the test fixtures (tests/bridge/generated/) and the demo's
#    production manifest + shaders (res://pixelizer_bridges/). A new
#    INJECTION_RULES_VERSION makes old entries stale until this runs.
"C:/Users/Clinton/g/Godot/Godot-stable_mono_win64_console.exe" --headless --path . --script res://tests/bridge/generate_bridges.gd

# 5. Windowed compile smoke test for the generated bridge shaders. Prints no
#    SHADER ERROR on success.
"C:/Users/Clinton/g/Godot/Godot-stable_mono_win64_console.exe" --path . res://tests/bridge/compile_test.tscn
```

The demo and the addon implement no custom CLI flags. `tests/` holds a
capture-matrix runner (`run_captures.py`) with a PIL diff tool
(`compare_captures.py`), reference PNGs (`reference/`), fresh captures
(`captures/`) and per-run logs (`logs/`) — see `tests/README.md`. The demo
does not parse the matrix flags and prints no diagnostics line, so matrix
runs fail the diagnostics check (exit 1).

## Demo (`demo/demo.tscn`, main scene)

- `demo/demo.tscn` + `demo/player.gd`. `demo/demo.gd.uid` has no matching script.
- Scene tree: `PixelizerManager3D` (auto-follows the viewport's current camera;
  no camera export/path) → top-level
  `PixelizerApplier3D` containing: 6 character FBX instances under a
  `Node3D/Node3D` row (`Barbarian`, `Knight`, `Mage`, `Ranger`, `Rogue`,
  `Rogue_Hooded`), `PixelizerFireflies3D`, a playable `CharacterBody3D`
  (Knight visual + arcball `Camera3D` child), a nested `PixelizerApplier3D`
  around `MarchingSquaresTerrain` (`data_directory =
  res://demo/demo2_TerrainData/...`) + `GrassPlanter` (MultiMeshInstance3D),
  plus `PixelizerPointLightVolume3D`, `PixelizerSkyClouds3D` and
  `PixelizerWater3D` (last two parented to the scene root, wired to the
  manager via NodePath).
- Assets: `demo/assets/characters/` (FBX + `*_texture.png`, KayKit Adventurers
  pack per `CREDITS.md`); MST save data in `demo/demo2_TerrainData/`.
- Bridge wiring: the manager trusts the production manifest
  (`bridge_manifests = [res://pixelizer_bridges/pixelizer_bridge_manifest.tres]`)
  with `auto_bridge_custom_shaders = true`, so the pristine MST shaders are
  swapped for generated bridge shaders at runtime. `res://pixelizer_bridges/`
  is generated output — delete it and rerun `generate_bridges.gd` to rebuild.
- Nested terrain applier: `pixel_size = 5`, `anchor_mode = 1` (UNIFIED) and a
  black outline override. UNIFIED is load-bearing: the 7 chunk meshes + grass
  share one world-origin macro lattice, otherwise the outline pass samples
  phase-shifted neighbour anchor cells across chunk borders and draws false
  inner-edge outlines along them.
- The pristine MST shader uses `cull_disabled`; the pre-bridge fork used
  `cull_back` to hide underside geometry at shallow pitches. The bridge only
  rewrites stage functions, never `render_mode`, so re-adding that fix needs a
  bridge render_mode rule or an addon patch.
- Controls (`demo/player.gd`): WASD camera-relative move, Space jump, arrow
  keys orbit (yaw/pitch), mouse drag orbits, wheel zooms (distance 2–14 m,
  pivot height 1.5 m). `Tab` toggles the HUD-only `PixelizerDiagnosticsOverlay`
  (status readout; live tuning is done through Godot's remote inspector).
  InputMap actions (`player_forward`/`back`/`left`/
  `right`/`jump`, `camera_orbit_*`) are created at runtime, idempotent —
  `project.godot` has no `[input]` section.
- `PixelizerCameraController3D` exists in the addon; the demo does not use it
  (the player script owns the camera).
- `capture.png`, `capture_metadata.png`, `palette_lut_debug.png` at the repo
  root are generated artifacts (gitignored via `*.png` / `*.import`).

## Composition model (per-scene effects)

The manager (`PixelizerManager3D`) is a neutral pipeline hub: it owns only shared
services (metadata viewport + camera, compositor, material factory, outline
palette, palette LUT, resolution/zoom, camera snap, mover snap, focus, bridge
registry, the shared `sun`) and generic registration slots. Every *visual*
effect is an optional, self-contained scene node in `effects/` that owns its own
settings and registers itself in `_ready` / unregisters in `_exit_tree`:

| Scene wants | Nodes to place |
|---|---|
| Anchor pixelization only | `PixelizerManager3D` + `PixelizerApplier3D` |
| + cloud shadows (no deck) | + `PixelizerSkyClouds3D` (`deck_enabled = false`) |
| + visible cloud deck | + `PixelizerSkyClouds3D` (shadows off via `cloud_shadow_strength = 0`) |
| + god rays | + `PixelizerGodRays3D` (toggles the manager's `ray_pass`) |
| + water / fireflies / day-night / … | + the matching `effects/` node |

Omit a node to omit the effect. Generic slots (all duck-typed where possible, so
new effect types need no manager change):

- `register_cloud_provider(provider)` / `unregister_cloud_provider(provider)` —
  any Object with `build_cloud_params(sun) -> Dictionary`. `PixelizerSkyClouds3D`
  is the provider node. With no provider the manager pushes neutral params
  (`clouds_enabled = false`) so consumers never read stale uniforms.
- The god-ray pass is manager-owned and fixed at compositor index 0
  (`PixelizerManager3D.ray_pass`, else a disabled manager-created pass).
  `get_god_ray_pass()` always returns it and stays the external tuning contract;
  `PixelizerGodRays3D` only toggles `rays_enabled`, and the pass early-outs while
  disabled.
- `register_cloud_material(material)` / `unregister_cloud_material(material)` —
  consumers that only receive cloud uniforms (water, terrain, deck).
- `register_pixelized_material(material)` / `unregister_pixelized_material(material)`
  — custom spatial materials that include `anchor_macros.gdshaderinc`.

All effect nodes resolve the manager through the shared static
`PixelizerManager3D.resolve_manager(node)` (ancestor walk → `pixelizer_manager`
group), never a duplicated lookup.

## Architecture (anchor mode — the default)

1. `PixelizerManager3D` creates a metadata `SubViewport` + duplicate `Camera3D`
   on its own cull layer (default layer 20). Pixelized meshes get that layer in
   `PixelizerGeometryState.bind()`; the main camera gets it removed.
2. `pixelizer_object.gdshader` serves both cameras via the
   `anchor_macros.gdshaderinc` branch on `CAMERA_VISIBLE_LAYERS & meta_bit`. On
   the metadata camera `ANCHOR_META_LIGHT` writes the payload `R =
   anchor_size/32, G = anchor_tag/256, B = view depth` (`ANCHOR_SIZE_SCALE`,
   `ANCHOR_TAG_SCALE`); the main-camera branch grades/clips the albedo.
3. Compositor effects on the main camera, in this array order (same-stage
   effects run in array order — this is the ordering contract, see
   `pixelizer_manager_3d.gd:_ensure_effects`):
   `god_rays` (compute, additive into the scene colour **before** the snapshot)
   → `snapshot` (compute, copies scene colour + depth in one dispatch) →
   `apply_pixelization` (RASTER with depth write-back).
4. The apply raster pass runs the inline anchor search (folded out of the
   old anchor-map compute pass) over the lower-left `pixel_size x pixel_size`
   quadrant — the exact set of offsets that can hold a corner-anchored survivor
   — replicates anchor colours across macro blocks, applies the occlusion guard,
   draws screen-space outlines, and writes the anchor depth into the scene depth
   attachment (`gl_FragDepth`).

Materials are converted per source material (`PixelizerMaterialFactory` cache)
and assigned via `material_override` or per-surface override materials, so
`MeshInstance3D.mesh` replacement (MST chunk rebuilds) survives automatically.
Per-object parameters ride on instance uniforms.

Third-party spatial shaders under an applier cannot call the macros (their
addon must not be edited, and Godot cannot merge their stage functions with the
header). They opt in through the **shader bridge**: an editor-time text transform
writes a separate generated `.gdshader` + a manifest (anchor hooks plus the
bundled cloud toolkit are injected as needed), and runtime only does a manifest
lookup and an in-place `material.shader` swap. See the "Shader bridge contract"
in Additional invariants and the addon `README.md`.

## Status

- Addon core (`addons/pixelizer_3d/`): manager, applier, object, material
  factory, outline palette, LUT/dither core, three wired compositor passes
  (`god_rays` / `snapshot` / `apply`), and the water / sky-clouds /
  point-light-volume / firefly-swarm / day-night / foliage / screen-projection
  shaders + `effects/` nodes.
- Shader bridge (`core/pixelizer_shader_bridge.gd`,
  `core/pixelizer_bridge_{entry,manifest,registry}.gd`,
  `editor/pixelizer_bridge_{plugin,dock}.gd`): editor-time generator + manifest +
  runtime lookup for third-party shaders (MST), including the bundled cloud
  toolkit + shadow term for sources that do not own one. `generate_bridges.gd`
  writes both the test fixtures (`tests/bridge/generated/`) and the demo's
  production manifest (`res://pixelizer_bridges/`, trusted via
  `PixelizerManager3D.bridge_manifests`). Added 2026-09-18.
- Demo: MST + character playground described above.
- `tests/`: runner + diff tool + reference PNGs + capture/log output dirs (see
  `tests/README.md`); `tests/bridge/` holds the headless bridge fixtures and the
  windowed generated-shader compile smoke test.

## Load-bearing invariants

- **Never write/read `ALPHA` in the pixelizer shader** — it moves the material
  to the transparent pipeline. Dither/scissor use `discard` (`ANCHOR_CLIP`).
- **Depth textures are y-flipped** relative to colour/metadata render targets in
  RD. `copy_scene.glsl` unflips the depth copy by sampling
  `vec2(uv.x, 1.0 - uv.y)`; the copy is colour-oriented and all downstream
  passes use plain UVs.
- **A texture cannot be a framebuffer attachment and a uniform in the same
  pass** — that is why the `snapshot` pass exists (it copies scene colour +
  depth in one dispatch; the apply pass attaches the scene colour/depth and
  samples the copies under the `"color_copy"` / `"depth_copy"` keys).
- **Compute cannot write depth.** Depth write-back only works in a raster pass.
- **`draw_list_bind_vertex_buffers_format` (4.7)** — not
  `draw_list_bind_vertex_buffer`. The pipeline's `vertex_format` must be the
  *same* vertex format ID bound at draw time or RD debug validation errors.
- **Push constants** must be a multiple of 4 floats and match the GLSL std430
  struct byte-for-byte (apply pass: 12 floats / 48 bytes).
- **`RenderSceneBuffersRD.create_texture`** with `Vector2i.ZERO` size and
  `layers = 0` gives internal size / view count; textures are resize-safe.
- **Metadata viewport** needs `use_hdr_2d = true` (raw float payload),
  linear tonemap env, no glow/SSAO/fog, `UPDATE_ALWAYS` (see
  `_create_metadata_viewport`).
- The manager syncs the metadata camera in `_process` at priority 301
  (`sync_process_priority`).
- **Camera auto-follow**: the manager has no `camera` export. It resolves
  `get_viewport().get_camera_3d()` every frame (or an explicit
  `set_target_camera()` override), binds the compositor to it, and saves/restores
  `cull_mask`, `compositor`, `h_offset`, `v_offset` and (when
  `manage_camera_size`) `size` for the single bound camera when the active camera
  changes or the manager exits — so switching `Camera3D.current` at runtime just
  works. One
  manager per viewport; simultaneous split-screen is unsupported (the effects
  bail on `view_count > 1`). Camera snap resolves the active camera at call time
  (mover snap is fully shader-side and needs no camera lookup).
- `create_pipeline` for compute must run on the render thread
  (`RenderingServer.call_on_render_thread`); raster pipelines are built lazily
  in `_render_callback` from the derived framebuffer format
  (`rd.framebuffer_get_format(fb)`).
- MSAA stays off — the depth write-back attachment path and the whole pipeline
  assume it (`project.godot` leaves the engine default; metadata/lowres
  viewports force `MSAA_DISABLED` explicitly).

## Additional invariants

- **Low-res mode** always uses a manager-owned `MirrorCamera` inside a
  manager-owned display SubViewport; the user camera stays in place (set
  `current = false`, saved value restored on exit) and is mirrored every frame
  by `_sync_mirror_camera`. The display `SubViewportContainer` uses
  `pixelizer_upscale.gdshader` (resolution-derived texel reconstruction: flat
  interiors, a one-output-pixel boundary ramp) and `scroll_shift` carrying
  `subtexel_remainder` (smooth scroll); the manager pushes `source_size`. The
  `PixelizerGlobals.LOWRES_MODE` global uniform disables the anchor clip in
  materials for that mode. `_update_lowres_camera_size` writes the mirror
  camera; the user camera's size and snap offsets are saved at bind and restored
  on unbind.
- **Per-object instance uniforms** (`anchor_macros.gdshaderinc`):
  `anchor_size`, `anchor_tag`, `anchor_focus`, `edge_tint`,
  `use_grade_lut`, plus `anchor_mode` (0 = PER_OBJECT,
  1 = UNIFIED world-origin anchor), `use_dither` (1 = on; gates both the
  alpha dither and the LUT dither band) and `anchor_mover_snap` (1 = shift the
  mesh so its projected pivot lands on a whole texel). The shader branches on the metadata
  camera for the payload; the anchor mode only changes the projected pivot in
  `ANCHOR_VERTEX`. `PixelizerGeometryState` sets these on bind, and manual
  `PixelizerObject3D` setters push them live (through the owning applier or
  `manager.reconfigure_node`), and `outline_enabled` / `override_outline_color` re-register the
  palette tag (the apply pass samples the palette, not the instance uniform) —
  see the "Outline palette contract" below.
- **Applier inheritance / overrides** (`PixelizerApplier3D`): `pixel_size`,
  `palette_enabled`, `dither_enabled`, `anchor_mode`, `outline_enabled`,
  `shadow_casting` and `mover_snap` use `-1` = inherit (nearest ancestor with a
  set value, then the manager default). Setters call `_refresh_children()` → `rescan()`, which
  re-scans the subtree and re-derives nested appliers, so runtime property
  changes propagate down. `rescan_interval > 0` keeps `_process` alive for a
  periodic scan; otherwise the watcher disables processing when idle.
- **Mover snap** (`PixelizerManager3D.register_mover` / `unregister_mover`, and
  `PixelizerApplier3D.mover_snap`): a **vertex-stage** offset. Registration sets
  the `anchor_mover_snap` instance uniform on the `GeometryInstance3D`; on the
  next draw `ANCHOR_VERTEX(0)` (`anchor_macros.gdshaderinc`) rounds the projected
  pivot to a whole screen texel and shifts the rigid mesh by the matching
  world-space offset (world units per texel derived from `PROJECTION_MATRIX`,
  orthographic-guarded). The scene transform is never read or written per frame,
  so there are no `RenderingServer.frame_pre_draw` / `frame_post_draw` callbacks
  and no save/restore bookkeeping. The mesh must run a pixelizer material (the
  instance uniform is declared by the macros header). Registration is explicit;
  the manager `mover_snap` is the inheritance default for appliers left at `-1`.
- **Subtree watcher**: appliers connect `SceneTree.node_added` once
  (`_enter_tree`) and filter with `is_ancestor_of`; additions queue and drain in
  `_process`, so children finish `_ready` before bind (important for
  firefly/glow material registration). Processing is disabled when the queue and
  the bridge watchdog are idle. Per-object state lives in `_states`
  (id -> `PixelizerGeometryState`); `_prune_states()` drops states whose target
  was freed or left the subtree, restoring authored materials. `_scan` skips
  nested appliers, manual `PixelizerObject3D` children and the
  `pixelizer_ignore` group, applied both at the top of `_scan` and in the child
  loop. Property setters coalesce into one deferred `rescan()`, and each rescan
  resolves the inherited values once (`_resolve_effective`) instead of
  re-walking the ancestor chain per geometry node.
- **Cloud contract**: uniform names in `cloud_fbm.gdshaderinc` (`clouds_enabled`,
  `cloud_noise`, `cloud_sun_dir`, `cloud_height`, `cloud_noise_scale`,
  `cloud_threshold`, `cloud_bands`, `cloud_tightness`, `cloud_octave_drop`,
  `cloud_gap_erosion`, `cloud_detail_strength`, `cloud_wind`,
  `cloud_shadow_strength`, `cloud_shadow_banding_enabled`,
  `cloud_shadow_levels`, `cloud_shadow_softness`) are built by the registered
  cloud **provider** (`PixelizerSkyClouds3D.build_cloud_params()`) and pushed by
  the manager to every registered cloud / pixelized material. With no provider
  the manager pushes neutral params (`clouds_enabled = false`, key defaults).
  Third-party sources without a
  cloud toolkit get the bundled include plus an injected
  `ALBEDO *= 1.0 - cloud_shadow(v_world_pos);` through the shader bridge, so a
  pristine `MarchingSquaresTerrain` receives the same coverage as water, the sky
  deck and the god-ray pass. The manager re-pushes only when the provider
  dictionary's `hash()` or the sun basis changes (`_cloud_dirty` forces a
  rebuild on provider register/unregister).
- **Manager cloud registry**: `_cloud_materials` (`id -> {material}`) is the
  **cloud-field push list only** — pipeline-wide params are global shader
  uniforms (`PixelizerGlobals`). `register_cloud_material` and every
  `register_pixelized_material` opt-in join it; entries are pruned when their
  material is freed. `PixelizerWater3D` / `PixelizerSkyClouds3D` /
  `PixelizerPointLightVolume3D` unregister in `_exit_tree`.
- **Material-factory eviction**: `PixelizerMaterialFactory` keeps a
  `WeakRef(source)` per cache id and drops the cached conversion when the source
  material is freed (MST chunk rebuilds / runtime swaps), bounding the cache.
- The apply pass push-constant block is **12 floats** (48 bytes); the GLSL
  std430 struct must match byte-for-byte and any new field needs a matching pad.
  Outline colour rides the palette, not the push block.
- **Geometry state / single slot iterator**: `PixelizerGeometryState` binds
  `MeshInstance3D`, `MultiMeshInstance3D`, `GPUParticles3D` and `CPUParticles3D`
  through one `_material_slots()` iterator yielding `{source, apply, restore}`
  per authored slot; `bind`/`unbind`/`collect_materials`/the bridge all iterate
  it. Instance uniforms are per node, so sub-instances/particles share the
  node's pixel size and outline id. `MeshInstance3D` keeps surface override
  materials; MMIs and particles get a **duplicated mesh** with converted surface
  materials (or a converted `material_override` when present). Only
  `GPUParticles3D.draw_pass_1` is converted — querying `draw_pass_2..4` when
  unset logs an engine error. Manager APIs `register_multimesh(node, opts)`,
  `register_particles(node, opts)` and `pixelize_node(node, opts)` return the
  `PixelizerGeometryState`; non-empty `opts` create an explicit manual
  `PixelizerObject3D` child, empty `opts` bind a manager-owned state directly.
- **Custom-shader macros** (`anchor_macros.gdshaderinc`): Godot 4.7
  preprocessor limits — no zero-arg macros (all entry points take a throwaway
  first argument: `ANCHOR_VERTEX(0)`), and `return` is illegal in the
  fragment processor function, so the metadata branch is
  `if (ANCHOR_META_ACTIVE(0)) { ANCHOR_META_LIGHT(0); } else { ... }`.
  A material registered via `register_pixelized_material()` is marked with the
  `pixelizer_opt_in` meta and joined to the cloud push list; it must be
  recognized by `PixelizerGeometryState._is_pixelizer_material()` (through
  `manager.is_pixelized_material()`) so the factory never replaces it.
  Pipeline-wide params ride `PixelizerGlobals` (global uniforms), so there is no
  per-material push for them.
  `cloud_fbm.gdshaderinc` is include-guarded (safe to include directly or
  through the macros header). **Function parameters must not shadow globals**:
  Godot rejects a parameter that collides with any source declaration
  ("Redefinition of 'world_pos'"), and these includes sit next to arbitrary
  third-party globals, so every helper parameter is `anchor_*` / `cloud_*`
  prefixed (e.g. MST declares `varying vec3 world_pos`).
- **Shader bridge contract** (`core/pixelizer_shader_bridge.gd`,
  `core/pixelizer_bridge_{entry,manifest,registry}.gd`,
  `editor/pixelizer_bridge_{plugin,dock}.gd`):
  - **Generation is editor-only.** `PixelizerShaderBridge` is a pure static text
    transform (reads files; no live materials/RenderingServer). The game path
    must never build/generate shader source — no `Shader.new().code = ...`
    anywhere under `core/nodes/compositor`. Runtime does a manifest lookup and at
    most one in-place `material.shader = <pre-generated Shader>`
    (`PixelizerBridgeRegistry.apply`). Keep it that way.
  - **Approval is explicit and not automatic.** `PixelizerBridgeEntry.approved`
    defaults false; `excluded` is sticky and persisted. The runtime registry
    (`PixelizerBridgeRegistry`) maps only approved entries whose
    `rules_version == INJECTION_RULES_VERSION` and whose `output_path` exists; it
    never hashes or reads source files. Stale detection and `generated_hash`
    drift reporting are editor/dock concerns. Unapproved / excluded /
    version-mismatch / missing-output entries are never applied, so the failure
    mode is always "rendered as authored", never a broken shader.
    `PixelizerGeometryState.bind()` leaves unsupported custom materials untouched
    and logs a one-shot hint.
  - **`auto_bridge_custom_shaders` defaults to `false`** (safety gate) on
    `PixelizerManager3D`; enable it (and set `bridge_manifests`) to let objects
    swap in approved bridges. The manifest list is the trust boundary — there is
    no global singleton. The `bridge_manifests` setter rebuilds the registry;
    diagnostics are `get_bridge_mapped_count()` / `get_bridge_warnings()`.
  - **The source addon is never written.** The dock refuses an `output_dir` that
    lies inside any scanned root. `tests/bridge/bridge_fixtures.gd` hashes the
    whole `addons/MarchingSquaresTerrain/resources/shaders` tree before/after
    scan+generate and asserts it is byte-identical.
  - **Injection vocabulary.** Generated shaders include
    `anchor_macros.gdshaderinc` and use the `PIXELIZER_*` aliases defined at the
    end of that header (`PIXELIZER_VERTEX(0)` first in `vertex()`;
    `PIXELIZER_META_ACTIVE` / `PIXELIZER_META_LIGHT` then `PIXELIZER_CLIP(...)`
    last in `fragment()`). `pixelizer_macros.gdshaderinc` is a forwarding shim
    only (no duplicate definitions). Cloud handling is **conditional**: a source
    whose flattened text owns `clouds_enabled` / `cloud_shadow` /
    `cloud_coverage_from_noise` gets the macros include wrapped in
    `#define PIXELIZER_NO_CLOUD` / `#undef` (compiling out the bundled
    `cloud_fbm.gdshaderinc` and `anchor_grade()`, so its own toolkit does not
    collide); every other source includes the bundled toolkit and gets
    `ALBEDO *= 1.0 - cloud_shadow(v_world_pos);` injected as the first fragment
    statement. Bump `INJECTION_RULES_VERSION` whenever the transform changes
    (current: 2).
  - **`\bALPHA\b` only** matches an ALPHA write — `ALPHA_SCISSOR_THRESHOLD` must
    not (fixture asserts this); opaque fragments clip `1.0`.
  - **Watchdog**: some systems create/replace the rendered material after the
    first bind (MST's runtime texture baker swaps every chunk mesh to its own
    `mst_terrain_baked.gdshader` duplicate, and chunks may be mesh-less while
    they rebuild). `PixelizerApplier3D` keeps a throttled `_watch_ids` poll
    (shared `_process`, `BRIDGE_WATCH_INTERVAL`) after a swap actually happened —
    including when the material was already bridged through a **shared** sibling
    material — or while there is nothing to inspect yet; it then retries the
    bind and registers newly mapped materials. `PixelizerGeometryState.unbind()`
    restores the authored shaders.
  - The dock registers via `add_control_to_dock` (deprecated in 4.7 in favour of
    `add_dock(EditorDock)`), called dynamically so the deprecation analyzer stays
    quiet, and removes via `remove_control_from_docks`.
- **Outline palette contract** (`core/pixelizer_outline_palette.gd` + the apply
  pass): a 256x2 RGBA8 texture. Row 0 = silhouette colour, row 1 = inner
  (id / depth-discontinuity) colour; the alpha channel is an **opacity**
  (`0` = leave the sampled scene colour, `1` = replace it). The apply shader
  composites `mix(scene, outline_rgb, opacity)`.
  `PixelizerManager3D.set_outline_color()` writes **both** rows at opacity 1, so
  a per-applier `override_outline_color` also colours elevated-rim depth edges;
  `set_outline_enabled(false)` writes opacity 0 and re-enabling restores the
  `outline_palette` row (or `outline_color`) — the apply shader needs no branch.
  `PixelizerOutlinePalette` stores per-row `silhouette_alpha` / `inner_alpha`
  (float 0..1), replacing the old multiply-flag representation.
  `PixelizerApplier3D.outline_enabled` (-1 inherit / 0 off /
  1 on) and `PixelizerObject3D.outline_enabled` expose this per subtree.
  Outlines paint whole macro blocks, so a tag viewed at grazing angles (dense
  depth steps) can flood with the outline colour; terrain-like subtrees should
  set `outline_enabled = 0`.
- **Palette LUT contract**: `PixelizerManager3D.global_palette_lut` (Texture2D)
  must keep its exact name — external pipeline components probe the property
  list and push their LUT there. The LUT is 256x256,
  `x = r + 16*b`, `y = g + 16*ditherBand` (16^3 gamma-space colours x 16
  ordered-dither bands), baked by `PaletteLUT` (core/) with
  `DitherMatrix` (core/). The shader sampler is the
  `PixelizerGlobals.PALETTE_LUT` global uniform
  (`global uniform sampler2D pixelizer_palette_lut : source_color,
  filter_nearest, repeat_disable`) — `source_color` is mandatory (ALBEDO is
  linear; without it the palette renders washed out / hue-shifted). Grading runs
  inside `ANCHOR_GRADE` (after `ANCHOR_CLIP`), so the graded colour rides the
  anchor fragment; the dither band comes from the object-grid macro-pixel delta
  (`anchor_macro_delta`), never screen space. The pipeline-wide palette params
  (`pixelizer_palette_lut`, `pixelizer_palette_grading_enabled`,
  `pixelizer_palette_dither_enabled`) are global uniforms set once by the manager
  (`_palette_dirty` gate); per-object opt-out is the instance uniform
  `use_grade_lut` (`PixelizerObject3D.palette_enabled`).
- **God-ray pass contract**: `PixelizerGodRayEffect` runs FIRST in the
  PRE_TRANSPARENT array and `imageStore`s an additive term into the scene
  colour layer (an `rgba16f` `image2D`) before the `snapshot` pass copies it, so
  the rays are replicated into macro-pixels by the apply pass. The engine depth
  layer is y-flipped (as in `copy_scene.glsl`) — the ray pass samples
  `vec2(uv.x, 1.0 - uv.y)` for the same screen pixel. Parameters ride a
  **uniform buffer** (not push constants): 15 vec4s / **240 bytes**, std140,
  and `PixelizerGodRayEffect.PARAMS_SIZE` must match byte-for-byte. The cloud
  field mirrors `cloud_fbm.gdshaderinc` (`cloud_noise_at` +
  `cloud_coverage_from_noise`) so rays share gaps with the shadows. The march is
  a Beer-Lambert transmittance integration (`accum += transmittance * gap *
  fade * ds; transmittance *= exp(-extinction * ds)`) with a per-pixel jittered
  start, not an independent sum of samples; the result is scaled by
  `ray_quantum` **before** the `ray_quantize_bands` step. Tuning property names
  (`ray_steps` … `ray_distance_falloff`) are an external contract via
  `manager.get_god_ray_pass()` (names kept for API stability; the meaning of
  `ray_decay` is the extinction coefficient). The pass is manager-owned
  (`PixelizerManager3D.ray_pass`, auto-created disabled; never rebuilt or
  swapped); `PixelizerGodRays3D` only toggles `rays_enabled`.
  The phase reads the wall clock (`Time.get_ticks_msec()`) while `time_override`
  `< 0`; a value `>= 0` pins it.
- **Sky cloud sheet**: `PixelizerSkyClouds3D` is the cloud **provider**
  (`register_cloud_provider(self)`) and also a cloud consumer
  (`register_cloud_material()`), so the deck follows its own
  noise/height/wind/threshold/bands (the 15 cloud exports moved off the
  manager). Opaque alpha-scissor only. The sheet
  samples a **second, mipmapped** copy of the noise (`cloud_noise_hi`): the
  include's `cloud_noise` is `filter_linear` (MST contract) and the deck is
  viewed at near-grazing angles, where a mip-less 256px noise aliases into dot
  moiré (and the aliased sheet depth makes the god-ray march jitter). The
  manager generates the noise with `generate_mipmaps()`. The helper pushes
  `cam_fwd = (0,0,0)` for perspective cameras, and flips the erosion side when
  `cam_fwd.y > 0` (deck above an upward-looking camera).
- **`EMISSION` is ignored for `unshaded` materials in 4.7.1** — an additive
  unshaded volume must write `ALBEDO`.
- **Point-light volume contract** (`shaders/point_light_volume.gdshader` +
  `PixelizerPointLightVolume3D`): additive unshaded sphere centred on the
  light, `blend_add, unshaded, cull_disabled, depth_draw_never,
  depth_test_disabled, shadows_disabled, fog_disabled`. Both hemispheres reach
  the same pixels, so fragments nearer than the light centre are discarded
  (`length(VERTEX) < length(v_light_view)`) for exactly one evaluation per
  pixel. The pool is evaluated on the opaque surface reconstructed from
  `hint_depth_texture` + `INV_PROJECTION_MATRIX`; the view-ray halo uses the
  closest approach; the occlusion test samples the depth at the light's
  projected position (`v_light_uv`, projected in the vertex stage) and hides
  the whole contribution when geometry sits in front of the light
  (`occlude_by_depth`; `depth_slack`, default 0.5, keeps a bulb mesh at the
  light centre from occluding its own light). Apply the occlusion test to the
  whole contribution, never per-ray. It includes `anchor_macros.gdshaderinc`
  and `discard`s in the metadata branch, so it can live under an applier; the
  helper registers its material (`register_pixelized_material`) and
  **unregisters on `_exit_tree`** (`unregister_pixelized_material`) so rebuilds
  never leave freed materials in the registry.
- **Water contract** (`shaders/water.gdshader` + `PixelizerWater3D`): always
  OPAQUE (`render_mode cull_back, shadows_disabled`, never write `ALPHA` —
  pixelized objects only write anchor depth). Banded deep→shallow from the
  `coast` instance uniform (`1.0` = shore, `0.0` = open water); `wave_phase`
  is a per-tile animation offset that a contiguous grid must leave at 0
  (otherwise vertex waves and the 4-sine normal field seam at tile borders).
  Cloud receiver via `cloud_fbm.gdshaderinc` + `register_cloud_material()`.
  Godot has a built-in `TAU` shader constant — never redeclare it.
- **Deferred watcher callbacks**: `PixelizerApplier3D._on_child_entered` takes
  an **untyped** parameter and checks `is_instance_valid` — deferred calls can
  carry a child that was already freed, and a typed `Node` parameter fails to
  bind.
- **Godot 4.7 `Curve` API**: `Curve.interpolation_mode` does not exist.
  Interpolation is per-point: `set_point_left_mode(i, Curve.TANGENT_LINEAR)`
  (and right mode) for straight segments; default `TANGENT_FREE` is a smooth
  Hermite.
- **Shader comments are `//` only** — a `##` doc-comment line is an unknown
  preprocessor directive and fails compilation with
  "Tokenizer: Unknown character #35: '#'" pointing at the *include* line.
- **`INSTANCE_ID` is stage-scoped**: it is only valid inside `vertex()` /
  `fragment()`, not in helper functions — pass it in as an argument.
  `LIGHT_VERTEX` is fragment-stage only; in `vertex()` use `VERTEX`.
- **Day/night rig** (`nodes/pixelizer_day_night_3d.gd`): normalized
  `time_of_day` (0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset); the sun is
  driven by `rotation_degrees = (-elevation, azimuth, 0)` from the analytic sine
  arc (or optional `elevation_curve`/`azimuth_curve`) plus `sun_color_ramp` /
  `sun_energy_ramp`, and the `WorldEnvironment` gets ambient/sky
  (`ProceduralSkyMaterial` colours)/fog/background-energy ramps. The rig assigns
  `manager.sun = sun`, and the manager reads the sun node every frame — cloud
  shadows, cloud deck and god-ray tint follow automatically.
  `set_time_of_day()`/`advance_time()`/`set_fast_forward()` are the runtime API.
  At exactly 0° elevation the ground self-shadows into stripes (grazing
  shadow-map acne).
- **Foliage contract** (`shaders/grass_billboard.gdshader`,
  `shaders/tree_leaves.gdshader`): both include `anchor_macros.gdshaderinc`
  and must be registered with `register_pixelized_material()`. Cards are unit
  quads; the shader lifts `VERTEX.y + 0.5` so the node/MultiMesh origin is the
  base. Grass is a Y-axis billboard, leaves a full billboard; both write
  `POSITION` directly, then **overwrite `v_world_pos`/`v_view_depth`** after
  `ANCHOR_VERTEX(0)` (the macro sampled the pre-billboard VERTEX), set
  `NORMAL` to world-up and `LIGHT_VERTEX` (fragment) to the card-centre view
  position. Wind is world-space, amplitude = `wind_strength` × card world
  height × bend², clock quantised by `wind_fps` (stepped pixel animation).
  Atlas variation hashes world origin + `INSTANCE_ID`; alpha-scissor only via
  `ANCHOR_CLIP`.
- **Screen projection contract** (`shaders/screen_projection.gdshader`): the
  material is registered for clouds; the render resolution (not the window) rides
  the `PixelizerGlobals.SCREEN_SIZE` global uniform
  (`global uniform vec2 pixelizer_screen_size`), set in the manager's
  `_enter_tree` and on every `render_resolution` change via
  `PixelizerGlobals.set_param()`. `PixelizerGlobals.ensure()` registers the
  globals exactly once (guarded by a static dict plus
  `ProjectSettings.has_setting("shader_globals/<name>")`); never call
  `global_shader_parameter_get` at runtime. Projection UV =
  `(SCREEN_UV * pixelizer_screen_size - origin_px) / texture_size`, so texels
  land on the render pixel grid and the pattern is screen-locked.
- **Character FBX import** (`demo/assets/characters/`): ufbx converts the source
  Z-up/cm to Godot Y-up/meters.
