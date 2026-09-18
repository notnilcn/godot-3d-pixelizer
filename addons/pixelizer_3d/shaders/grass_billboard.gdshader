shader_type spatial;
render_mode depth_draw_opaque, cull_disabled, diffuse_toon, specular_disabled;

// Pixelizer3D billboard grass/foliage card.
//
// Cards are upright (Y-axis) billboards: they face the camera around Y only, so
// a grass patch keeps its vertical blades. The quad is expected to be a unit
// PlaneMesh/QuadMesh centred on its origin — the shader lifts it so the node
// origin sits at the blade base, and scales it with the node/MultiMesh
// transform.
//
// Wind is world-space and length-scaled: the amplitude is `wind_strength`
// (fraction of the card height) times the card's world height, times a bend
// factor that keeps the base planted, so taller blades travel farther. The
// clock is quantised to `wind_fps` so the sway reads as low-frame-rate pixel
// animation instead of smooth motion.
//
// Atlas variation / stepped frames: `atlas_cells` declares the grid, each
// instance picks a cell by hashing its world origin + INSTANCE_ID, and
// `animate_frames` cycles cells at `animation_fps`. Textures must use nearest
// filtering and alpha in the alpha channel.
//
// ANCHOR OPT-IN: this shader includes anchor_macros.gdshaderinc, so the
// owning material must be registered with
// `PixelizerManager3D.register_pixelized_material(material)` — otherwise the
// material renders without the anchor clip / metadata payload (the factory
// never replaces registered materials). It supports alpha-scissor ONLY
// (ANCHOR_CLIP); never write ALPHA — transparent surfaces break the
// pixelized depth pipeline.

#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

group_uniforms Albedo;
uniform sampler2D albedo_texture : source_color, filter_nearest, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

group_uniforms Atlas;
uniform vec2 atlas_cells = vec2(2.0, 2.0);
// Cells used for static per-instance variation (row-major from the top-left).
uniform int variation_count = 4;
uniform bool animate_frames = false;
uniform float animation_fps = 6.0;
uniform int animation_frames = 4;

group_uniforms Wind;
uniform vec2 wind_direction = vec2(1.0, 0.25);
// Sway amplitude as a fraction of the card height (world/length scaled).
uniform float wind_strength = 0.12;
uniform float wind_speed = 1.3;
uniform float wind_turbulence = 0.35;
// Quantise the wind clock to this frame rate (0 = continuous).
uniform float wind_fps = 8.0;

varying vec2 f_uv;
varying vec3 f_card_center_view;

// INSTANCE_ID is stage-scoped in Godot shaders, so it is passed in as an
// argument (a helper function cannot read it directly).
//
// Deterministic card seed: fold the world origin and the instance id through a
// couple of fractional multiplies. This keeps the value well distributed at any
// world position (no huge-angle sin() precision cliff on mobile GPUs).
float foliage_hash(vec3 origin, float instance_id) {
	vec2 cell = fract(origin.xz * 0.125 + instance_id * 0.6180339887);
	cell = fract(cell * vec2(91.7, 47.3) + vec2(0.37, 0.11));
	return fract(cell.x * cell.y * 197.0);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float seed = foliage_hash(origin, float(INSTANCE_ID));

	float clock = TIME;
	if (wind_fps > 0.0) {
		clock = floor(TIME * wind_fps) / wind_fps;
	}

	// Per-axis world scale from the node (and the MultiMesh instance) matrix.
	vec3 card_scale = vec3(
		length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz));

	// Upright billboard: camera right/back projected to the ground plane.
	vec3 right = normalize(vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z));
	vec3 back = normalize(vec3(INV_VIEW_MATRIX[2].x, 0.0, INV_VIEW_MATRIX[2].z));

	// Unit card centred on the origin; lift it so the pivot becomes the base.
	float bend = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	vec3 world_pos = origin
		+ right * (VERTEX.x * card_scale.x)
		+ vec3(0.0, 1.0, 0.0) * ((VERTEX.y + 0.5) * card_scale.y)
		+ back * (VERTEX.z * card_scale.z);

	// Wind, world space: direction * gust * amplitude * bend^2 * card height.
	vec2 dir_flat = normalize(wind_direction + vec2(0.0001, 0.0001));
	float phase = clock * wind_speed + seed * 6.2831853;
	float gust = sin(phase) + wind_turbulence * sin(phase * 2.7 + 1.7);
	world_pos += vec3(dir_flat.x, 0.0, dir_flat.y)
		* gust * wind_strength * bend * bend * card_scale.y;

	// Bypass the normal model transform; the card is fully billboarded.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	// Light the card as one point (its base) so shading is stable across the
	// swaying quad and matches the pixelized blocks around it.
	NORMAL = vec3(0.0, 1.0, 0.0);
	f_card_center_view = (VIEW_MATRIX * vec4(origin, 1.0)).xyz;

	ANCHOR_VERTEX(0);
	// The macros sampled the anchor before the billboard; refresh the payload.
	v_world_pos = world_pos;
	v_view_depth = -(VIEW_MATRIX * vec4(world_pos, 1.0)).z;

	// Atlas: hash-driven variation, optionally stepping through frames.
	int cell = int(floor(seed * float(variation_count)));
	if (animate_frames) {
		int frame_count = max(1, animation_frames);
		int frame_offset = int(floor(seed * float(frame_count)));
		int frame = frame_offset + int(floor(TIME * max(animation_fps, 0.001)));
		cell = frame % frame_count;
	}
	int columns = max(1, int(atlas_cells.x));
	vec2 cell_index = vec2(float(cell % columns), float(cell / columns));
	f_uv = (UV + cell_index) / atlas_cells;
}

void fragment() {
	// LIGHT_VERTEX is fragment-stage in Godot: pin the lighting sample to the
	// card centre (view space) so the swaying billboard shades as one unit.
	LIGHT_VERTEX = f_card_center_view;
	vec4 tex = texture(albedo_texture, f_uv);
	ANCHOR_CLIP(tex.a * tint.a);
	if (ANCHOR_META_ACTIVE(0)) {
		ANCHOR_META_LIGHT(0);
	} else {
		ALBEDO = ANCHOR_GRADE(tex.rgb * tint.rgb);
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
		SPECULAR = 0.0;
	}
}
