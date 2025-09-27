shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_front,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

/* The terrain depends on this shader to function. Don't change most things in vertex() or
 * terrain normal calculations in fragment(). You probably only want to customize the
 * material calculation and PBR application in fragment().
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However,
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

// Defined Constants
#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2
#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.5)
#define DIV_255 0.003921568627450 // 1. / 255.
#define DIV_1024 0.0009765625 // 1. / 1024.
#define TAU_16TH -0.392699081698724 // -TAU / 16.

// Inline Functions
#define DECODE_BLEND(control) float(control >> 14u & 0xFFu) * DIV_255
#define DECODE_AUTO(control) bool(control & 0x1u)
#define DECODE_BASE(control) int(control >> 27u & 0x1Fu)
#define DECODE_OVER(control) int(control >> 22u & 0x1Fu)
#define DECODE_ANGLE(control) float(control >>10u & 0xFu) * TAU_16TH
// This math recreates the scale value directly rather than using an 8 float const array.
#define DECODE_SCALE(control) (0.9 - float(((control >>7u & 0x7u) + 3u) % 8u + 1u) * 0.1)
#define DECODE_HOLE(control) bool(control >>2u & 0x1u)

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    #define fma(a, b, c) ((a) * (b) + (c))
    #define dFdxCoarse(a) dFdx(a)
    #define dFdyCoarse(a) dFdy(a)
#endif

// Private uniforms
uniform vec3 _camera_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1./_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
#define FILTER_LINEAR

// Public uniforms

group_uniforms shadow_settings;
uniform float directional_depth_bias: hint_range(0.0, 1000.0) = 50.0;
uniform float directional_height_bias: hint_range(0.0, 100.0) = 4.0;
uniform float perspective_depth_bias: hint_range(0.0, 1000.0) = 50;
uniform float perspective_height_bias: hint_range(0.0, 1000.0) = 20.0;
uniform float perspective_decaying_depth_bias: hint_range(-1000.0, 1000.0) = 0.0; //Positive dec-bias + small bias is better overall, negative dec-bias + big bias is better very upclose.
group_uniforms;

group_uniforms world_background_noise;
uniform bool world_noise_fragment_normals = false;
uniform float world_noise_region_blend : hint_range(0.05, 0.95, 0.01) = 0.33;
uniform int world_noise_max_octaves : hint_range(0, 15) = 4;
uniform int world_noise_min_octaves : hint_range(0, 15) = 2;
uniform float world_noise_lod_distance : hint_range(0, 40000, 1) = 7500.;
uniform float world_noise_scale : hint_range(0.25, 20, 0.01) = 5.0;
uniform float world_noise_height : hint_range(0, 1000, 0.1) = 64.0;
uniform vec3 world_noise_offset = vec3(0.0);
group_uniforms;

// Varyings & Types

varying float v_vertex_xz_dist;

////////////////////////
// Vertex
////////////////////////

// Takes in world space XZ (UV) coordinates & search depth (only applicable for background mode none)
// Returns ivec3 with:
// XY: (0 to _region_size - 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_index_coord(const vec2 uv, const int search) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv,_region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < clamp(search, SKIP_PASS, FRAGMENT_PASS); i++) {
		if ((layer_index == -1 && _background_mode == 0u ) || i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(float(o_uv.x <= o_uv.y), float(o_uv.y <= o_uv.x));
			pos = ivec2(floor((r_uv) * _region_texel_size)) + (_region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
			layer_index = (_region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1);
		}
	}
	return ivec3(ivec2(mod(r_uv,_region_size)), layer_index);
}

// World Noise Functions Start

// Takes in UV2 region space coordinates, returns 1.0 or 0.0 if a region is present or not.
float check_region(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int layer_index = 0;
	if (uint(pos.x | pos.y) < uint(_region_map_size)) {
		layer_index = clamp(_region_map[ pos.y * _region_map_size + pos.x ] - 1, -1, 0) + 1;
	}
	return float(layer_index);
}

// Takes in UV2 region space coordinates, returns a blend value (0 - 1 range) between empty, and valid regions
float region_blend(vec2 uv2) {
	uv2 -= 0.5;
	const vec2 offset = vec2(0.0,1.0);
	float a = check_region(uv2 + offset.xy);
	float b = check_region(uv2 + offset.yy);
	float c = check_region(uv2 + offset.yx);
	float d = check_region(uv2 + offset.xx);
	vec2 w = smoothstep(vec2(0.0), vec2(1.0), fract(uv2));
	float blend = mix(mix(d, c, w.x), mix(a, b, w.x), w.y);
    return 1.0 - blend;
}

float hashv2(vec2 v) {
	return fract(1e4 * sin(fma(17.0, v.x, v.y * 0.1)) * (0.1 + abs(sin(fma(v.y, 13.0, v.x)))));
}

// https://iquilezles.org/articles/morenoise/
vec3 noise2D(vec2 x) {
    vec2 f = fract(x);
    // Quintic Hermine Curve.  Similar to SmoothStep()
	vec2 f2 = f * f, f3 = f2 * f, s = f - 1.0, s2 = s * s;
	vec2 u = f3 * fma(vec2(6.0), f2, fma(vec2(-15.0), f, vec2(10.0)));
	vec2 du = 30.0 * f2 * s2;

    vec2 p = floor(x);

	// Four corners in 2D of a tile
	float a = hashv2( p+vec2(0,0) );
    float b = hashv2( p+vec2(1,0) );
    float c = hashv2( p+vec2(0,1) );
    float d = hashv2( p+vec2(1,1) );

    // Mix 4 corner percentages
    float k0 =   a;
    float k1 =   b - a;
    float k2 =   c - a;
    float k3 =   d - (b + k2);
	return vec3(fma(k2, u.y, fma(u.x, fma(k3, u.y, k1), k0)),
		 du * fma(vec2(k3), u.yx, vec2(k1, k2)));
}

float world_noise(vec2 p) {
    float a = 0.0;
    float b = 1.0;
    vec2  d = vec2(0.0);

    int octaves = int( clamp(
		float(world_noise_max_octaves) - floor(v_vertex_xz_dist/(world_noise_lod_distance)),
		float(world_noise_min_octaves), float(world_noise_max_octaves))
	);

    for( int i=0; i < octaves; i++ ) {
        vec3 n = noise2D(p);
        d += n.yz;
        a += b * n.x / (1.0 + dot(d,d));
        b *= 0.5;
        p = mat2( vec2(0.8, -0.6), vec2(0.6, 0.8) ) * p * 2.0;
    }
    return a;
}

float get_noise_height(const vec2 uv) {
	float weight = region_blend(uv);
	// only calculate world noise when it could be visibile.
	if (weight <= 1.0 - world_noise_region_blend) {
		return 0.0;
	}
	//TODO: Offset/scale UVs are semi-dependent upon region size 1024. Base on v_vertex.xz instead
	float noise = world_noise((uv + world_noise_offset.xz * 1024. / _region_size) * world_noise_scale * _region_size / 1024. * .1) *
            world_noise_height * 10. + world_noise_offset.y * 100.;
	weight = smoothstep(1.0 - world_noise_region_blend, 1.0, weight);
	return mix(0.0, noise, weight);
}

// World Noise Functions End

bool is_orthographic(mat4 matrix) {
	//Broken for paraboloid omnis.
	//return matrix[2].w == 0.0;
	vec3 a1 = vec3(0, 1, 0);
	vec3 b1 = vec3(0, 1, 1);
	vec4 a2 = matrix * vec4(a1, 1);
	vec4 b2 = matrix * vec4(b1, 1);
	return a2.w == b2.w; //This works accurately as far as I can test but I have no idea why or how.
}

void vertex() {
	// Get vertex of flat plane in world coordinates and set world UV
	vec3 v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Camera distance to vertex on flat plane
	v_vertex_xz_dist = length(v_vertex.xz - _camera_pos.xz);

	// Geomorph vertex, set end and start for linear height interpolate
	float scale = MODEL_MATRIX[0][0];
	float vertex_lerp = smoothstep(0.55, 0.95, (v_vertex_xz_dist / scale - _mesh_size - 4.0) / (_mesh_size - 2.0));
	vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
	// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
	vec2 shift = (scale < _vertex_spacing + 1e-6) ? // LOD0 or not
		// Shift from regular to symetric
		mix(v_fract, vec2(v_fract.x, -v_fract.y),
			round(fract(round(mod(v_vertex.z * _vertex_density, 4.0)) *
			round(mod(v_vertex.x * _vertex_density, 4.0)) * 0.25))
			) :
		// Symetric shift
		v_fract * round((fract(v_vertex.xz * 0.25 / scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	// Discard vertices for Holes. 1 lookup
	ivec3 v_region = get_index_coord(start_pos, VERTEX_PASS);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = DECODE_HOLE(control);

	// Show holes to all cameras except mouse camera (on exactly 1 layer). As this is shadow shader though, there's never a mouse layer.
	if (hole || (_background_mode == 0u && v_region.z == -1)) {
		v_vertex.x = 0. / 0.;
	} else {
		// Set final vertex height & calculate vertex normals. 3 lookups
		ivec3 coord_a = get_index_coord(start_pos, VERTEX_PASS);
		ivec3 coord_b = get_index_coord(end_pos, VERTEX_PASS);
		float h = mix(texelFetch(_height_maps, coord_a, 0).r,texelFetch(_height_maps, coord_b, 0).r,vertex_lerp);
		// World Noise
		if (_background_mode == 2u) {
			vec2 nuv_a = fma(start_pos, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));
			vec2 nuv_b = fma(end_pos, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));
			float nh = mix(get_noise_height(nuv_a),get_noise_height(nuv_b),vertex_lerp);
			float nu = mix(get_noise_height(nuv_a + vec2(_region_texel_size, 0.0)),
				get_noise_height(nuv_b + vec2(_region_texel_size, 0.0)),vertex_lerp);
			float nv = mix(get_noise_height(nuv_a + vec2(0.0, _region_texel_size)),
				get_noise_height(nuv_b + vec2(0.0, _region_texel_size)),vertex_lerp);
			//This does nothing?
			//world_noise_ddxy = vec2(nh - nu, nh - nv);
			h += nh;
		}

		v_vertex.y = h;
	}

	//Gotta find ways to compute good shadow offsets, and that requires digging into the engine's code.
	//Directional lights, for example, have a shadow bias that varies from cascade to cascade so it's complex to counteract the effect.
	/*
	From Godot 4.5 source at: servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl:2081

	```glsl
	#define BIAS_FUNC(m_var, m_idx)                                                                 \
		m_var.xyz += light_dir * directional_lights.data[i].shadow_bias[m_idx];                     \
		vec3 normal_bias = base_normal_bias * directional_lights.data[i].shadow_normal_bias[m_idx]; \
		normal_bias -= light_dir * dot(light_dir, normal_bias);                                     \
		m_var.xyz += normal_bias;
	```

	`m_idx` seems to be the cascade for which to compute the bias, either 0,1,2,3.

	Due to `directional_lights.data[i].shadow_bias[m_idx]`, it seems like each cascade has a different CPU-set bias, not computed from the shader.

	This `DirectionalLightdata` GPU struct is defined at servers/rendering/renderer_rd/shaders/light_data_inc.glsl:57

	The CPU equivalent is at servers/rendering/renderer_rd/storage_rd/light_storage.h:186

	Shadow bias is a vector4 and that's fine, because once again each cascade has a separate bias.

	Only one line of code in the entire engine ever writes to that buffer, and it's this one at: servers/rendering/renderer_rd/storage_rd/light_storage.cpp:715

	```cpp
	float bias_scale = light_instance->shadow_transform[j].bias_scale * light_data.soft_shadow_scale;
	light_data.shadow_bias[j] = light->param[RS::LIGHT_PARAM_SHADOW_BIAS] / 100.0 * bias_scale;
	```

	`bias_scale` comes from `ShadowTransform shadow_transform[6];` at servers/rendering/renderer_rd/storage_rd/light_storage.h:107

	Shadow transforms are set through `light_instance_set_shadow_transform` in from servers/rendering/renderer_rd/storage_rd/light_storage.cpp:515

	Shadow transforms for directional lights are set from servers/rendering/renderer_scene_cull.cpp:3358

	```cpp
	const Cull::Shadow::Cascade &c = cull.shadows[i].cascades[j];
	//			print_line("shadow " + itos(i) + " cascade " + itos(j) + " elements: " + itos(c.cull_result.size()));
	RSG::light_storage->light_instance_set_shadow_transform(cull.shadows[i].light_instance, c.projection, c.transform, c.zfar, c.split, j, c.shadow_texel_size, c.bias_scale, c.range_begin, c.uv_scale);
	```

	...Which takes the bias straight through a Cascade struct! So much passing stuff around.

	Once again, each cascade has its own shadow bias.

	And finally, we get to the only line of code in the entire engine that sets the shadow bias for cascades: servers/rendering/renderer_scene_cull.cpp:2418

	`cull.shadows[p_shadow_index].cascades[i].bias_scale = (z_max - z_min_cam);`
	*/
	bool is_directional_light = is_orthographic(PROJECTION_MATRIX);
	//float depth_bias = float(int(TIME * 100.0) % 500) / 100000.0;
	float depth_bias = (is_directional_light? directional_depth_bias : perspective_depth_bias) * 0.001; //Multiply to keep values in sensible range.
	float fixed_decaying_bias = (is_directional_light? 0.0 : perspective_decaying_depth_bias) * 0.01;
	float vertical_bias = (is_directional_light? directional_height_bias : perspective_height_bias) * 0.001;
	float normalization_factor = PROJECTION_MATRIX[2].z;

	if (is_directional_light) {
		//DIRECTIONAL: Calculate the view space distance between far and near clip planes (needed to counteract Godot's per-cascade shadow bias).
		//See Godot code renderer_scene_cull.cpp:2415: cull.shadows[p_shadow_index].cascades[i].bias_scale = (z_max - z_min_cam);
		const float bias_scale = 0.1;
		float projection_depth = bias_scale / normalization_factor; //think of this as ((1 / normalization_factor) * vertical_bias_scale) with one less multiplication.
		v_vertex += CAMERA_DIRECTION_WORLD * depth_bias * projection_depth;
		v_vertex.y -= vertical_bias * projection_depth;
	} else {
		vec3 delta = v_vertex - CAMERA_POSITION_WORLD;
		v_vertex -= delta * depth_bias + normalize(delta) * fixed_decaying_bias;
		v_vertex.y -= vertical_bias;
	}
	
	//Setting clip position through POSITION breaks dual-paraboloid omnilight shadows, so using VERTEX is a necessary workaround.
	//This happens because Godot uses some special math for dual-paraboloid omnis which accesses hidden data not exposed to normal shaders.
	//See here for the magic sauce: servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl:475
	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz; // Convert model space to view space w/ skip_vertex_transform render mode
}
