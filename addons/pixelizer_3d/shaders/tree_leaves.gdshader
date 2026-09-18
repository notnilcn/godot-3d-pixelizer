shader_type spatial;
render_mode depth_draw_opaque, cull_disabled, diffuse_toon, specular_disabled;

// Pixelizer3D tree/leaf card billboard.
//
// Full camera-facing billboard: unlike grass, leaf cluster cards follow the
// camera in pitch too, which is the classic 3D-pixel-art foliage look. The
// whole card sways in world space (amplitude is `wind_strength` as a fraction
// of the card height, so bigger cards travel farther) on a stepped clock
// (`wind_fps`) for low-frame-rate pixel animation.
//
// Atlas variation / stepped frames work exactly like grass_billboard.gdshader:
// `atlas_cells` grid, per-instance cell from a world-origin + INSTANCE_ID hash,
// optional frame stepping at `animation_fps`.
//
// ANCHOR OPT-IN: includes anchor_macros.gdshaderinc — register the
// material with `PixelizerManager3D.register_pixelized_material(material)`.
// Alpha-scissor only (ANCHOR_CLIP); never write ALPHA.

#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

group_uniforms Albedo;
uniform sampler2D albedo_texture : source_color, filter_nearest, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

group_uniforms Atlas;
uniform vec2 atlas_cells = vec2(2.0, 2.0);
uniform int variation_count = 4;
uniform bool animate_frames = false;
uniform float animation_fps = 4.0;
uniform int animation_frames = 4;

group_uniforms Wind;
uniform vec2 wind_direction = vec2(1.0, 0.2);
// Sway amplitude as a fraction of the card height (world/length scaled).
uniform float wind_strength = 0.15;
uniform float wind_speed = 0.9;
uniform float wind_turbulence = 0.5;
// Quantise the wind clock to this frame rate (0 = continuous).
uniform float wind_fps = 6.0;
// Vertical bob as a fraction of the lateral sway.
uniform float wind_bob = 0.25;

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

	vec3 card_scale = vec3(
		length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz));

	// Full billboard: use the camera basis columns directly.
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 back = INV_VIEW_MATRIX[2].xyz;

	vec3 world_pos = origin
		+ right * (VERTEX.x * card_scale.x)
		+ up * (VERTEX.y * card_scale.y)
		+ back * (VERTEX.z * card_scale.z);

	// Wind: lateral world-space sway + a little bob; the whole card moves.
	vec2 dir_flat = normalize(wind_direction + vec2(0.0001, 0.0001));
	float phase = clock * wind_speed + seed * 6.2831853;
	float gust = sin(phase) + wind_turbulence * sin(phase * 2.7 + 1.7);
	float sway = gust * wind_strength * card_scale.y;
	world_pos += vec3(dir_flat.x, 0.0, dir_flat.y) * sway;
	world_pos.y += sway * wind_bob * sin(phase * 1.3 + 0.7);

	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	NORMAL = vec3(0.0, 1.0, 0.0);
	f_card_center_view = (VIEW_MATRIX * vec4(origin, 1.0)).xyz;

	ANCHOR_VERTEX(0);
	// The macros sampled the anchor before the billboard; refresh the payload.
	v_world_pos = world_pos;
	v_view_depth = -(VIEW_MATRIX * vec4(world_pos, 1.0)).z;

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
