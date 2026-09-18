shader_type spatial;
render_mode depth_draw_opaque, cull_back, diffuse_toon, specular_toon;

// Anchor clip, metadata branch, vertex-colour/cloud grading and the shared
// uniforms/varyings live in the opt-in macro header (single source of truth for
// custom shaders too). See anchor_macros.gdshaderinc.
#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

// ── Appearance (populated from the source BaseMaterial3D by the addon) ─────────
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_nearest, repeat_enable;
uniform vec4 emission_color : source_color = vec4(0.0);
uniform float emission_energy = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular_amount : hint_range(0.0, 1.0) = 0.5;

void vertex() {
	ANCHOR_VERTEX(0);
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ANCHOR_CLIP(tex.a * albedo_color.a);
	if (ANCHOR_META_ACTIVE(0)) {
		ANCHOR_META_LIGHT(0);
	} else {
		ALBEDO = ANCHOR_GRADE(tex.rgb * albedo_color.rgb);
		ROUGHNESS = roughness;
		METALLIC = metallic;
		SPECULAR = specular_amount;
		if (emission_color.a > 0.0) {
			EMISSION = emission_color.rgb * emission_energy;
		}
	}
}
