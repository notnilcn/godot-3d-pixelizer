# Yūgen's Terrain Authoring Toolkit — Hex Terrain Fork

An in-editor 3D terrain authoring plugin for Godot 4.6+ (verified compatible with 4.7). Originally developed by [Yūgen](https://www.youtube.com/@yugen_seishin) and forked from [Jackachulian](https://github.com/jackachulian) — this fork converts it from marching-squares heightmap terrain into **hexagonal stepped terrain**: a pointy-top axial hex grid where every hex sits at an integer elevation level, with crisp cliff walls (or authored terrace/slope transitions) between levels. MIT licensed.

**Documentation map** — this README covers day-to-day usage and where every knob lives. For deep dives see:
- `documentation/hex_terrain_guide.md` — data model, transition edges, JSON format, persistence, performance.
- `documentation/plugin_quick_guide.md` — per-tool walkthrough with all keyboard/mouse shortcuts.
- `documentation/documentation+/` — contributor docs (tool system internals, code locations, style guide, navmesh recipe).

---

## Quick start

1. **Enable the plugin** — _Project → Project Settings → Plugins_ (already enabled in this project).
2. **Add a `MarchingSquaresTerrain` node** to your scene. Selecting it reveals the plugin toolbar (left of the 3D viewport), the tool attribute bar (bottom), and the texture settings panel (right).
3. **Create chunks** — pick the **Chunk Management** tool and click the ground. The first click places a chunk anywhere; subsequent chunks attach to an existing chunk's 6 neighbours. Click an existing chunk to delete it (undoable); **CTRL+click** selects a chunk.
4. **Shape terrain** — switch to the **Brush** tool, **SHIFT+LMB** and drag. Terrain rises in whole elevation steps. SHIFT+scroll resizes the brush; ALT / ESC / RMB clears the selection.
5. **Paint** — use the **Vertex Paint** tool for ground/wall textures and edge transitions, the **Grass Mask** tool for grass, and the **Import/Export** tool to round-trip the terrain as JSON.

A good pass order: elevations (Brush/Level) → transitions (Default Transition setting or Transition painting) → textures (Vertex Paint, presets, quick paints) → grass (Grass Mask).

---

## Editing terrain parameters

**The important thing to know:** terrain parameters are *not* in the Inspector. They are storage-only exports on the `MarchingSquaresTerrain` node (hidden by design) and are edited through the plugin's **Terrain Settings** tool (gear icon). Select the terrain node, pick the tool, and the settings appear in the bottom attribute bar.

| Setting | What it does |
|---|---|
| **Hex Size** | Outer radius of one hex in world units (default `2.0`). |
| **Level Height** | World-space Y height of one elevation level (default `2.0`). Hex top Y = `elevation × level_height`. |
| **Chunk Radius** | Hexes from a chunk's center to its edge (default `8` → `3R(R+1)+1` = 217 hexes/chunk). |
| **Default Transition** | Edge kind for unauthored single-level steps: cliff or terrace. Applies on next chunk regeneration. |
| **Blend Mode** | Texture blending mode of the terrain shader. |
| **Default Wall Texture** | Slot used for walls of untouched hexes. |
| **Extra Collision Layer** | Additional physics layer the chunk collision is placed on. |
| **Animation Fps** | Grass animation: `0` = smooth noise wind, `>0` = stepped pixel-art motion (clamped 0–30). |
| **Grass Subdivisions / Grass Size** | Density of grass scatter per hex / size of one grass sprite (scaled by hex size). |
| **Ridge / Ledge Threshold** | How far the wall texture bleeds onto floor rims at the top (ridge) / bottom (ledge) of a cliff. |
| **Use Ridge / Ledge Texture** | Toggles for the above. |

### Changing `hex_size` and `chunk_radius` (the non-obvious part)

Both live in the **Terrain Settings** tool as described above, or can be set in code — the setters handle regeneration:

```gdscript
terrain.hex_size = 3.0      # repositions + regenerates all chunks
terrain.level_height = 1.5  # regenerates all chunk meshes
terrain.chunk_radius = 12   # repositions + regenerates — see warning below
```

- **`hex_size` is safe to change at any time.** Hex records are stored as chunk-local axial offsets, so scaling the grid only moves/resizes geometry; no data is lost.
- **`level_height` is likewise safe** — it only rescales Y.
- **`chunk_radius` does NOT remap existing data.** Each chunk keeps its local-offset records, but the hex→chunk ownership mapping depends on the radius, so changing it with authored terrain in place **scrambles which hexes live where** (and each saved chunk stores a radius snapshot that will no longer match). Decide the radius *before* authoring. If you must change it afterwards: export to JSON first (the **Import/Export** tool writes absolute axial coords, independent of chunk layout), change the radius, then re-import.
- **Cost scales quadratically.** Mesh regen is whole-chunk per edit (~217 hexes at radius 8). Prefer more chunks over one huge radius so brush strokes only rebuild what they touch.

## Editing constants (in code)

These are compile-time constants — edit the file, let the editor reload the script, then repaint a hex or reload the scene to regenerate.

`algorithm/terrain/marching_squares_terrain_chunk.gd`:

| Constant | Default | Effect |
|---|---|---|
| `VOID_SLOT` | `15` | Ground slot that marks a hex as void (top face skipped). |
| `TERRACE_TREAD_DEPTH` | `0.35` | Outward depth of one terrace tread (fraction of hex size). |
| `SLOPE_INSET` | `0.35` | How far a slope leans into the lower hex's area. |
| `MAX_TERRACE_INSET` | `0.7` | Total inward bound for multi-step terraces. |
| `EDGE_END_OVERLAP` | `0.05` | Strip ends extend past corners to hide junction seams. |
| `SLOPE_TOP_EPSILON` | `0.001` | Float of the slope inset line above the low fan (fraction of level height). |
| `MAX_TERRACE_DELTA` | `4` | Terraces beyond this many levels fall back to cliff. |
| `DEFAULT_HEX_SIZE` / `DEFAULT_LEVEL_HEIGHT` / `DEFAULT_CHUNK_RADIUS` | `2.0 / 2.0 / 8` | Fallbacks when a chunk has no terrain system assigned. |

Also in that file: `enum EdgeKind {INHERIT, CLIFF, TERRACE, SLOPE}` — the 2-bit-per-edge transition kinds packed into each hex record's `edges` int.

Elsewhere:
- `algorithm/grass/marching_squares_grass_planter.gd` — `GRASS_BORDER_INSET` (0.85: keeps sprites inside the hex), `GRASS_ALPHA_VALUES` (per-slot density steps).
- `algorithm/terrain/mst_hex_math.gd` — `NEIGHBOR_OFFSETS` (axial neighbor order — must stay in sync with the game client's `HexMath.cs` and the server's `hex.rs`), plus the 16-slot ↔ vertex-color-pair encoding (`slot = c0_channel × 4 + c1_channel`).
- `editor/tools/scripts/marching_squares_geometry_baker.gd` — `polygon_texture_resolution` export and `MAX_TEXTURE_SIZE` for the runtime texture baker.
- `utils/marching_squares_thread_pool.gd` — `max_threads` (4).

> **Shader contract:** chunks pin the terrain shader uniforms `chunk_size = ivec3(2,2,2)` and `cell_size = vec2(1,1)` so UV2 tiles raw world XZ at 1 unit. The hex conversion kept the original `mst_terrain`/`mst_grass` shaders untouched — don't "fix" those uniforms.

## Textures, presets and quick paints

- **16 texture slots**, 15 editable. Slot 15 = void (invisible hex tops). Only slots 1–6 can grow grass. Texture names, textures, albedos, scales and per-slot grass toggles are edited in the right-hand texture settings panel.
- **Texture presets** swap the whole palette at once; export them from the bottom of the right panel. They live in `resources/texture_presets/`.
- **Quick Paints** (ground slot + wall slot + grass flag combos) apply textures directly from the height brushes. Create `MarchingSquaresQuickPaint` resources in `resources/quick_paints/` (preset-specific) or `resources/quick_paints/global/`.

## Data & persistence

Chunk data does **not** live in the scene file. On save, dirty chunks are written to `[SceneDir]/[SceneName]_TerrainData/[NodeName]_[uid]/chunk_X_Y/metadata.res` (compressed `MSTChunkData`, V3 hex format — **no migration from the old marching-squares V2 data**). Storage modes on the terrain node: **BAKED** (mesh/collision/grass cached — faster loads) or **RUNTIME** (rebuilt from hex records — smallest files). Runtime texture baking (`enable_runtime_texture_baking`) bakes the multi-texture terrain into a simple baked shader for in-game performance.

The **Import/Export** tool round-trips the terrain as versioned JSON (`mst-hex-terrain` v1, absolute axial coords) — chunk-layout-agnostic, diff-friendly, and the intended hand-off format for a game server. Format details and idempotency notes: `documentation/hex_terrain_guide.md`.

## License (MIT)

Free to use, improve and change — include a copyright mention to the original project and author (Yūgen, forked from Jackachulian). See `documentation/credits.md`.
