shader_type spatial;
render_mode depth_draw_opaque;

uniform vec4 tint : source_color = vec4(1.0);

void vertex() {
	VERTEX += NORMAL * 0.0;
}

void fragment() {
	vec4 c = tint;
	ALBEDO = c.rgb;
	ALPHA = c.a;
}

// drift
