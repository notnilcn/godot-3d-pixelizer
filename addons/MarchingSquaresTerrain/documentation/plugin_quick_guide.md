# Plugin Quick Guide

### What is Yūgen's Terrain Authoring Toolkit?
Yūgen's Terrain Authoring Toolkit is a terrain plugin developed by [Yūgen](https://www.youtube.com/@yugen_seishin) as an alternative to using 3d modelling software like blender to create custom terrain shapes. Instead of having to switch between softwares every time you want to make a change, you can now do it all inside the godot engine itself!

**This fork turns the plugin into a hexagonal stepped-terrain editor.** The world is a grid of pointy-top hexagons instead of square cells, and every hex sits at an integer elevation level — terrain is built from crisp steps with vertical cliff walls (or terrace/slope transitions) between them, not from smooth heightmap interpolation. While this plugin was created originally with isometric perspective and 3d pixel art games in mind, it can be used for a plethora of genres.

Below you will find a brief explanation of all the tools included in the plugin. A more in depth explanation of how all the tools function internally can be found in the _documentation+_ folder, and a full usage deep-dive lives in `hex_terrain_guide.md` next to this file. Other plugin explanations and where to find certain code can also be found in the same folder.

For community showcases, feature requests and bug reporting, please refer to the [discord](https://discord.gg/ZSeYkTCgft).

## Tool Overview

### Brush Tool
* Used to elevate or lower terrain in integer steps.
  * Holding **[SHIFT]** and pressing **[LEFT MOUSE BUTTON]** with most brush tools selected will keep adding terrain to the selection even after letting go of the original mouse click.
  * In the same fashion as above, holding **[SHIFT]** and using the **[SCROLL WHEEL]** decreases and increases the current brush size.
  * You can also press **[ALT]**, **[ESC]** or **[RMB]** to deselect the current draw selection.
  * With "flatten" enabled the whole selection moves toward one elevation level; without it the selection keeps its relative shape and is dragged up/down.

### Level Tool
* Used to level terrain to a certain elevation level (integer levels 0–16).
  * Press **[CTRL]** while hovering over terrain to set the current level to the hovered hex's elevation level.

### Smooth Tool
* Used to smooth neighbouring terrain to their average elevation level (rounded to the nearest integer level per hex).

### Bridge Tool
* Used to create a bridge between two points, stepping per hex along the way.
  * The bridge curve falloff can be set via the "ease value" attribute. For reference see the below ease value cheatsheet (see also the _documentation+_ folder).

![Godot Ease Value Cheatsheet](documentation+\ease_cheatsheet.png "Ease Cheatsheet")

### Grass Mask Tool
* Used to control where grass gets placed.
  * Grass defaults to **off** on untouched hexes — painting with the mask tool turns it on (or back off with "Mask Mode" enabled).
  * Grass only grows on textures 1–6 that have grass enabled in the texture settings.

### Vertex Paint Tool
* Used to paint textures onto the terrain.
  * 16 texture slots in total of which 15 can be editted.
	* The final 16th slot is used for turning terrain invisible.
	* The first 6 textures can have grass.
	* Texture names can be changed at will.
  * The "Paint Mode" option switches between painting **Ground** textures, **Wall** (cliff face) textures and **Transitions**.
	* Transition painting sets the edge of the hex nearest to the cursor to a transition kind (Default / Cliff / Terrace / Slope).
	* Edges are owned by the higher hex of each pair — painting from the lower side automatically writes to the higher hex's edge.
  * Texture presets can be used to quickly swap between texture pallets.
	* They can be exported in the plugin via the right hand UI panel at the bottom.
  * "Quick Paints" are a way to quickly set textures while moddeling the terrain.
	* They can be accesed via any of the height based terrain brushes.
	* You can make global or texture preset specific ones. 
	  * → Create a **MarchingSquaresQuickPaint** resource in their dedicated folders in the parent plugin folder.

### Debug Brush Tool
* Used to print the data record of the selected hex:
  * Chunk and local hex coordinates;
  * Elevation level;
  * Ground and wall texture slots;
  * Grass flag and packed edge transitions.

### Chunk Management Tool
* Used to create and delete chunks on the hex chunk grid.
  * A new chunk can be added next to any of the 6 neighbouring chunks of an existing one (or anywhere if the terrain has no chunks yet).
* Holding **[CTRL]** and pressing **[LEFT MOUSE BUTTON]** will set the selected chunk to the hovered chunk.
  * The selected chunk will show in the editor via a highlighted hexagon outline.

### Terrain Settings Tool
* Used to tweak global terrain settings.
  * "Hex Size" is the outer radius of one hex in world units, "Level Height" the world-space height of one elevation level, "Chunk Radius" the size of a chunk in hexes from center to edge.
  * "Default Transition" picks the edge kind used for unauthored single-level steps (cliff or terrace).
  * The "Blend Mode" dropdown menu allows you to set the terrain's texture blending mode to suit your liking.
  * Setting the "Animation Fps" value to more than 0 makes the grass sprites move with limited fps.
	* Keeping it at 0 gives the grass a smooth wind based effect.
  * "Ridge Threshold" controls how far the wall texture continues onto floor rims at the top of a cliff.
  * "Ledge Threshold" does the same for floor rims at the bottom of a cliff.

### Import/Export Tool
* Used to export the terrain to a versioned JSON file and import it back.
  * Set the "Export Path" / "Import Path" (a `res://` or absolute path) and press the **Export** / **Import** buttons.
  * The JSON stores absolute axial hex coordinates, so it is independent of the chunk layout and friendly to version control diffs.
  * It is also the hand-off format for feeding terrain data to a game server.

## License (MIT)
Feel free to use, improve and change this plugin according to your needs, but include a copyright mention to the original project and author.
