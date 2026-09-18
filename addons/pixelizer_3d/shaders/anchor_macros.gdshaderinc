// Pixelizer3D opt-in macros for custom spatial shaders.
//
// Include this file in any spatial shader that should join the anchor pipeline,
// then call the macros from vertex()/fragment():
//
//   shader_type spatial;
//   render_mode depth_draw_opaque, cull_back;
//   #include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"
//
//   void vertex() {
//       ANCHOR_VERTEX(0);
//   }
//
//   void fragment() {
//       ANCHOR_CLIP(my_alpha);                  // scissor + dither + anchor clip
//       if (ANCHOR_META_ACTIVE(0)) {            // metadata camera branch
//           ANCHOR_META_LIGHT(0);               // write the payload
//       } else {
//           ALBEDO = ANCHOR_GRADE(my_color);    // vertex colour + clouds + palette LUT
//           // ANCHOR_OUTLINE(0) is this object's registered outline colour.
//       }
//   }
//
// Godot 4.7 does not support zero-argument macros ("one or more arguments" in
// the preprocessor docs), so the entry points that take no real input require a
// throwaway argument: ANCHOR_VERTEX(0), ANCHOR_META_LIGHT(0),
// ANCHOR_OUTLINE(0).
//
// Register the material once with
// `PixelizerManager3D.register_pixelized_material(material)` so the manager
// pushes the cloud-shadow uniforms to it. Pipeline-wide params
// (`pixelizer_meta_bit`, `pixelizer_lowres_mode`, palette) are global shader
// uniforms set once by the manager. The macros declare every uniform/varying
// they need — do NOT redeclare any of them in the shader (duplicate
// declarations are a parse error).
//
// The ANCHOR_* entry points are preprocessor macros, not functions: Godot
// stage built-ins (MODEL_MATRIX, FRAGCOORD, ALBEDO, COLOR, ...) are only in
// scope inside vertex()/fragment(), so these must expand textually there.
//
// Notes:
// - Never write ALPHA — it moves the material to the transparent pipeline,
//   which the compositor/depth write-back cannot handle. Use ANCHOR_CLIP.
// - ANCHOR_META_LIGHT() may only be called from fragment() (it `return`s).
// - Per-object parameters are instance uniforms, i.e. per node: every
//   sub-instance of a MultiMesh and every particle of a particle system shares
//   the node's anchor size / edge tag.

#ifndef ANCHOR_MACROS_INC
#define ANCHOR_MACROS_INC

// A bridge-generated shader that owns its own cloud toolkit (e.g. MST's
// vendored `cloud_fbm.gdshaderinc`, which declares the same `cloud_*` uniforms
// and functions) defines PIXELIZER_NO_CLOUD before including this header to
// skip the bundled include. Such shaders must not expand ANCHOR_GRADE (it is
// compiled out with the cloud functions); the bridge injects only
// PIXELIZER_VERTEX / PIXELIZER_CLIP / PIXELIZER_META_LIGHT.
#ifndef PIXELIZER_NO_CLOUD
#include "res://addons/pixelizer_3d/shaders/cloud_fbm.gdshaderinc"
#endif

// ── Required uniforms (global shader uniforms, pushed once by the manager) ──
// Metadata camera bit (1 << (layer - 1)); nonzero selects the payload branch.
global uniform uint pixelizer_meta_bit;
// Low-res mode disables the per-object anchor clip (the SubViewport already
// renders at the render resolution).
global uniform bool pixelizer_lowres_mode;
instance uniform int anchor_size = 3;
instance uniform int anchor_tag = 1;
// Focus flag (1 = focused). Focused meshes are tagged 255 in the metadata
// payload, overriding `anchor_tag`, so the focus is non-destructive.
instance uniform int anchor_focus = 0;
instance uniform vec4 edge_tint : source_color = vec4(0.0, 0.0, 0.0, 1.0);
// Per-object palette opt-out (1 = grade through the manager's LUT).
instance uniform int use_grade_lut = 1;
// Anchor lattice mode: 0 = PER_OBJECT (default), 1 = UNIFIED (world origin).
// UNIFIED makes every object in a group land on one common lattice.
instance uniform int anchor_mode = 0;
// Per-object ordered-dither toggle (1 = on): gates both the alpha dither and
// the palette LUT dither band.
instance uniform int use_dither = 1;
// Mover snap (1 = on): the vertex stage shifts the whole mesh so the projected
// object pivot lands on a whole screen texel. Orthographic only; the scene
// transform is never touched (the old CPU pre/post-draw swap is gone).
instance uniform int anchor_mover_snap = 0;
uniform bool use_vertex_color = false;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.0;
uniform bool dither_alpha = false;

// ── Palette grading ─────────────────────────────────────────────────────
// global_palette_lut is a 256x256 LUT baked by PaletteLUT: 16^3 gamma-space
// colours on x (r + 16*b) and g + 16*dither band on y. The dither band is
// derived from the object-grid macro-pixel coordinate, so the pattern is
// locked to the anchor lattice and never crawls. The graded colour is written
// by the surviving anchor fragment, which is what the apply pass replicates.
global uniform bool pixelizer_palette_grading_enabled;
// source_color: the LUT stores gamma-space palette colours (as authored), and
// ALBEDO is linear, so the sample must be linearised (otherwise the palette
// renders washed out / hue-shifted). Exact texel-centre samples, so no
// filtering artifacts.
global uniform sampler2D pixelizer_palette_lut : source_color, filter_nearest, repeat_disable;
global uniform bool pixelizer_palette_dither_enabled;

// Payload channels (metadata camera only):
//   R = anchor_size / 32
//   G = edge tag / 256
//   B = view depth in metres (raw; nearest anchor wins)
const float ANCHOR_SIZE_SCALE = 32.0;
const float ANCHOR_TAG_SCALE = 256.0;

// Palette LUT dimensions (see PaletteLUT): 16 quantisation levels per
// channel, 16 stacked ordered-dither bands.
const float LUT_LEVELS = 16.0;
const float LUT_BANDS = 16.0;

varying flat vec2 v_anchor_px;
varying flat float v_is_meta;
varying float v_view_depth;
varying vec3 v_world_pos;

// ── Ordered dither (algorithmic Bayer) ───────────────────────────────────────
//
// The 4x4 threshold matrix is generated from the same recursive Bayer
// construction as `DitherMatrix.bayer_index()` (core/dither_matrix.gd) instead
// of a pasted table, so there is exactly one definition of the pattern.
// `anchor_bayer2` is the base cell [[0,2],[3,1]]; the 4x4 value is the
// recursive `4*M2(low) + M2(high)` in [0, 15].
int anchor_bayer2(int a, int b) {
	if (a == 0) {
		return (b == 0) ? 0 : 2;
	}
	return (b == 0) ? 3 : 1;
}

int anchor_bayer_index(ivec2 cell) {
	return anchor_bayer2(cell.x & 1, cell.y & 1) * 4 + anchor_bayer2((cell.x >> 1) & 1, (cell.y >> 1) & 1);
}

// ── Helper functions (no stage built-ins, so callable from macros) ───────────
//
// Exactly one fragment survives per `anchor_size` macro block, on the lattice
// anchored to the projected object pivot. The survivor of a block is the pixel
// whose offset from the anchor is a whole multiple of the block size.
// The `+0.1` bias + `<= 0.1` tolerance are load-bearing: the projected pivot is
// a large float and is not guaranteed to land on an exact integer on every
// driver/precision path, so an exact `mod(d, ps) == 0.0` test can reject every
// fragment (the world then renders only in one quadrant). The bias snaps the
// anchor to the nearest integer and the tolerance absorbs the sub-pixel error.
// Parameters are `anchor_`-prefixed: Godot's shader language rejects a
// parameter that shadows a global (bridge-generated shaders include this header
// next to arbitrary third-party declarations like `varying vec3 world_pos`).
vec2 anchor_clip_delta(vec2 anchor_frag_px) {
	return floor(floor(anchor_frag_px) - floor(v_anchor_px + vec2(0.1))) + vec2(0.01);
}

bool anchor_alive(vec2 anchor_frag_px, float anchor_block_size) {
	float ps = max(1.0, anchor_block_size);
	vec2 d = anchor_clip_delta(anchor_frag_px);
	return mod(d.x, ps) <= 0.1 && mod(d.y, ps) <= 0.1;
}

// Macro-pixel coordinate relative to the object's anchor lattice; constant
// across a block, i.e. the dither/grade cell index.
vec2 anchor_macro_delta(vec2 anchor_frag_px, float anchor_block_size) {
	return anchor_clip_delta(anchor_frag_px) / max(1.0, anchor_block_size);
}

float anchor_bayer(vec2 anchor_frag_px, float anchor_block_size) {
	vec2 macro = anchor_macro_delta(anchor_frag_px, anchor_block_size);
	ivec2 cell = ivec2(mod(macro, 4.0));
	return (float(anchor_bayer_index(cell)) + 1.0) / 17.0;
}

// Gamma-space 3D LUT flattened to 2D, with the
// 16 ordered-dither bands stacked on y (band 0 when dithering is disabled).
vec3 anchor_lut_grade(vec3 anchor_color, vec2 anchor_delta) {
	vec3 orig = pow(clamp(anchor_color, vec3(0.0), vec3(1.0)), vec3(1.0 / 2.2));
	orig = clamp(orig, vec3(0.0), vec3(0.9999));

	float u = (clamp(orig.r * LUT_LEVELS, 0.0, LUT_LEVELS - 1.0) + 0.5) / (LUT_LEVELS * LUT_LEVELS);
	float v = (clamp(orig.g * LUT_LEVELS, 0.0, LUT_LEVELS - 1.0) + 0.5) / (LUT_LEVELS * LUT_BANDS);
	float cell = floor(clamp(orig.b * LUT_LEVELS, 0.0, LUT_LEVELS - 1.0) + 0.5);
	u += cell / LUT_LEVELS;

	float band = 0.0;
	if (pixelizer_palette_dither_enabled && use_dither != 0) {
		band = (mod(anchor_delta.x, 4.0) * 4.0 + mod(anchor_delta.y, 4.0)) / LUT_BANDS;
	}
	v += band;

	return textureLod(pixelizer_palette_lut, vec2(u, v), 0.0).rgb;
}

// Vertex-colour multiply + cloud shadows + optional palette grading (world
// position / fragment position passed by the macro, because varyings are fine
// in functions but COLOR and FRAGCOORD are fragment-only).
// Compiled out under PIXELIZER_NO_CLOUD (an external shader owns the clouds);
// such shaders must not expand ANCHOR_GRADE.
#ifndef PIXELIZER_NO_CLOUD
vec3 anchor_grade(vec3 anchor_base, vec3 anchor_vertex_color, vec3 anchor_world_pos, vec2 anchor_frag_px, float anchor_block_size) {
	vec3 graded = anchor_base * anchor_vertex_color * (1.0 - cloud_shadow(anchor_world_pos));
	if (pixelizer_palette_grading_enabled && use_grade_lut != 0) {
		graded = anchor_lut_grade(graded, anchor_macro_delta(anchor_frag_px, anchor_block_size));
	}
	return graded;
}
#endif

// ── Macros (expand textually inside vertex()/fragment()) ─────────────────────

// Computes the anchor lattice, metadata flag and world/depth varyings.
// Call from vertex(). The argument is unused (Godot has no zero-arg macros).
#define ANCHOR_VERTEX(_unused) \
	vec3 anchor_pivot_world = (anchor_mode == 0) ? MODEL_MATRIX[3].xyz : vec3(0.0); \
	vec4 anchor_pivot_clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(anchor_pivot_world, 1.0); \
	vec2 anchor_px = (anchor_pivot_clip.xy / anchor_pivot_clip.w * 0.5 + 0.5) * VIEWPORT_SIZE; \
	if (abs(anchor_pivot_clip.w - 1.0) > 0.0001) { \
		anchor_px = round(anchor_px); \
	} \
	if (anchor_mover_snap != 0 && anchor_mode == 0 && PROJECTION_MATRIX[3][3] > 0.5) { \
		/* Orthographic mover snap: shift the rigid mesh so the projected pivot \
		   lands on a whole screen texel. World units per texel fall out of the \
		   orthographic projection matrix; the shift is applied through the \
		   vertex so the scene transform is never mutated. */ \
		vec2 anchor_world_per_px = vec2( \
			2.0 / (VIEWPORT_SIZE.x * PROJECTION_MATRIX[0][0]), \
			2.0 / (VIEWPORT_SIZE.y * PROJECTION_MATRIX[1][1])); \
		vec2 anchor_snap_px = round(anchor_px) - anchor_px; \
		vec3 anchor_snap_world = VIEW_MATRIX[0].xyz * (anchor_snap_px.x * anchor_world_per_px.x) \
			+ VIEW_MATRIX[1].xyz * (anchor_snap_px.y * anchor_world_per_px.y); \
		VERTEX += (inverse(MODEL_MATRIX) * vec4(anchor_snap_world, 0.0)).xyz; \
	} \
	v_anchor_px = anchor_px; \
	v_is_meta = ((CAMERA_VISIBLE_LAYERS & pixelizer_meta_bit) != 0u) ? 1.0 : 0.0; \
	v_view_depth = -(VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0)).z; \
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

// Alpha scissor + ordered dither + anchor clip. Call from fragment() with the
// surface's final alpha (texture alpha * tint alpha).
#define ANCHOR_CLIP(alpha) \
	vec2 anchor_frag = floor(FRAGCOORD.xy); \
	if (alpha_scissor > 0.0 && (alpha) < alpha_scissor) { discard; } \
	if (dither_alpha && use_dither != 0 && (alpha) < anchor_bayer(anchor_frag, float(anchor_size))) { discard; } \
	if (!pixelizer_lowres_mode) { \
		bool anchor_on_edge = anchor_frag.x < 1.0 || anchor_frag.y < 1.0 \
			|| anchor_frag.x > VIEWPORT_SIZE.x - 2.0 || anchor_frag.y > VIEWPORT_SIZE.y - 2.0; \
		if (!anchor_alive(anchor_frag, float(anchor_size)) && !anchor_on_edge) { discard; } \
	}

// Vertex-colour multiply + cloud shadows + palette LUT grading; returns the
// graded albedo. Must be called from fragment() (uses FRAGCOORD) and after
// ANCHOR_CLIP, so the graded colour rides the surviving anchor fragment.
#define ANCHOR_GRADE(base) anchor_grade((base), use_vertex_color ? COLOR.rgb : vec3(1.0), v_world_pos, FRAGCOORD.xy, float(anchor_size))

// This object's registered outline colour. The anchor pipeline draws
// silhouettes/inner edges in the apply pass, so this is for custom shaders
// that render their own contours or need the palette tint.
#define ANCHOR_OUTLINE(_unused) edge_tint

// True when the metadata camera is rendering this object (and the anchor
// pipeline is active). Use it as the branch condition in fragment():
//   if (ANCHOR_META_ACTIVE(0)) { ANCHOR_META_LIGHT(0); } else { ... }
// Godot forbids `return` in the fragment processor function, so the metadata
// branch cannot early-out from a macro.
#define ANCHOR_META_ACTIVE(_unused) (!pixelizer_lowres_mode && v_is_meta > 0.5)

// Writes the metadata payload (anchor size / edge tag / view depth). Only
// valid inside the ANCHOR_META_ACTIVE branch. Never writes ALPHA.
#define ANCHOR_META_LIGHT(_unused) \
	ALBEDO = vec3(0.0); \
	EMISSION = vec3( \
		float(anchor_size) / ANCHOR_SIZE_SCALE, \
		float(anchor_focus != 0 ? 255 : anchor_tag) / ANCHOR_TAG_SCALE, \
		max(v_view_depth, 0.0)); \
	ROUGHNESS = 1.0; \
	METALLIC = 0.0; \
	SPECULAR = 0.0;

// ── Bridge vocabulary ────────────────────────────────────────────────────────
// Aliases for the native ANCHOR_* entry points. The editor-time shader bridge
// injects these names into generated assets, so the generated text stays
// independent of the native prefix. Generated shaders include this header, so
// the aliases resolve to the same macros.
#define PIXELIZER_VERTEX(_unused) ANCHOR_VERTEX(_unused)
#define PIXELIZER_CLIP(alpha) ANCHOR_CLIP(alpha)
#define PIXELIZER_META_ACTIVE(_unused) ANCHOR_META_ACTIVE(_unused)
#define PIXELIZER_META_LIGHT(_unused) ANCHOR_META_LIGHT(_unused)

#endif
