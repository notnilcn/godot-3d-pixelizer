shader_type spatial;
render_mode depth_draw_opaque, cull_back, diffuse_toon, specular_disabled;

// Pixelizer3D screen-space texture projection.
//
// The texture is "painted onto the screen": sampling uses SCREEN_UV so the
// projected texels stay locked to the screen's pixel grid (no texture swimming
// on moving meshes); the mesh supplies shape, depth and lighting.
//
// `pixelizer_screen_size` is the `PixelizerGlobals.SCREEN_SIZE` global shader
// uniform, set once by PixelizerManager3D (and on every `render_resolution`
// change). It holds the INTERNAL render resolution (not the window resolution),
// so a `texture_size` of (16, 16) means "one texture tile every 16 internal
// pixels".
//
// `lock_to_object` subtracts the mesh origin's projected pixel offset, so the
// texture scrolls with the object instead of being glued to the screen.
//
// ANCHOR OPT-IN: includes anchor_macros.gdshaderinc — register the
// material with `PixelizerManager3D.register_pixelized_material(material)` so
// the object is anchor-clipped and replicated like the rest of the scene.

#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

global uniform vec2 pixelizer_screen_size;
uniform sampler2D projection_texture : source_color, filter_nearest, repeat_enable;
// Pixel dimensions of the projected texture (tile period in internal pixels).
uniform vec2 texture_size = vec2(16.0, 16.0);
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// Subtract the mesh origin's screen offset so the pattern follows the object.
uniform bool lock_to_object = true;
// Rotate the projection grid in screen space (radians).
uniform float projection_angle = 0.0;

varying vec2 f_origin_px;

void vertex() {
	// Mesh origin in internal pixels, relative to the screen centre.
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	vec2 ndc = clip.xy / max(abs(clip.w), 0.0001) * sign(clip.w);
	f_origin_px = ndc * 0.5 * pixelizer_screen_size;  // = clip.xy / clip.w * 0.5 * screen_size
	ANCHOR_VERTEX(0);
}

void fragment() {
	ANCHOR_CLIP(tint.a);
	if (ANCHOR_META_ACTIVE(0)) {
		ANCHOR_META_LIGHT(0);
	} else {
		vec2 screen_px = SCREEN_UV * pixelizer_screen_size;
		if (lock_to_object) {
			screen_px -= f_origin_px;
		}
		if (abs(projection_angle) > 0.0001) {
			float s = sin(projection_angle);
			float c = cos(projection_angle);
			screen_px = mat2(vec2(c, s), vec2(-s, c)) * screen_px;
		}
		vec2 uv = screen_px / max(texture_size, vec2(1.0));
		vec3 col = texture(projection_texture, uv).rgb;
		ALBEDO = ANCHOR_GRADE(col * tint.rgb);
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
		SPECULAR = 0.0;
	}
}
