shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

// Visible banded cloud deck — the sky-side companion of the addon's cloud
// shadows and god rays. Includes cloud_fbm.gdshaderinc and draws the exact
// coverage field the shadows use (cloud_noise_at + cloud_coverage_from_noise),
// so the blobs overhead sit in the same place as the shadows on the ground and
// the gaps the god rays pour through.
//
// Deliberately OPAQUE with alpha scissor: pixelized objects only write depth at
// anchor fragments, so a transparent cloud sheet between the camera and a
// character would draw over it and "dissolve" it into anchor dots.
//
// PixelizerSkyClouds3D feeds this: the cloud uniforms come from the manager's
// register_cloud_material() push, cloud_color/edge_fade plus the live camera
// frame (cam_pos/cam_up/half_h/bound_on) are pushed by the helper.

#include "res://addons/pixelizer_3d/shaders/cloud_fbm.gdshaderinc"

// Mipmapped copy of the same noise (pushed by PixelizerSkyClouds3D). The
// include's `cloud_noise` is `filter_linear` (no mips, MST contract); the deck
// is viewed at near-grazing angles, where a mip-less 256px noise aliases into
// dot moiré. Coverage below mirrors cloud_noise_at() but samples this one.
uniform sampler2D cloud_noise_hi : filter_linear_mipmap, repeat_enable;
uniform vec4 cloud_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float edge_fade : hint_range(0.0, 0.5) = 0.15; // UV-space fade at the plane border
// Frustum exit-line erosion (driven per-frame by PixelizerSkyClouds3D): on
// shallow pitches the tilted ortho box leaves the horizontal deck through its
// side, which would draw a hard straight cut across the frame. oy_n is the
// fragment's screen-row in units of half the frustum height, and bound_on is
// the row of that exit line (parked off-frame, |bound_on| > 1, when the whole
// frame hits the deck). Cloud alpha erodes with noise breakup around the line.
uniform vec3 cam_pos;
uniform vec3 cam_up = vec3(0.0, 1.0, 0.0);
uniform vec3 cam_fwd = vec3(0.0, 0.0, -1.0);
uniform float half_h = 1000000.0;
uniform float bound_on = -1000000.0;
uniform float edge_width = 0.10; // half-width of the erosion band, in half-frustums
uniform float edge_wiggle = 0.09; // noise breakup amplitude, in half-frustums

varying vec3 world_pos;

// cloud_noise_at() with the mipmapped sampler (implicit LOD handles the
// grazing-angle minification).
float sheet_noise_at(vec3 world_position) {
	float sun_y = min(cloud_sun_dir.y, -0.0001);
	float travel = (cloud_height - world_position.y) / sun_y;
	vec2 plane = world_position.xz + cloud_sun_dir.xz * travel;
	vec2 uv = plane * cloud_noise_scale + cloud_wind * TIME;
	float noise_value = texture(cloud_noise_hi, uv).r;
	if (cloud_detail_strength > 0.0) {
		float detail = texture(cloud_noise_hi, uv * 2.17 + vec2(0.37, 0.11)).r;
		noise_value = mix(noise_value, noise_value * 0.65 + detail * 0.35, cloud_detail_strength);
	}
	return noise_value;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = sheet_noise_at(world_pos) + cloud_gap_erosion;
	float cover = cloud_coverage_from_noise(n);
	// Fade the plane border so the sheet never shows a hard rectangular edge.
	vec2 d = abs(UV - 0.5) * 2.0;
	float edge = 1.0 - smoothstep(1.0 - edge_fade * 2.0, 1.0, max(d.x, d.y));
	// Dissolve the frustum exit line: ortho rays sharing a screen row share
	// oy_n (all points on one ortho ray project to the same height along
	// cam_up), so this fades whole rows around the line with a noise-broken
	// contour. Rays cross the deck only on the side of the line that moves
	// toward the plane, which flips with the view direction's Y sign.
	float oy_n = dot(world_pos - cam_pos, cam_up) / half_h;
	float wob = (texture(cloud_noise_hi, world_pos.xz * cloud_noise_scale * 3.7 + vec2(0.37, 0.11) + cloud_wind * TIME * 1.7).r - 0.5) * 2.0 * edge_wiggle;
	float exit_edge = 1.0;
	if (abs(cam_fwd.y) > 0.02) {
		float line = smoothstep(bound_on - edge_width, bound_on + edge_width, oy_n + wob);
		exit_edge = (cam_fwd.y > 0.0) ? (1.0 - line) : line;
	}
	// Two-tone shading by band so the clouds aren't a flat sheet of white.
	float bands = max(cloud_bands, 1.0);
	float banded = floor(n * bands) / bands;
	ALBEDO = cloud_color.rgb * (0.82 + 0.18 * banded);
	ALPHA = cover * edge * exit_edge;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
