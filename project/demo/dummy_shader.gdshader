shader_type spatial;
render_mode cull_disabled, skip_vertex_transform;

void vertex() {
	vec4 world = MODEL_MATRIX * vec4(VERTEX, 1);
	vec4 view = VIEW_MATRIX * world;
	// Called for every vertex the material is visible on.
	VERTEX = view.xyz;
	//VERTEX.z -= 20.0;
	COLOR = vec4(VERTEX.xyz, 1);
	//VERTEX = VERTEX + CAMERA_POSITION_WORLD - vec3(0, 0, 1);
	//POSITION = (PROJECTION_MATRIX * vec4(view, 1));
}

/*void fragment() {
	ALBEDO = COLOR.rgb;
}*/
