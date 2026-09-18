shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

// Pixelizer3D firefly glow — one camera-facing additive quad per firefly in a
// MultiMesh. Replaces the old per-firefly PixelizerPointLightVolume3D node (the
// fly swarm is now two draw calls: bodies + glows).
//
// The per-instance transform only carries translation and a uniform pulse
// scale; the shader billboards the quad at that world position and uses the
// transform scale as the per-instance pulse. Occlusion mirrors the point-light
// volume: sample the scene depth at the glow's projected centre and hide the
// whole glow when opaque geometry sits in front.
//
// The macros include is deliberate: the material can live under a
// PixelizerApplier3D (metadata camera discards it) and
// register_pixelized_material() keeps the factory from replacing the additive
// shader.

#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec4 glow_color : source_color = vec4(1.0, 0.85, 0.4, 1.0);
// World-space half-size of the glow quad.
uniform float glow_radius = 0.7;
uniform float glow_intensity = 1.2;
// When true the glow is hidden when opaque geometry sits in front of its centre.
uniform bool occlude_by_depth = true;
uniform float depth_slack = 0.5;

varying vec3 v_center_view;
varying vec4 v_center_clip;
varying float v_scale;

void vertex() {
	ANCHOR_VERTEX(0);
	vec3 center_world = MODEL_MATRIX[3].xyz;
	float instance_scale = length(MODEL_MATRIX[0].xyz);
	v_scale = instance_scale;
	vec3 center_view = (VIEW_MATRIX * vec4(center_world, 1.0)).xyz;
	v_center_view = center_view;
	v_center_clip = PROJECTION_MATRIX * vec4(center_view, 1.0);
	// Camera-facing quad centred on the instance origin.
	vec3 local = vec3(VERTEX.xy * glow_radius * 2.0 * instance_scale, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(center_view + local, 1.0);
	v_world_pos = center_world;
	v_view_depth = -center_view.z;
}

void fragment() {
	// Keep the glow out of the metadata camera (it would write a bogus payload).
	if (ANCHOR_META_ACTIVE(0)) {
		discard;
	}
	vec2 uv = UV * 2.0 - 1.0;
	float d = length(uv);
	if (d > 1.0) {
		discard;
	}
	float falloff = pow(clamp(1.0 - d, 0.0, 1.0), 2.0);

	float visible = 1.0;
	if (occlude_by_depth && v_center_clip.w > 0.0) {
		vec2 center_uv = v_center_clip.xy / max(abs(v_center_clip.w), 1e-5) * 0.5 + 0.5;
		float raw = texture(depth_texture, center_uv).r;
		vec4 sv = INV_PROJECTION_MATRIX * vec4(center_uv * 2.0 - 1.0, raw, 1.0);
		float surface_depth = -(sv.z / sv.w);
		float center_depth = -v_center_view.z;
		visible = step(center_depth - max(depth_slack, center_depth * 0.005), surface_depth);
	}

	// ALBEDO, not EMISSION: Godot ignores EMISSION for unshaded materials.
	ALBEDO = glow_color.rgb * falloff * glow_intensity * v_scale * visible;
}
