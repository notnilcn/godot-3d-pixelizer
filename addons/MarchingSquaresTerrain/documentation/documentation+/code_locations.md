# Code Locations

This small guide explains where you can find the code for several (smaller) features inside the plugin.

### Texture Slots and Texture Mixing

* **MSTHexMath** script → `slot_to_color_pair(slot: int)` / `color_pair_to_slot(c0: Color, c1: Color)` static functions.
* **MarchingSquaresTerrainChunk** script → `_slot_to_mat_blend(slot: int)` and the `_build_*` mesh builder functions.
* **mst_terrain** gdshaderinc → fragment function.

The 16 texture slots are encoded as a pair of vertex colors (slot = c0_channel × 4 + c1_channel): although the variables are called _color_, the shader checks whether any of the channels are 1 or 0 and picks the texture from which channels are "turned on". The chunk writes these pairs per hex (ground slot on top fans, wall slot on risers/cliff walls) along with a CUSTOM2 material-blend value that pins the whole hex to its single slot.

### Grass Placement and Animations

* **MarchingSquaresGrassPlanter** script → `regenerate_grass()` function.
* **mst_grass** gdshader → at the top of the vertex function.

Grass instances are scattered inside each hex's top polygon (seeded, deterministic) wherever the hex's grass flag is set and the ground texture allows it. Right now having the fps at 0 means that the shader will use a noise texture to apply a global smooth wind effect. Turning the fps up in the terrain_settings tool mode in the editor makes the individual grass sprites move from left to right giving it a pixel art look.

Feel free to change these animations to what looks best for your project! The two animation types present right now are only a base to get people started.

### Transition Edges (Cliffs, Terraces, Slopes)

* **MarchingSquaresTerrainChunk** script → `_resolve_edge_kind(...)` for the derived-vs-authored kind decision, `_build_cliff_wall` / `_build_terrace` / `_build_slope` for the geometry.

### Chunk UI Lines

* **MarchingSquaresTerrainGizmo** script → `try_add_chunk(terrain_system: MarchingSquaresTerrain, coords: Vector2i):` function.
* **MarchingSquaresTerrainGizmo** script → `add_chunk_lines(terrain_system: MarchingSquaresTerrain, coords: Vector2i, material: Material):` function.

### Terrain (Triplanar) Mapping

* **mst_terrain** gdshaderinc → fragment function.

### Ridge & Ledge Texture Calculations

* **mst_terrain** gdshaderinc → end of the fragment function.
* **MarchingSquaresTerrainChunk** script → `_build_top_fan(...)` writes the ridge/ledge flags and nearest wall slot into CUSTOM1 per corner (ridge = corner next to a cliff going down, ledge = corner next to a cliff going up).
