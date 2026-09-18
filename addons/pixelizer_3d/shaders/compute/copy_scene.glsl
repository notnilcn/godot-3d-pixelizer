#[compute]
#version 450

// Snapshots the scene colour AND depth into named render-scene-buffer textures
// in one dispatch, so the apply pass can sample both while writing the scene
// attachments in place (a texture cannot be a framebuffer attachment and a
// uniform in the same pass).

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2, rgba16f) uniform image2D destination_color;
layout(set = 0, binding = 3, r32f) uniform image2D destination_depth;

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(destination_color);
	if (pos.x >= size.x || pos.y >= size.y) {
		return;
	}
	vec2 uv = (vec2(pos) + vec2(0.5)) / vec2(size);
	imageStore(destination_color, pos, texture(source_color, uv));
	// The engine depth target is y-flipped relative to colour; the copy is
	// stored colour-oriented so downstream passes can use plain UVs.
	imageStore(destination_depth, pos, vec4(texture(depth_texture, vec2(uv.x, 1.0 - uv.y)).r, 0.0, 0.0, 0.0));
}
