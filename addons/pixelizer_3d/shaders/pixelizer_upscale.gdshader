shader_type canvas_item;
render_mode unshaded;

// Pixel-art upscale for the low-res SubViewport display.
//
// The source is a fixed `source_size` thumbnail, so an output pixel maps to a
// small footprint in source-texel space. The output is snapped to the nearest
// source texel centre (flat interiors, no bilinear mush). Only when a pixel
// straddles a texel boundary do we mix in the neighbour across that boundary,
// so the transition lands on the fractional scroll phase instead of popping;
// the blend band is exactly one output pixel wide. `scroll_shift` carries the
// camera snap remainder in source texels so motion reads as smooth.

uniform vec2 scroll_shift = vec2(0.0);
uniform vec2 source_size = vec2(1920.0, 1080.0);

void fragment() {
	vec2 src = UV * source_size - scroll_shift;
	vec2 footprint = max(fwidth(src), vec2(1e-5));
	vec2 nearest = floor(src + 0.5);
	vec2 delta = src - nearest;
	// Per-axis closeness to the boundary with the neighbour (0.5 = on it).
	vec2 edge = vec2(0.5) - abs(delta);
	vec2 weight = clamp(1.0 - edge / max(0.5 * footprint, vec2(1e-6)), vec2(0.0), vec2(1.0));
	// Blend only across the axis the footprint actually crosses.
	vec2 neighbour = nearest;
	if (weight.x >= weight.y) {
		neighbour.x += sign(delta.x);
	} else {
		neighbour.y += sign(delta.y);
	}
	vec4 center = textureLod(TEXTURE, (nearest + 0.5) / source_size, 0.0);
	vec4 across = textureLod(TEXTURE, (neighbour + 0.5) / source_size, 0.0);
	COLOR = mix(center, across, 0.5 * max(weight.x, weight.y));
}
