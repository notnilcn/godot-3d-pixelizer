extends SceneTree

## Generates the MST bridge shaders in two places:
##   1. `res://tests/bridge/generated/` - fixtures for the windowed compile
##      smoke test (`compile_test.tscn`). Wiped/rebuilt by bridge_fixtures.gd.
##   2. `res://pixelizer_bridges/` - the production manifest the demo manager
##      trusts (`PixelizerManager3D.bridge_manifests`).
## Run:
##   Godot-stable_mono_win64_console.exe --headless --path . \
##     --script res://tests/bridge/generate_bridges.gd

const TARGETS := [
	"res://addons/MarchingSquaresTerrain/resources/shaders/mst_terrain.gdshader",
	"res://addons/MarchingSquaresTerrain/resources/shaders/mst_terrain_baked.gdshader",
	"res://addons/MarchingSquaresTerrain/resources/shaders/mst_grass.gdshader",
]
const FIXTURE_DIR := "res://tests/bridge/generated"
const PRODUCTION_DIR := "res://pixelizer_bridges"


func _initialize() -> void:
	var failed := 0
	failed += _generate_into(FIXTURE_DIR, "mst_bridge_manifest.tres")
	failed += _generate_into(PRODUCTION_DIR, PixelizerBridgeManifest.FILE_NAME)
	quit(1 if failed > 0 else 0)


func _generate_into(out_dir: String, manifest_name: String) -> int:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var manifest := PixelizerBridgeManifest.new()
	manifest.output_dir = out_dir + "/"
	manifest.roots = PackedStringArray(["res://addons/MarchingSquaresTerrain"])
	var failed := 0
	for source: String in TARGETS:
		var result := PixelizerShaderBridge.generate(FileAccess.get_file_as_string(source), source)
		if not result["ok"]:
			print("SKIP %s: %s" % [source, result["reason"]])
			failed += 1
			continue
		var name: String = source.get_file()
		var path: String = out_dir + "/" + name
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(String(result["code"]))
		file.close()
		var scan := PixelizerShaderBridge.scan_candidate(FileAccess.get_file_as_string(source), source)
		var entry := manifest.get_or_create_entry(source)
		entry.approved = true
		entry.has_vertex = scan["has_vertex"]
		entry.has_fragment = scan["has_fragment"]
		entry.writes_alpha = scan["writes_alpha"]
		entry.source_hash = PixelizerShaderBridge.hash_source_file(source)
		entry.output_path = path
		entry.generated_hash = PixelizerShaderBridge.hash_text(String(result["code"]))
		entry.rules_version = PixelizerBridgeRegistry.INJECTION_RULES_VERSION
		print("WROTE %s" % path)
	var manifest_path := out_dir + "/" + manifest_name
	print("MANIFEST %s (%d) err=%d" % [manifest_path, manifest.entries.size(), ResourceSaver.save(manifest, manifest_path)])
	return failed
