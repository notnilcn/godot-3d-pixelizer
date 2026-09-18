shader_type spatial;

// ALPHA_SCISSOR_THRESHOLD must NOT be mistaken for an ALPHA write.
void fragment() {
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALBEDO = vec3(1.0);
}
