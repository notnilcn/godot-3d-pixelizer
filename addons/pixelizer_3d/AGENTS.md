# AGENTS.md — pixelizer_3d (usage)

How to use the addon. Requirements: Godot 4.7 Forward+ only; MSAA/TAA off, render scale 1.0. Compatibility/headless degrade with a warning.

## Minimal setup

1. One `PixelizerManager3D` per viewport. It auto-follows `get_viewport().get_camera_3d()`; no camera wiring. Set `sun` for cloud/ray tint. Optionally `set_target_camera(cam)` to pin.
2. One `PixelizerApplier3D` around any subtree to pixelize. It watches `SceneTree.node_added`, so runtime spawns are picked up. `rescan()` is the manual fallback.
3. Optional per-scene `effects/` nodes — add only what the scene needs; each self-registers in `_ready`.

```gdscript
var manager := PixelizerManager3D.new()
manager.sun = sun
manager.pixel_size = 3          # default macro-pixel size for inheriting appliers
add_child(manager)

var applier := PixelizerApplier3D.new()
applier.pixel_size = 3
applier.anchor_mode = PixelizerObject3D.AnchorMode.UNIFIED
applier.add_child(my_model)
add_child(applier)

# optional effects (self-register):
PixelizerSkyClouds3D            # cloud shadows + optional visible deck
PixelizerGodRays3D              # enables the manager-owned ray pass
PixelizerWater3D
PixelizerFireflies3D
PixelizerDayNight3D
PixelizerPointLightVolume3D
PixelizerCameraController3D
```

## Nodes

| Node | Use |
|---|---|
| `PixelizerManager3D` | One per viewport. Owns shared services, no per-effect settings. |
| `PixelizerApplier3D` | Binds supported geometry in its subtree. Nested appliers own their subtree. |
| `PixelizerObject3D` | Manual-only per-object override: add as a child of a `MeshInstance3D`/`MultiMeshInstance3D`/`GPUParticles3D`/`CPUParticles3D`. Live setters. |
| `PixelizerDiagnosticsOverlay` | Optional HUD status; toggle key `Tab`. |

Supported targets: `MeshInstance3D`, `MultiMeshInstance3D`, `GPUParticles3D`, `CPUParticles3D`. Instance uniforms are per node, so sub-instances/particles share the node's pixel size and outline id.

## Applier inheritance

Properties `pixel_size`, `palette_enabled`, `dither_enabled`, `anchor_mode`, `outline_enabled`, `shadow_casting`, `mover_snap` use `-1` = inherit (nearest ancestor applier, then manager default). Setters live-refresh the subtree. Other `PixelizerApplier3D` fields: `outline_id`, `override_outline_color`/`outline_color`, `rescan_interval`, `ignore_group` (default `pixelizer_ignore`).

`anchor_mode`: `PER_OBJECT` anchors each object to its own pivot; `UNIFIED` anchors a group to one world-origin lattice (needed for contiguous meshes, e.g. terrain chunks, to avoid false inner-edge outlines).

## Per-object override (`PixelizerObject3D`)

Add one manually as a geometry child, then set `pixel_size`, `outline_id`, `outline_color`, `override_outline_color`, `outline_enabled`, `palette_enabled`, `dither_enabled`, `anchor_mode`, `disable_shadows`, `enabled`. Changes apply live through the owning applier or `manager.reconfigure_node()`.

## Manager API / fields

- Groups: one `pixelizer_manager` group; `PixelizerManager3D.resolve_manager(node)` resolves ancestor → group.
- Registration: `pixelize_node(node, opts)`, `register_multimesh(node, opts)`, `register_particles(node, opts)` return a `PixelizerGeometryState`. `opts` (any non-empty): `pixel_size`, `outline_id`, `outline_color`, `override_outline_color`, `outline_enabled`, `palette_enabled`, `dither_enabled`, `anchor_mode`, `disable_shadows`, `mover_snap`.
- Custom shaders: `register_pixelized_material(mat)` / `unregister_pixelized_material(mat)`. Opted-in materials include `anchor_macros.gdshaderinc` and are never replaced by the factory.
- Mover snap: `register_mover(node)` / `unregister_mover(node)`. Vertex-stage lattice snap; the mesh must run a pixelizer material. Orthographic only.
- Outlines: `set_outline_color(id, color)` (both silhouette + inner rows), `set_outline_enabled(id, enabled)`, `allocate_outline_id()`, `outline_palette`.
- Focus: `focus_subtree(root)` / `unfocus_subtree(root)`, or `auto_focus` + `auto_focus_target`. Focused pixels use reserved edge tag 255.
- Clouds: `register_cloud_provider(obj)` (any Object with `build_cloud_params(sun)->Dictionary`), `register_cloud_material(mat)`, `unregister_cloud_material(mat)`.
- God rays: `get_god_ray_pass()` — always valid; tune ray exports on it. `PixelizerGodRays3D` only toggles `rays_enabled`.
- Key fields: `enabled`, `mode` (`ANCHOR`/`LOW_RES`), `render_resolution`, `texel_density`, `view_zoom`, `manage_camera_size`, `pixel_size`, `depth_occlusion`, `snap_camera`, `snap_origin`, `sun`, `global_palette_lut` (name is a contract), `dither_enabled`, `outline_enabled`, `outline_threshold`, `debug_view` (0-9).

## Writing a custom spatial shader

Include the macros, call the entry points, then register the material:

```glsl
#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

void vertex() { ANCHOR_VERTEX(0); /* ... */ }
void fragment() {
    if (ANCHOR_META_ACTIVE(0)) { ANCHOR_META_LIGHT(0); }
    else { /* ... */ ANCHOR_CLIP(1.0); }
}
```

```gdscript
manager.register_pixelized_material(my_material)
```

Never read/write `ALPHA` (moves the material to the transparent pipeline); use `ANCHOR_CLIP` / `discard`. Comments must be `//` only. Pipeline-wide params ride global uniforms, so no per-material push is needed.

## Shader bridge (third-party shaders)

For vendored spatial shaders that must not be edited (e.g. MarchingSquaresTerrain) and cannot include the macros. The source is never written.

1. `Project > Tools > Pixelizer3D Shader Bridge` (or the dock).
2. Set manifest path (`.tres`), output dir (default `res://pixelizer_bridges/`, must be outside every scanned root), and scanned roots.
3. **Scan** → **Approve** rows → **Generate approved** (never automatic). `Dry run` reports without writing; `Clean generated` deletes only generated files.
4. Point the manager at the manifest and enable swaps:

```gdscript
manager.bridge_manifests = [load("res://pixelizer_bridges/pixelizer_bridge_manifest.tres")]
manager.auto_bridge_custom_shaders = true   # default false (safety gate)
```

Runtime only does a manifest lookup + in-place `material.shader` swap; unapproved / excluded / stale / version-mismatched entries are never applied ("rendered as authored"). Diagnostics: `get_bridge_mapped_count()`, `get_bridge_warnings()`. Regenerate after any source shader change or `INJECTION_RULES_VERSION` bump.

## Composition per scene

| Scene wants | Place |
|---|---|
| Pixelization only | `PixelizerManager3D` + `PixelizerApplier3D` |
| + cloud shadows, no deck | `PixelizerSkyClouds3D` with `deck_enabled = false` |
| + visible deck only | `PixelizerSkyClouds3D` with `cloud_shadow_strength = 0` |
| + god rays | `PixelizerGodRays3D` |
| + water / fireflies / day-night / volume / camera | matching `effects/` node |

No cloud node → cloud-free (manager pushes neutral params). Ray pass stays disabled until a `PixelizerGodRays3D` enables it.
