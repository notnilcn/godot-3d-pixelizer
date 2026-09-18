shader_type spatial;
#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

void vertex() {
	ANCHOR_VERTEX(0);
}

void fragment() {
	ANCHOR_CLIP(1.0);
	if (ANCHOR_META_ACTIVE(0)) {
		ANCHOR_META_LIGHT(0);
	}
	ALBEDO = vec3(1.0);
}
