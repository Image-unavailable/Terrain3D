shader_type spatial;
render_mode cull_disabled;

void vertex() {
	// Called for every vertex the material is visible on.
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1)).xyz;
	vec3 view = (VIEW_MATRIX * vec4(world, 1)).xyz;
	
	vec3 vertex_interp = view;
	float z_far = (INV_PROJECTION_MATRIX * vec4(0, 0, 1, 1)).w;
	
	//Magic sauce from Godot source for dual-paraboloid omnis: servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl:475
	//vertex_interp.z *= scene_data.dual_paraboloid_side;

	//dp_clip = vertex_interp.z; //this attempts to avoid noise caused by objects sent to the other parabolloid side due to bias

	//for dual paraboloid shadow mapping, this is the fastest but least correct way, as it curves straight edges

	/*vec3 vtx = vertex_interp;
	float distance_value = length(vtx);
	vtx = normalize(vtx);
	vtx.xy /= 1.0 - vtx.z;
	vtx.z = (distance_value / z_far);
	vtx.z = vtx.z * 2.0 - 1.0;
	vertex_interp = vtx;*/
	
	//POSITION = (PROJECTION_MATRIX * vec4(view, 1));
}
