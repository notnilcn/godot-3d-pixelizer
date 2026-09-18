// Pixelizer3D cloud coverage toolkit. The uniform names in the
// `Effects.Cloud_Shadows` group are the contract shared with
// MarchingSquaresTerrain's `mst_terrain.gdshaderinc` and the water shader, so
// PixelizerManager3D.register_cloud_material() can push the same values to all
// registered materials. Include inside a spatial shader:
//
//   #include "res://addons/pixelizer_3d/shaders/cloud_fbm.gdshaderinc"
//   ...
//   ALBEDO *= 1.0 - cloud_shadow(world_position);
//
// Guarded so it can be included directly and through anchor_macros.gdshaderinc.

#ifndef CLOUD_FBM_INC
#define CLOUD_FBM_INC

group_uniforms Effects.Cloud_Shadows;
uniform bool clouds_enabled = false;
uniform sampler2D cloud_noise : filter_linear, repeat_enable;
uniform vec3 cloud_sun_dir = vec3(0.0, -1.0, 0.0);
uniform float cloud_height = 10.0;
uniform float cloud_noise_scale = 0.05;
uniform float cloud_threshold : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_bands = 3.0;
uniform float cloud_tightness = 1.0;
uniform float cloud_octave_drop = 0.5;
uniform float cloud_gap_erosion = 0.0;
uniform float cloud_detail_strength = 0.0;
uniform vec2 cloud_wind = vec2(0.02, 0.0);
uniform float cloud_shadow_strength : hint_range(0.0, 1.0) = 0.6;
uniform bool cloud_shadow_banding_enabled = true;
uniform float cloud_shadow_levels = 3.0;
uniform float cloud_shadow_softness : hint_range(0.0, 1.0) = 0.4;
group_uniforms;

// Smooth, optionally banded coverage ramp from a noise sample. Parameters are
// `cloud_`-prefixed because Godot's shader language rejects a parameter that
// shadows a global, and this include is injected into arbitrary third-party
// shaders by the bridge.
float cloud_coverage_from_noise(float cloud_noise_value) {
	float coverage = smoothstep(
		cloud_threshold - cloud_shadow_softness,
		cloud_threshold,
		cloud_noise_value);
	coverage = pow(coverage, max(cloud_tightness, 0.0001));
	if (cloud_shadow_banding_enabled) {
		float levels = max(cloud_shadow_levels, 1.0);
		coverage = ceil(coverage * levels) / levels;
	}
	return clamp(coverage, 0.0, 1.0);
}

// Sample the cloud noise projected along the sun direction onto the cloud plane.
float cloud_noise_at(vec3 cloud_world_position) {
	float sun_y = min(cloud_sun_dir.y, -0.0001);
	float travel = (cloud_height - cloud_world_position.y) / sun_y;
	vec2 plane = cloud_world_position.xz + cloud_sun_dir.xz * travel;
	vec2 uv = plane * cloud_noise_scale + cloud_wind * TIME;
	float cloud_n = texture(cloud_noise, uv).r;
	// Optional procedural detail (FBM approximation from the same texture) and
	// gap erosion keep cloud cores from reading as flat blobs.
	if (cloud_detail_strength > 0.0) {
		float detail = texture(cloud_noise, uv * 2.17 + vec2(0.37, 0.11)).r;
		cloud_n = mix(cloud_n, cloud_n * 0.65 + detail * 0.35, cloud_detail_strength);
	}
	return cloud_n;
}

// 0 = fully lit, up to cloud_shadow_strength = fully shadowed.
float cloud_shadow(vec3 cloud_world_position) {
	if (!clouds_enabled) {
		return 0.0;
	}
	float cloud_n = cloud_noise_at(cloud_world_position);
	if (cloud_gap_erosion > 0.0) {
		cloud_n += cloud_gap_erosion;
	}
	return cloud_coverage_from_noise(cloud_n) * cloud_shadow_strength;
}

#endif
