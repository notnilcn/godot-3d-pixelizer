#[compute]
#version 450

// God rays through the banded cloud layer: for each pixel, march from the
// camera toward the reconstructed world position and accumulate the gaps
// with the cloud plane projected along the sun direction. Runs FIRST in the
// PRE_TRANSPARENT compositor array (before the snapshot pass) and writes additively
// into the scene colour, so the rays are part of the image that the
// anchor-map/apply passes later replicate into macro-pixels.
//
// Endpoint-lerp optimisation: the camera and the surface point are projected
// onto the cloud plane once, then each step lerps between the two plane UVs —
// valid because the sun projection is affine in the world position.
//
// The cloud field mirrors `cloud_fbm.gdshaderinc` (cloud_noise_at +
// cloud_coverage_from_noise) so rays pour through the same gaps the cloud
// shadows come from. The engine depth target is y-flipped relative to colour
// (see copy_scene.glsl); the depth sample is unflipped here.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_layer;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2) uniform sampler2D cloud_noise;

// 15 vec4s / 240 bytes (mat4 + 11 vec4s); PixelizerGodRayEffect.PARAMS_SIZE
// must match.
layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inv_view_proj;
	vec4 camera_pos;      // xyz = world camera position
	vec4 sun_dir;         // xyz = world direction the light travels (downward)
	vec4 cloud_params;    // x = noise scale, y = threshold, z = bands, w = plane height
	vec4 cloud_params2;   // x = tightness, y = softness, z = band levels, w = banding enabled
	vec4 cloud_params3;   // x = gap erosion, y = detail strength, z = time, w = unused
	vec4 cloud_wind;      // xy = wind
	vec4 ray_params;      // x = max distance, y = intensity, z = decay, w = quantize bands
	vec4 ray_params2;     // x = dust strength, y = steps, z = near fade start, w = near fade range
	vec4 ray_params3;     // x = near fade power, y = depth cutoff, z = surface fade, w = max stack
	vec4 ray_params4;     // x = quantum, y = distance falloff
	vec4 ray_tint;        // xyz = ray colour
};

// World point -> raw cloud-plane horizontal coordinates (before scale/wind).
vec2 cloud_plane_pos(vec3 p) {
	// sun_dir.y < 0 (light travels down), so t is negative and p + sun_dir * t
	// walks toward the sun up to the cloud plane.
	float t = (cloud_params.w - p.y) / min(sun_dir.y, -0.0001);
	return (p + sun_dir.xyz * t).xz;
}

vec2 cloud_uv(vec2 plane_pos) {
	return plane_pos * cloud_params.x + cloud_wind.xy * cloud_params3.z;
}

// 1 = sunlight reaches the eye through this sample, 0 = cloud blocks it.
float cloud_gap(vec2 plane_pos) {
	vec2 uv = cloud_uv(plane_pos);
	float n = textureLod(cloud_noise, uv, 0.0).r;
	if (cloud_params3.y > 0.0) {
		float detail = textureLod(cloud_noise, uv * 2.17 + vec2(0.37, 0.11), 0.0).r;
		n = mix(n, n * 0.65 + detail * 0.35, cloud_params3.y);
	}
	n += cloud_params3.x; // gap erosion, applied before coverage like cloud_shadow()
	float coverage = smoothstep(cloud_params.y - cloud_params2.y, cloud_params.y, n);
	coverage = pow(coverage, max(cloud_params2.x, 0.0001));
	if (cloud_params2.w > 0.5) {
		float levels = max(cloud_params2.z, 1.0);
		coverage = ceil(coverage * levels) / levels;
	}
	return 1.0 - clamp(coverage, 0.0, 1.0);
}

// Shaft attenuation at world distance `t` along a ray of length `ray_len`.
// Three independent distance windows (near fade-in, far cutoff, surface
// approach) plus an exponential distance falloff. Windows are anchored on world
// distances, so the tunables read as distances rather than as curve powers.
float shaft_attenuation(float t, float ray_len) {
	float atten = 1.0;
	// Near fade-in: hold at zero until the start, ramp up over the range.
	if (ray_params2.z > 0.0 || ray_params2.w > 0.0) {
		float ramp = clamp((t - ray_params2.z) / max(ray_params2.w, 1e-4), 0.0, 1.0);
		atten *= pow(ramp, max(ray_params3.x, 1e-4));
	}
	// Far cutoff: a soft window that reaches zero at the cutoff distance.
	if (ray_params3.y > 0.0) {
		float cutoff = ray_params3.y;
		float band = clamp(cutoff * 0.1, 0.5, 50.0);
		atten *= 1.0 - smoothstep(cutoff - band, cutoff, t);
	}
	// Surface approach: dim the shaft as it nears the hit point.
	if (ray_params3.z > 0.0) {
		atten *= clamp((ray_len - t) / ray_params3.z, 0.0, 1.0);
	}
	// Distance falloff.
	atten *= exp(-max(ray_params4.y, 0.0) * t);
	return atten;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_layer);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float depth = textureLod(scene_depth, vec2(uv.x, 1.0 - uv.y), 0.0).r;

	// Reversed-Z reconstruction (near = 1, far = 0); the inverse matrix
	// handles the Z mapping, sky reconstructs at the far plane.
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 world4 = inv_view_proj * ndc;
	vec3 world = world4.xyz / world4.w;

	vec3 origin = camera_pos.xyz;
	vec3 ray = world - origin;
	float ray_len = length(ray);
	vec3 ray_dir = ray / max(ray_len, 1e-5);
	float march_len = (ray_params.x > 0.0) ? min(ray_len, ray_params.x) : ray_len;

	int steps = int(clamp(ray_params2.y, 1.0, 256.0));
	vec2 plane0 = cloud_plane_pos(origin);
	vec2 plane1 = cloud_plane_pos(origin + ray_dir * march_len);

	float dust = 1.0;
	if (ray_params2.x > 0.0) {
		// Slow, high-threshold noise modulates the whole shaft (dustiness).
		vec2 dust_uv = cloud_uv(plane1) * 0.35 + cloud_wind.xy * cloud_params3.z * 0.3;
		float d = textureLod(cloud_noise, dust_uv, 0.0).r;
		dust = mix(1.0, smoothstep(0.55, 0.9, d), ray_params2.x);
	}

	// Volumetric transmittance march (Beer-Lambert). Light in-scatters through
	// the cloud gaps and is attenuated along the same ray, so denser shafts
	// self-shadow instead of summing independently. The march start is jittered
	// per pixel to break up slice banding at low step counts.
	float inv_steps = 1.0 / float(steps);
	float jitter = fract(sin(dot(vec2(pixel), vec2(12.9898, 78.233))) * 43758.5453);
	float extinction = max(ray_params.z, 0.0);
	float transmittance = 1.0;
	float accum = 0.0;
	for (int i = 0; i < steps; i++) {
		float t = (float(i) + jitter) * inv_steps;
		float tuk = t * march_len;
		float gap = cloud_gap(mix(plane0, plane1, t));
		float fade = shaft_attenuation(tuk, ray_len);
		// In-scatter weighted by how much light survives the path so far.
		accum += transmittance * gap * fade * inv_steps;
		transmittance *= exp(-extinction * inv_steps);
	}

	float quantum = (ray_params4.x > 0.0) ? ray_params4.x : 1.0;
	accum *= quantum;
	float bands_q = ray_params.w;
	if (bands_q > 1.0) {
		accum = floor(accum * bands_q + 0.5) / bands_q;
	}
	if (ray_params3.w > 0.0) {
		accum = min(accum, ray_params3.w);
	}

	vec3 ray_color = ray_tint.rgb * ray_params.y * accum * dust;
	imageStore(color_layer, pixel, imageLoad(color_layer, pixel) + vec4(ray_color, 0.0));
}
