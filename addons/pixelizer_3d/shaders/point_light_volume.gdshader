shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

// Pixelizer3D point-light volume — a radial `pow(1 - d)` pool evaluated on
// the opaque scene surface (reconstructed from the depth texture), plus a
// view-ray "source orb" halo from the closest approach of the view ray to the
// light centre. Both terms are optionally quantised into hard bands.
//
// The mesh is a sphere centred on the light (PixelizerPointLightVolume3D); it
// only bounds the screen area the light can affect. Marking is
// occlusion-style: the pool/halo are masked by scene depth, so a wall between the
// camera and the light hides the light instead of the additive orb drawing over
// the wall.
//
// The macros include is deliberate: this material can safely live under a
// PixelizerApplier3D (the metadata camera discards it instead of writing a
// bogus payload) and register_pixelized_material() keeps the factory from
// replacing the additive shader.
//
// `depth_test_disabled` + cull_disabled: both sphere hemispheres produce the
// same screen pixels, so fragments nearer than the light centre are discarded
// to guarantee exactly one additive evaluation per pixel.

#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec4 light_color : source_color = vec4(1.0, 0.85, 0.5, 1.0);
uniform float light_radius = 6.0;
uniform float falloff = 2.0;
// <= 1 disables the banding step.
uniform float band_count = 4.0;
uniform float band_tightness = 4.0;
uniform float intensity = 1.0;

uniform vec4 halo_color : source_color = vec4(1.0, 0.92, 0.65, 1.0);
uniform float halo_size = 1.0;
uniform float halo_intensity = 1.0;
uniform float halo_falloff = 2.0;
uniform float halo_band_count = 4.0;

// When true the whole contribution is hidden when opaque geometry sits in
// front of the light centre (the occlusion-style "no light through walls" gate).
uniform bool occlude_by_depth = true;
// Depth slack for the visibility test: a lamp bulb/housing mesh sitting at the
// light centre must not occlude its own light.
uniform float depth_slack = 0.5;

varying vec3 v_light_view;
varying vec2 v_light_uv;
varying float v_light_w;

// Posterise a 0..1 falloff into `bands` equal steps. `tightness` is how hard
// the band edges read: 1 keeps the continuous falloff, larger values drive the
// result toward the quantised value (hard pixel-art bands).
float volume_banded(float value, float bands, float tightness) {
	if (bands <= 1.0) {
		return value;
	}
	float softness = clamp(1.0 - 1.0 / max(tightness, 1.0), 0.0, 1.0);
	float quantised = round(clamp(value, 0.0, 1.0) * bands) / bands;
	return mix(value, quantised, softness);
}

void vertex() {
	ANCHOR_VERTEX(0);
	// The light sits at the node origin (the mesh is centred on it).
	v_light_view = (VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz;
	vec4 light_clip = PROJECTION_MATRIX * vec4(v_light_view, 1.0);
	v_light_w = light_clip.w;
	v_light_uv = (light_clip.xy / max(abs(light_clip.w), 1e-5)) * 0.5 + 0.5;
}

void fragment() {
	// Keep the volume out of the metadata camera (it would write a bogus
	// payload and punch holes in the anchor map).
	if (ANCHOR_META_ACTIVE(0)) {
		discard;
	}
	// Exactly one hemisphere survives per pixel: only fragments farther from
	// the camera than the light centre add light (works with the camera both
	// outside and inside the volume).
	if (length(VERTEX) < length(v_light_view)) {
		discard;
	}

	vec3 ray_dir = normalize(VERTEX);
	float pixel_depth = -VERTEX.z;
	float fwd_dot = max(-ray_dir.z, 1e-4);

	// Reconstruct the opaque surface under this pixel (reverse-Z depth).
	float raw_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene_view_h = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
	vec3 scene_view = scene_view_h.xyz / scene_view_h.w;
	float scene_depth = -scene_view.z;
	float scene_t = (scene_depth - pixel_depth) / fwd_dot;
	vec3 scene_pos = VERTEX + ray_dir * scene_t;

	// Radial pool on the scene surface (pow(saturate(1 - d / radius))).
	float dist = distance(scene_pos, v_light_view);
	float nd = clamp(dist / max(light_radius, 1e-4), 0.0, 1.0);
	float atten = pow(max(1.0 - nd, 0.0), max(falloff, 1e-3));
	atten = volume_banded(atten, band_count, band_tightness);

	// Visible source orb: closest approach of the view ray to the light.
	float t_center = dot(v_light_view - VERTEX, ray_dir);
	vec3 closest = VERTEX + ray_dir * t_center;
	float h_dist = distance(v_light_view, closest);
	float halo = pow(clamp(1.0 - h_dist / max(halo_size, 1e-4), 0.0, 1.0), max(halo_falloff, 1e-3));
	halo = volume_banded(halo, halo_band_count, band_tightness);

	if (occlude_by_depth && v_light_w > 0.0) {
		// Occlusion-style: is opaque geometry in front of the light centre?
		// Sample the scene depth at the light's screen position — a wall
		// between the camera and the light hides the whole contribution,
		// while the pool stays view-independent on surfaces around the lamp.
		float raw = texture(depth_texture, v_light_uv).r;
		vec4 lv = INV_PROJECTION_MATRIX * vec4(v_light_uv * 2.0 - 1.0, raw, 1.0);
		float surface_depth = -(lv.z / lv.w);
		float light_depth = -v_light_view.z;
		float visible = step(light_depth - max(depth_slack, light_depth * 0.005), surface_depth);
		atten *= visible;
		halo *= visible;
	}

	// ALBEDO, not EMISSION: Godot ignores EMISSION for unshaded materials, and
	// `blend_add` adds ALBEDO straight into the framebuffer.
	ALBEDO = light_color.rgb * (atten * intensity) + halo_color.rgb * (halo * halo_intensity);
}
