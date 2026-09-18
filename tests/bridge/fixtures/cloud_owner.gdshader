shader_type spatial;
render_mode depth_draw_opaque;

uniform bool clouds_enabled = false;
uniform float cloud_shadow_strength : hint_range(0.0, 1.0) = 0.6;

void fragment() {
	ALBEDO = vec3(1.0) * (1.0 - (clouds_enabled ? cloud_shadow_strength : 0.0));
}
