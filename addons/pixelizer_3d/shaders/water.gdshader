shader_type spatial;
render_mode cull_back, shadows_disabled;

// Pixelizer3D water — opaque, banded deep→shallow colour with foam at the coast
// and thresholded whitecaps. The 4-sine slope normal drives a stepped toon
// diffuse + sun glint so the water shades in bands instead of a smooth specular.
//
// OPAQUE by contract: pixelized objects only write depth at anchor fragments, so
// a transparent/additive water surface in front of one draws over the block and
// "dissolves" the object into anchor dots. Never write ALPHA here.
//
// Per-tile variation rides instance uniforms (`coast`, `wave_phase`), so one
// shared material can dress a whole grid with a coastline.
//
// Cloud shadows come from the shared include — register the material with the
// manager's `register_cloud_material()` (PixelizerWater3D does it for you).

#include "res://addons/pixelizer_3d/shaders/cloud_fbm.gdshaderinc"

uniform vec4 shallow_color : source_color = vec4(0.35, 0.75, 0.80, 1.0);
uniform vec4 deep_color : source_color = vec4(0.08, 0.25, 0.45, 1.0);
uniform vec4 foam_color : source_color = vec4(0.90, 0.97, 1.0, 1.0);
uniform sampler2D water_noise : filter_nearest, repeat_enable;

// 1.0 = shallow / touches land (foam), 0.0 = open water (deep, whitecaps).
instance uniform float coast = 0.0;
// Per-tile animation offset so a grid of tiles doesn't move in lockstep.
instance uniform float wave_phase = 0.0;

// Quantisation of the deep→shallow ramp (hard bands, pixel-art style).
uniform float depth_levels = 4.0;

uniform float wave_height = 0.12;
uniform float wave_frequency = 0.55;
uniform float wave_speed = 1.2;

// Foam coverage on a fully coastal tile.
uniform float foam_amount : hint_range(0.0, 1.0) = 0.4;
uniform float foam_noise_scale = 0.35;
uniform vec2 foam_scroll = vec2(0.05, 0.03);

uniform float cap_threshold = 0.90;
uniform float cap_noise_scale = 0.28;
uniform vec2 cap_scroll = vec2(0.06, -0.04);

// 4-sine slope normals.
uniform float normal_scale = 0.45;
uniform vec2 normal_scroll = vec2(0.02, 0.013);
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

// Stepped sun response (banded, so the water reads as pixel-art shading).
uniform float toon_soft = 0.15;
uniform float toon_mid = 0.65;
uniform float glint_strength = 0.25;
uniform float glint_sharpness = 48.0;

varying vec3 water_world_pos;
varying float coast_v;
varying float phase_v;

// Procedural, texture-free low-frequency normal. Coord is the already
// scaled/panned world XZ coordinate; returns tangent-space XY (plane up = +Y).
//
// The height field is a sum of directional sine waves. Each crest direction is
// the previous one advanced by the golden angle, so no two crests share an axis
// and the field never settles into a regular cross-hatch. The domain is rotated
// and shrunk between crests (a small FBM), and the wave amplitudes fall off
// geometrically. The returned value is the analytic horizontal gradient of that
// height, not a finite difference.
vec2 wave_normal_xy(vec2 coord) {
	vec2 p = coord * TAU;
	vec2 slope = vec2(0.0);
	float angle = 0.6;
	float amplitude = 1.0;
	for (int i = 0; i < 4; i++) {
		vec2 dir = vec2(cos(angle), sin(angle));
		slope += dir * (amplitude * cos(dot(p, dir) + float(i) * 1.7));
		angle += 2.39996323;
		amplitude *= 0.55;
		p *= 1.7;
	}
	// Keep the combined normal broad and readable rather than letting it
	// saturate into a noisy high-frequency normal.
	return clamp(slope * 0.3 * normal_strength, vec2(-0.85), vec2(0.85));
}

void vertex() {
	water_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	coast_v = coast;
	phase_v = wave_phase;
	// Two sine waves 90 degrees apart, multiplied (A x B).
	float wave_a = sin(water_world_pos.x * wave_frequency + TIME * wave_speed + wave_phase);
	float wave_b = sin(water_world_pos.z * wave_frequency * 1.3 + TIME * wave_speed * 0.8 + wave_phase * 1.7);
	VERTEX.y += wave_a * wave_b * wave_height;
}

void fragment() {
	vec2 wuv = water_world_pos.xz;

	// Banded base colour: deep water -> shallow at the coast, quantised so the
	// depth ramp reads as hard pixel-art bands (instance uniform `coast`).
	float band = clamp(coast_v, 0.0, 1.0);
	float levels = max(depth_levels, 1.0);
	float depth_band = floor(band * levels + 0.5) / levels;
	vec3 col = mix(deep_color.rgb, shallow_color.rgb, depth_band);

	// Shoreline foam on coastal tiles, deliberately broken up by noise.
	float foam_n = texture(water_noise, wuv * foam_noise_scale + foam_scroll * TIME).r;
	float foam = step(1.0 - foam_amount * band, foam_n) * step(0.01, band);
	col = mix(col, foam_color.rgb, foam);

	// Whitecaps: a hard threshold on scrolling noise, open water only.
	float cap_n = texture(water_noise, wuv * cap_noise_scale + cap_scroll * TIME).r;
	float caps = step(cap_threshold, cap_n) * (1.0 - band);
	col = mix(col, foam_color.rgb, caps);

	// Cloud shadows: same sun-projected coverage as the terrain, so shadows
	// continue seamlessly across the coastline.
	col *= 1.0 - cloud_shadow(water_world_pos);

	// 4-sine slope normal. The surface is horizontal, so the tangent-space XY
	// maps straight onto world XZ and Y stays up.
	vec2 slope = wave_normal_xy(wuv * normal_scale + normal_scroll * TIME + vec2(phase_v));
	vec3 world_normal = normalize(vec3(slope.x, 1.0, slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	ALBEDO = col;
}

void light() {
	// Stepped diffuse: three hard bands keep the toon read.
	float ndl = dot(NORMAL, LIGHT);
	float toon = 0.25 + 0.35 * step(toon_soft, ndl) + 0.40 * step(toon_mid, ndl);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * toon;

	// Sun glint on the slope normals (kept low so it doesn't blow out).
	vec3 half_vec = normalize(LIGHT + VIEW);
	float glint = pow(max(dot(NORMAL, half_vec), 0.0), glint_sharpness);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * glint * glint_strength;
}
