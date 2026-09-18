# Hex Terrain Guide

This guide is the deep-dive companion to the _Plugin Quick Guide_. It explains how the hexagonal stepped terrain works, how to author with it, and how data moves in and out of the plugin.

## Getting started

1. **Enable the plugin.** It ships enabled in this project (`res://addons/MarchingSquaresTerrain/plugin.cfg` in `project.godot`). In another project, enable it under _Project → Project Settings → Plugins_.
2. **Add a terrain node.** Add a `MarchingSquaresTerrain` node to your scene (it appears in the Create Node dialog once the plugin is enabled). Selecting it shows the plugin toolbar on the left side of the 3D viewport and the tool attribute bar at the bottom.
3. **Create chunks.** Pick the **Chunk Management** tool and click on the ground plane. The first click places a chunk anywhere; after that, chunks can be added next to any existing chunk's 6 neighbours. Clicking an existing chunk removes it (undoable); **[CTRL] + click** selects a chunk instead.
4. **First brush strokes.** Switch to the **Brush** tool, hold **[SHIFT] + [LMB]** and drag over the new chunk. Terrain rises in whole elevation steps with vertical cliff walls between levels. Drag the selection up or down to change the target level; **[ALT] / [ESC] / [RMB]** clears the selection.

## The data model

Every hex on the grid owns a small record:

| Field | Type | Meaning |
|---|---|---|
| `elevation` | int | Elevation level. World Y of the hex top = `elevation × level_height` (terrain settings). |
| `ground` | int (0–15) | Texture slot of the hex's top face. Slot 15 = void (top face is not drawn). |
| `wall` | int (0–15) | Texture slot of vertical faces this hex builds (cliffs, terrace risers). |
| `grass` | bool | Whether grass sprites grow on this hex. Defaults to **false** — painting the grass mask turns it on. |
| `edges` | int | 6 × 2-bit transition kinds, one per neighbor direction: 0 = inherit/derived, 1 = cliff, 2 = terrace, 3 = slope. |

Hexes are stored per chunk, keyed by **local axial offset** from the chunk's center hex. Coordinates are **pointy-top axial** `(q, r)` — the same convention as the game server (`hex_to_world: x = R(√3 q + √3/2 r), z = 1.5 R r`). Chunks are hex-shaped regions of radius `chunk_radius` (terrain setting, default 8 → `3R(R+1)+1` = 217 hexes per chunk) and every hex belongs to exactly one chunk, so there are no shared border cases.

Mesh generation is per chunk and whole-chunk: each hex gets a top fan at its level, and each edge toward a lower (or missing) neighbor gets a wall strip — a cliff by default, or a terrace/slope if the edge kind says so.

## Authoring workflow

A typical pass order that works well:

1. **Layout elevations** with the Brush and Level tools. Work in whole levels; use CTRL-click with the Level tool to sample a level from existing terrain.
2. **Shape transitions.** Decide where single steps should be terraces or slopes instead of cliffs — either set the terrain-wide `default_transition` (Terrain Settings) or paint individual edges with the Vertex Paint tool in **Transitions** paint mode (see below).
3. **Textures.** Assign texture slots with the Vertex Paint tool (Ground mode for tops, Walls mode for cliff faces). Texture presets swap the whole palette at once; **Quick Paints** combine a ground slot, wall slot and grass flag so you can paint biome-like strokes directly with the height brushes.
4. **Grass.** Paint the grass mask onto the hexes that should grow grass (only textures 1–6 with grass enabled actually sprout).

## Transition edges explained

Every edge between two hexes of different elevation has a **kind**: cliff, terrace, or slope. The kind used at mesh time is decided like this:

1. An **authored** kind (painted onto the hex's `edges` field) always wins.
2. Otherwise (kind 0 = inherit): single-level steps (Δ = 1) use the terrain's `default_transition` setting (cliff or terrace); bigger drops (Δ ≥ 2) are **always cliffs**.

Geometry, per edge, built by the higher hex and leaning into the lower hex's area:

- **Cliff**: one vertical quad from the high top edge down to the low top level.
- **Terrace** (Δ = 1): a half-level riser, a horizontal tread (≈ 0.35 × hex_size), and a second half-level riser.
- **Terrace** (Δ = 2–4, authored only): alternating full-level risers and treads, bounded so the strip stays inside the low hex. Δ > 4 falls back to a cliff.
- **Slope**: one slanted quad from the high top edge down to an inset line just above the low top level.

Risers use the wall slot, treads and slopes use the ground slot. (Changing `default_transition` in the Terrain Settings applies on the next chunk regeneration — repaint something or reload to see it everywhere.)

**Known limitation:** strips are built per edge, independently. Where three different elevations meet at one point, the strips can leave small wedge seams at the corner (slightly mitigated by overlapping strip ends). They read as small crevices between blocks at close range; there are no see-through holes.

Transition painting uses the higher-hex ownership rule: an edge's kind is stored on the **higher** hex of the pair, so when you paint from the lower hex's side the write is redirected to the neighbor's opposite edge automatically.

## JSON export / import

The **Import/Export** tool writes the terrain to a versioned JSON file and reads it back. The format is deliberately simple and chunk-layout-agnostic:

```json
{
  "format": "mst-hex-terrain",
  "version": 1,
  "settings": {
    "hex_size": 2.0, "level_height": 2.0, "chunk_radius": 8,
    "orientation": "pointy-top", "axes": "axial q=+x, r=+z (server convention)",
    "texture_preset": "my_preset"
  },
  "texture_slots": { "0": "res://…/grass.png", "5": "res://…/rock.png" },
  "chunks": [
    { "chunk": [0, 0],
      "hexes": [
        { "q": 12, "r": -4, "elevation": 3, "ground": 5, "wall": 5, "grass": true,
          "edges": [0, 1, 0, 0, 0, 0] }
      ] }
  ]
}
```

Key properties:

- **Absolute axial coordinates** per hex — files do not depend on `chunk_radius`, so they survive chunking changes and can be consumed directly by other tools (e.g. the game server, where `(q, r) + elevation + slot` maps straight onto its hex data).
- **Defaults are omitted** on export (elevation 0, ground 0, wall = the terrain's default wall slot, grass false, edges all-zero), keeping files small and diffs meaningful. `edges` is an array of 6 ints in the fixed neighbor-direction order, only written when any kind is non-default.
- `texture_slots` is advisory (slot → resource path) so consumers can map slot indices onto their own texture ids.
- **Import is idempotent**: it creates any missing chunks, overwrites exactly the hexes the file contains, and leaves unmentioned hexes untouched. Re-importing the same file twice changes nothing. Note: imported hex writes are applied directly (chunk *creation* is undoable; the hex payload itself is not a single undo action).

## Persistence

Chunk source data does not live in the scene file. On save, each dirty chunk is written to:

```
[SceneDir]/[SceneName]_TerrainData/[NodeName]_[uid]/chunk_X_Y/metadata.res
```

as a compressed `MSTChunkData` resource (**V3 format**: chunk coords, chunk_radius snapshot, and parallel arrays of local axial offsets, elevations, ground/wall slots, grass flags and edges). Two storage modes exist on the terrain node:

- **BAKED** (default): the built mesh, collision faces and (optionally) grass multimesh are cached inside `metadata.res` — faster loads, bigger files.
- **RUNTIME**: everything is rebuilt from the hex records on load — smallest files.

**V2 → V3 is a hard format break**: terrain data saved by the marching-squares version of the plugin is not migrated. Old chunks load as empty/default terrain, so re-author or re-import from JSON.

## Performance & limits

- Mesh regeneration is whole-chunk per edit action (no incremental tracking). Cost is roughly `3R(R+1)+1` hexes × up to ~54 vertices each — trivial at the default radius 8 (217 hexes), but it scales quadratically with `chunk_radius`.
- Collision is a trimesh (`create_trimesh_collision`) rebuilt with the mesh; it is stripped from the scene file on save and recreated afterwards (put `navmesh_`-prefixed groups on the chunk node itself, not the collision body — see the navmesh guide).
- Very large terrains should prefer multiple chunks over one huge `chunk_radius` so brush edits only rebuild what they touch.
