extends Node3D

## Windowed smoke test: compiles and renders each generated MST bridge shader on
## a quad, saves a screenshot, then quits. A compile failure shows up as
## `SHADER ERROR` in the log; a black frame surfaces a runtime failure.
##
## Run:
##   Godot-stable_mono_win64_console.exe --path . res://tests/bridge/compile_test.tscn

const SHADERS := [
	"res://tests/bridge/generated/mst_terrain.gdshader",
	"res://tests/bridge/generated/mst_terrain_baked.gdshader",
	"res://tests/bridge/generated/mst_grass.gdshader",
]

var _frames := 0


func _ready() -> void:
	# Register the pipeline globals before loading any shader that declares them,
	# otherwise Godot warns "global parameter ... removed at some point".
	PixelizerGlobals.ensure()
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.6
	environment.environment = env
	add_child(environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	light.light_energy = 1.2
	add_child(light)

	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 4.0)
	camera.current = true
	add_child(camera)

	for i in SHADERS.size():
		var material := ShaderMaterial.new()
		material.shader = load(SHADERS[i])
		var mesh := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(1.1, 1.1)
		mesh.mesh = quad
		mesh.material_override = material
		mesh.position = Vector3((float(i) - 1.0) * 1.3, 0.0, 0.0)
		add_child(mesh)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 20:
		var image := get_viewport().get_texture().get_image()
		var error := image.save_png("res://tests/bridge/generated/compile_test.png")
		print("compile_test screenshot err=%d size=%s" % [error, str(image.get_size())])
		get_tree().quit()
