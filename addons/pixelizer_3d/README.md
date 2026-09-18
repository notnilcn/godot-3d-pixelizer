# Pixelizer3D

A Godot 4.7 (Forward+) 3D pixel-art pipeline for Godot — per-object macro-pixel
sizes, screen-space outlines with a 256-id palette, subject focus, palette
LUT + ordered-dither grading, a projection-space orthographic camera snap, god
rays, cloud shadows, water, foliage, fireflies, point-light volumes, a day/night
rig and optional low-res SubViewport mode.

The renderer combines ideas from several open-source Godot demos (see the
repository `CREDITS.md` for the full inspiration list).

## Requirements

- Godot **4.7** with the **Forward+** renderer (the anchor pipeline needs
  `CompositorEffect`, storage textures and normal-roughness).
- MSAA/TAA off, render scale 1.0 (the defaults in `project.godot`).
- `Compatibility`/headless degrade with a warning; low-res mode also runs on
  `Mobile`, but the anchor pipeline is Forward+ only.

## Contents

| Path | What lives there |
|---|---|
| `plugin.cfg`, `plugin.gd` | Addon registration; adds the **Bake PaletteLUT to PNG** tool-menu item and builds the shader-bridge dock. |
| `nodes/` | The core runtime/config nodes: `PixelizerManager3D`, `PixelizerApplier3D`, `PixelizerObject3D` and `PixelizerDiagnosticsOverlay`. See below. |
| `effects/` | Optional per-scene effect nodes (`water`, `sky_clouds`, `point_light_volume`, `fireflies`, `day_night`, `camera_controller`). Place only the effects a scene needs. |
| `compositor/` | The `CompositorEffect` subclasses that drive the render passes (`*_effect.gd`). |
| `shaders/` | Runtime spatial shaders (`.gdshader`) and shared includes (`.gdshaderinc`). |
| `shaders/compute/` | The GLSL compute/ raster passes used by the compositor effects (`*.glsl`). |
| `core/` | Palette LUT, dither matrix, outline palette, material factory and the shader-bridge data types. |
| `editor/` | Editor-only tooling: the bridge dock/plugin and the palette baker. |

## Quick start

```gdscript
# 1. World setup: one manager + a sun. The manager auto-follows the viewport's
#    current Camera3D, so there is no camera to wire (use set_target_camera()
#    to pin one explicitly).
var manager := PixelizerManager3D.new()
manager.sun = sun
manager.pixel_size = 3
add_child(manager)

# 2. Wrap content in an applier; everything under it is pixelized
#    (subtree watcher catches runtime spawns too). Applier properties left at
#    -1 inherit from the parent applier / manager.
var applier := PixelizerApplier3D.new()
applier.pixel_size = 3
applier.anchor_mode = PixelizerObject3D.AnchorMode.UNIFIED  # one lattice for the group
applier.dither_enabled = 1
add_child(applier)
applier.add_child(my_model)

# 3. Custom spatial shaders opt in with the macros header:
#    #include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"
manager.register_pixelized_material(my_water_material)

# 4. Optional: snap moving objects onto the pixel lattice in the vertex stage
#    (the scene transform is never touched). manager.register_mover() sets the
#    `anchor_mover_snap` instance uniform on a GeometryInstance3D, so the mesh
#    must run a pixelizer material.
manager.register_mover(my_moving_object)   # or applier.mover_snap = 1

# 5. Optional effects are self-contained scene nodes — add only what the scene
#    needs. Each registers itself with the manager in _ready and unregisters in
#    _exit_tree, so effects are composable per scene:
#      PixelizerSkyClouds3D      # cloud shadows + optional deck (deck_enabled)
#      PixelizerGodRays3D        # god rays (toggles the manager's ray pass)
#      PixelizerWater3D          # cloud-shadow-receiving water tile
#      PixelizerFireflies3D      # MultiMesh firefly swarm
#      PixelizerDayNight3D       # sun + environment rig
#      PixelizerPointLightVolume3D
#      PixelizerCameraController3D
#    With no cloud node the manager pushes neutral cloud params; the manager's
#    ray pass stays disabled until a PixelizerGodRays3D enables it
#    (get_god_ray_pass() is always valid for external tuning).
```

`PixelizerObject3D` is a **manual-only** per-object override: place one as a
child of a supported geometry node (the applier no longer creates them). It
exposes live setters (`pixel_size`, `outline_id`, `outline_color`,
`outline_enabled`, `palette_enabled`, `anchor_mode`, `dither_enabled`), so
runtime changes reach objects that already bound. Without one, per-object state
lives in a `PixelizerGeometryState` owned by the applier/manager.
`outline_color` overrides **both** the silhouette and inner-edge (depth-edge)
rows of the tag's outline palette; `outline_enabled = false` (applier or object)
hides that tag's outline entirely (its palette rows get opacity 0, which the
apply pass composites as `mix(scene, outline_rgb, opacity)`). The applier inherits
`outline_enabled` like the other `-1` properties. `anchor_mode` `UNIFIED` anchors the
macro blocks to the world origin (a common lattice for a group) instead of each
object's own pivot.

See `nodes/pixelizer_manager_3d.gd` for the full export set and the generic
`register_*` slots (`register_multimesh`, `register_particles`, `pixelize_node`,
`register_cloud_provider`, `register_cloud_material`,
`register_pixelized_material`). The god-ray pass is manager-owned
(`PixelizerManager3D.ray_pass`) and fixed at compositor index 0.

## Composition model

The manager exposes shared services only; every visual effect is an optional
`effects/` node that registers itself. Add only the effects a scene needs:

| Scene wants | Nodes to place |
|---|---|
| Anchor pixelization only | `PixelizerManager3D` + `PixelizerApplier3D` |
| + cloud shadows (no visible deck) | + `PixelizerSkyClouds3D` with `deck_enabled = false` |
| + visible cloud deck | + `PixelizerSkyClouds3D` (set `cloud_shadow_strength = 0` for deck only) |
| + god rays | + `PixelizerGodRays3D` |
| + water / fireflies / day-night / … | + the matching `effects/` node |

Cloud shadows/rays without a deck: `PixelizerSkyClouds3D` with
`deck_enabled = false`. A scene with no cloud node renders cloud-free (the
manager pushes neutral params). The manager's ray pass stays disabled until a
`PixelizerGodRays3D` enables it; `manager.get_god_ray_pass()` is always valid
for external tuning.

## Nodes

The core runtime/config nodes live in `nodes/`; the optional effects in
`effects/`.

| Node | Role |
|---|---|
| `PixelizerManager3D` | One per viewport. Owns the metadata `SubViewport` + camera, attaches the compositor effects to the active `Camera3D` (auto-follow; `set_target_camera()` to pin), and keeps the metadata camera in sync. No effect settings — the effect nodes own theirs. |
| `PixelizerApplier3D` | Subtree pixelizer. Every supported geometry node under it is bound through a `PixelizerGeometryState` (no auto-created nodes). Watches `SceneTree.node_added` so runtime spawns are picked up. `-1` properties inherit from the parent applier, then the manager. |
| `PixelizerObject3D` | **Manual-only** per-object override: place one as a child of a supported geometry node. Runtime-only; exposes live `pixel_size` / `outline_*` / `palette_enabled` / `anchor_mode` / `dither_enabled` / `disable_shadows`. |
| `PixelizerDiagnosticsOverlay` | Optional HUD-only status readout (pipeline state, FPS, draw calls). Toggle key defaults to `Tab`; live tuning is done through Godot's remote inspector. |
| `PixelizerSkyClouds3D` | Cloud **provider** (owns the 15 cloud-field params + noise) and optional visible deck. `enabled` = node on/off, `deck_enabled` = visible sheet, `clouds_enabled` = shader master toggle. |
| `PixelizerGodRays3D` | God-ray toggle node; writes `manager.get_god_ray_pass().rays_enabled`. The pass itself is manager-owned and fixed at compositor index 0. |
| `PixelizerWater3D` | Opaque banded water tile (`water.gdshader`); registers its material for cloud-shadow uniforms. |
| `PixelizerPointLightVolume3D` | Additive, banded point-light volume with a view-ray halo and depth-tested occlusion. |
| `PixelizerFireflies3D` | Deterministic emissive firefly swarm (seed-stable positions) rendered as two `MultiMeshInstance3D` draw calls (bodies + camera-facing additive glow quads from `firefly_glow.gdshader`), with depth-tested glow occlusion. |
| `PixelizerDayNight3D` | Drives a `DirectionalLight3D` and the `WorldEnvironment` (ambient/sky/fog) from a normalized `time_of_day`. |
| `PixelizerCameraController3D` | Input-agnostic orbit / yaw-step / zoom controller; zoom goes through the manager's `view_zoom`. |

Supported pixelization targets: `MeshInstance3D`, `MultiMeshInstance3D`,
`GPUParticles3D` and `CPUParticles3D`. Instance uniforms are per node, so a
MultiMesh's sub-instances and a particle system's particles share the node's
pixel size / outline id.

## Bridging third-party shaders (the shader bridge)

Some spatial shaders live in addons that must not be edited (a vendored terrain
addon is the canonical case). Godot cannot merge their `vertex()`/`fragment()`
with `anchor_macros.gdshaderinc` (stage built-ins are illegal in helper
functions), so they can never call `ANCHOR_*` themselves. The **shader bridge**
rewrites the *source text* into a separate generated asset. Generation is an
explicit, reviewable editor action; the game only ever performs a manifest
lookup and an in-place shader swap. **The source addon is never written to.**
Generated files are plain `.gdshader` text: diffable in git, reviewable, and
safe to delete.

### When to use it

- A third-party `shader_type spatial;` shader (with a `fragment()`) under an
  applier is left unpixelized and logs a one-shot hint.
- The shader cannot be edited to `#include` the macros yourself (vendored
  addon, read-only package, upgrade churn).

Do **not** use it for shaders you own — include `anchor_macros.gdshaderinc` and
call `ANCHOR_VERTEX(0)` / `ANCHOR_CLIP()` / `ANCHOR_META_LIGHT(0)` directly, then
`manager.register_pixelized_material(material)`.

### Workflow

1. `Project > Tools > Pixelizer3D Shader Bridge` (or the docked panel) opens the
   bridge dock.
2. Set the **manifest** path (created on demand as a `.tres`), the **output
   dir** (default `res://pixelizer_bridges/`) and one or more **scanned roots**.
   The output dir must be **outside** every scanned root — the dock refuses
   otherwise, so it can never write into an addon.
3. **Scan** lists every spatial shader with a `fragment()`, with its hook sites
   (Vertex / Fragment / Alpha) and status: `New`, `Excluded`, `Stale`,
   `Up-to-date`, `Missing output`, `Drift`, `Not bridgeable`. Already-opted-in
   shaders (macros include / `ANCHOR_VERTEX` / `PIXELIZER_VERTEX`) are rejected.
4. **Approve** the rows you want (never automatic; new rows default to
   unapproved) and **Preview** to inspect the injected lines and the generated
   source diff.
5. **Dry run** reports what would be written without touching disk.
   **Generate approved** writes the generated `.gdshader` files and saves the
   manifest. **Clean generated** deletes only the generated files (approval
   state is preserved).

### What injection does

The generator (rules version `2`) flattens `#include`s recursively (relative to
the including file, include-guard semantics, depth cap 16, fail on missing),
then:

- `fragment()`: injects `ALBEDO *= 1.0 - cloud_shadow(v_world_pos);` followed by
  `if (PIXELIZER_META_ACTIVE(0)) { PIXELIZER_META_LIGHT(0); }` and
  `PIXELIZER_CLIP(ALPHA)` when the fragment writes `ALPHA` (`\bALPHA\b`, so
  `ALPHA_SCISSOR_THRESHOLD` is not matched), else `PIXELIZER_CLIP(1.0)`. The
  cloud term is skipped when the source owns its own cloud toolkit.
- `vertex()`: injects `PIXELIZER_VERTEX(0);` after the opening brace, or appends
  a synthesized `void vertex() { PIXELIZER_VERTEX(0); }`.
- global scope, **cloud-owning source** (flattened text declares
  `clouds_enabled` / `cloud_shadow` / `cloud_coverage_from_noise`):
  `#define PIXELIZER_NO_CLOUD` around the macros include, `#undef` immediately
  after, so its own toolkit does not collide with the bundle's
  `cloud_fbm.gdshaderinc`.
- global scope, **cloud-less source**: the macros include pulls in the bundled
  `cloud_fbm.gdshaderinc`, so the injected shadow term reads the same `cloud_*`
  uniforms the manager pushes to every registered cloud / pixelized material.
- prepends a banner with the source path, source sha256 and `rules_version`.

The generated file is self-contained (no relative includes) and compiles
standalone. `anchor_macros.gdshaderinc` exposes `PIXELIZER_*` aliases for the
native `ANCHOR_*` entry points, which is the vocabulary the bridge injects.

### Manifest contract and drift

`PixelizerBridgeManifest` (`.tres`) holds `output_dir`, `roots` and an array of
`PixelizerBridgeEntry` (`source_path`, `source_hash`, `approved`, `excluded`,
`has_vertex`, `has_fragment`, `writes_alpha`, `output_path`, `generated_hash`,
`rules_version`).

- `source_hash` is the sha256 of the **source file bytes**. The dock compares it
  and reports the entry as **Stale** when it changes; regenerate from the dock to
  refresh it. Runtime never hashes sources.
- `generated_hash` is the sha256 of the generated file. A mismatch is reported as
  `Drift` (e.g. a hand edit) by the dock.
- Entries generated with an older `rules_version` are not applied.
- Unapproved, excluded, missing-output or version-mismatched entries are
  **never** applied. The failure mode is always "rendered as authored", never
  "broken shader".

### Runtime application

`PixelizerManager3D.bridge_manifests` names the manifests the manager trusts
(no global singleton). On `_ready` (and whenever the list changes) it builds a
`PixelizerBridgeRegistry` mapping `source_path -> output_path`. In
`PixelizerObject3D._apply()` each unregistered custom `ShaderMaterial` gets one
`registry.apply(mat)` call: a lookup, and at most one in-place
`material.shader = generated`. There is **no** `Shader.new().code = ...`, no
runtime source generation, no source-file I/O and no hashing anywhere in the game
path. The in-place swap is safe
because the material is per-object (a system that duplicates its material per
instance is the usual case) and the swap only happens for explicitly approved
sources. A throttled watchdog re-runs the lookup to catch systems that create or
replace the rendered material after the first apply — e.g. a runtime texture
baker that swaps every chunk mesh to its own baked-shader duplicate. It arms
after a swap actually happened (including through a shared, sibling-bridged
material) or while an object has no mesh/material to inspect yet.

`auto_bridge_custom_shaders` is the **safety switch** (default `false`): while
off, custom shaders are left authored even if a manifest entry is approved. Set
it to `true` (or per manager instance) to enable manifest-driven swaps.

Manager diagnostics: `get_bridge_mapped_count()` and `get_bridge_warnings()`
(version drift, missing outputs).

## Asset notes

- ufbx imports source Z-up/cm assets to Godot Y-up/meters automatically; no
  per-asset conversion is required by the addon.

## Docs

`AGENTS.md` (repository root) is the architecture + load-bearing invariants
reference.
