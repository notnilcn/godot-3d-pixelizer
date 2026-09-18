extends SceneTree

## Headless fixtures for the editor-time shader bridge. Run:
##   Godot-stable_mono_win64_console.exe --headless --path . \
##     --script res://tests/bridge/bridge_fixtures.gd
##
## Asserts scan/generate behaviour, determinism/idempotence, include flattening,
## the output-dir-in-root guard, stale detection, manifest round-trip, the
## runtime registry swap, and that no file under a scanned addon root is touched.

const FIXTURES := "res://tests/bridge/fixtures"
const GENERATED := "res://tests/bridge/generated"
const MST_SHADERS := "res://addons/MarchingSquaresTerrain/resources/shaders"
const MST_TERRAIN := "res://addons/MarchingSquaresTerrain/resources/shaders/mst_terrain.gdshader"

var _failures := PackedStringArray()
var _checks := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(GENERATED)
	_clean_generated()
	_test_scan()
	_test_generate()
	_test_include_flattening()
	_test_determinism_and_idempotence()
	_test_alpha_boundary()
	_test_manifest_round_trip()
	_test_registry_gating()
	_test_output_dir_guard()
	_test_external_files_untouched()
	_report()


# ── Tests ────────────────────────────────────────────────────────────────────

func _test_scan() -> void:
	var vf := PixelizerShaderBridge.scan_candidate(_read(FIXTURES + "/vertex_fragment.gdshader"), FIXTURES + "/vertex_fragment.gdshader")
	_check(vf["candidate"], "vertex_fragment is a candidate")
	_check(vf["has_vertex"], "vertex_fragment has vertex")
	_check(vf["has_fragment"], "vertex_fragment has fragment")
	_check(vf["writes_alpha"], "vertex_fragment writes ALPHA")

	var fo := PixelizerShaderBridge.scan_candidate(_read(FIXTURES + "/fragment_only.gdshader"), FIXTURES + "/fragment_only.gdshader")
	_check(fo["candidate"], "fragment_only is a candidate")
	_check(not fo["has_vertex"], "fragment_only has no vertex")
	_check(not fo["writes_alpha"], "fragment_only writes no ALPHA")

	var opt := PixelizerShaderBridge.scan_candidate(_read(FIXTURES + "/opted_in.gdshader"), FIXTURES + "/opted_in.gdshader")
	_check(not opt["candidate"], "opted_in is rejected")
	_check(String(opt["reason"]).contains("already opted"), "opted_in reason mentions already opted")

	var nf := PixelizerShaderBridge.scan_candidate(_read(FIXTURES + "/no_fragment.gdshader"), FIXTURES + "/no_fragment.gdshader")
	_check(not nf["candidate"], "no_fragment is rejected")
	_check(String(nf["reason"]).contains("fragment"), "no_fragment reason mentions fragment")

	var miss := PixelizerShaderBridge.scan_candidate(_read(FIXTURES + "/missing_include.gdshader"), FIXTURES + "/missing_include.gdshader")
	_check(not miss["candidate"], "missing include is rejected")
	_check(String(miss["reason"]).contains("missing include"), "missing include reason")


func _test_generate() -> void:
	var path := FIXTURES + "/vertex_fragment.gdshader"
	var result := PixelizerShaderBridge.generate(_read(path), path)
	_check(result["ok"], "generate vertex_fragment ok")
	var code := String(result["code"])
	_check(code.contains("PIXELIZER_VERTEX(0);"), "generate injects PIXELIZER_VERTEX")
	_check(code.contains("PIXELIZER_META_LIGHT(0);"), "generate injects PIXELIZER_META_LIGHT")
	_check(code.contains("PIXELIZER_CLIP(ALPHA);"), "generate injects PIXELIZER_CLIP(ALPHA)")
	_check(not code.contains("#define PIXELIZER_NO_CLOUD"), "cloud-less source uses the bundled cloud toolkit")
	_check(code.contains("cloud_shadow(v_world_pos)"), "cloud-less source gets the bundled cloud shadow term")
	_check(code.contains("anchor_macros.gdshaderinc"), "generate includes the macros header")
	_check(code.contains("rules_version: 2"), "generate banner carries rules_version")
	_check(not code.contains("#include \"includes/"), "generated code has no relative include left")

	var owner_path := FIXTURES + "/cloud_owner.gdshader"
	var owner := PixelizerShaderBridge.generate(_read(owner_path), owner_path)
	_check(owner["ok"], "generate cloud_owner ok")
	var owner_code := String(owner["code"])
	_check(owner_code.contains("#define PIXELIZER_NO_CLOUD"), "cloud-owning source keeps the NO_CLOUD guard")
	_check(not owner_code.contains("cloud_shadow(v_world_pos)"), "cloud-owning source gets no bundled shadow term")

	var fo := PixelizerShaderBridge.generate(_read(FIXTURES + "/fragment_only.gdshader"), FIXTURES + "/fragment_only.gdshader")
	_check(fo["ok"], "generate fragment_only ok")
	var fo_code := String(fo["code"])
	_check(fo_code.contains("PIXELIZER_CLIP(1.0);"), "opaque fragment clips 1.0")
	_check(fo_code.contains("void vertex() {"), "fragment_only synthesizes vertex()")
	_check(fo_code.contains("PIXELIZER_VERTEX(0);"), "synthesized vertex calls the macro")

	var rejected := PixelizerShaderBridge.generate(_read(FIXTURES + "/no_fragment.gdshader"), FIXTURES + "/no_fragment.gdshader")
	_check(not rejected["ok"], "generate rejects no_fragment")

	var diff := PixelizerShaderBridge.preview_diff("a\nb\n", "a\nB\nb\n")
	_check(diff.contains("+ B"), "preview_diff marks additions")


func _test_include_flattening() -> void:
	var path := FIXTURES + "/nested_include.gdshader"
	var scan := PixelizerShaderBridge.scan_candidate(_read(path), path)
	_check(scan["candidate"], "nested_include is a candidate via flattened fragment")
	_check(scan["has_fragment"], "nested_include fragment found through include")
	var flat := PixelizerShaderBridge.flatten_includes(_read(path), FIXTURES, {}, 0)
	_check(flat["ok"], "nested_include flattens")
	var flattened := String(flat["code"])
	_check(flattened.contains("CLOUD_TINT"), "flattened body includes cloud const")
	_check(_count(flattened, "const vec3 CLOUD_TINT") == 1, "repeat/self include is skipped exactly once")
	_check(not flattened.contains("#include"), "flattening removes all includes")


func _test_determinism_and_idempotence() -> void:
	var path := FIXTURES + "/vertex_fragment.gdshader"
	var code := _read(path)
	var a := String(PixelizerShaderBridge.generate(code, path)["code"])
	var b := String(PixelizerShaderBridge.generate(code, path)["code"])
	_check(a == b, "generate is deterministic (byte-identical re-run)")
	var again := PixelizerShaderBridge.generate(a, GENERATED + "/vertex_fragment.gdshader")
	_check(not again["ok"], "generate refuses already-generated code (idempotence guard)")


func _test_alpha_boundary() -> void:
	var path := FIXTURES + "/alpha_scissor_only.gdshader"
	var scan := PixelizerShaderBridge.scan_candidate(_read(path), path)
	_check(scan["candidate"], "alpha_scissor_only is a candidate")
	_check(not scan["writes_alpha"], "ALPHA_SCISSOR_THRESHOLD does not count as an ALPHA write")
	var gen := PixelizerShaderBridge.generate(_read(path), path)
	_check(String(gen["code"]).contains("PIXELIZER_CLIP(1.0);"), "alpha_scissor_only clips 1.0")


func _test_manifest_round_trip() -> void:
	var manifest := PixelizerBridgeManifest.new()
	manifest.output_dir = GENERATED + "/"
	manifest.roots = PackedStringArray([FIXTURES])
	var entry := manifest.get_or_create_entry(MST_TERRAIN)
	entry.approved = true
	entry.has_fragment = true
	entry.writes_alpha = true
	var path := GENERATED + "/manifest_roundtrip.tres"
	_check(ResourceSaver.save(manifest, path) == OK, "manifest saves")
	var loaded := ResourceLoader.load(path, "PixelizerBridgeManifest", ResourceLoader.CACHE_MODE_IGNORE)
	_check(loaded is PixelizerBridgeManifest, "manifest loads as PixelizerBridgeManifest")
	_check(loaded.entries.size() == 1, "manifest entry count survives")
	_check(loaded.entries[0].source_path == MST_TERRAIN, "entry source path survives")
	_check(loaded.entries[0].approved, "entry approved survives")
	_check(loaded.output_dir == GENERATED + "/", "output_dir survives")
	_check(loaded.roots.size() == 1, "roots survive")


func _test_registry_gating() -> void:
	# Approved + generated: registry maps and swaps in place. Runtime does not
	# hash sources: a bogus source_hash must not matter (editor-only concern).
	var source := MST_TERRAIN
	var generated_path := GENERATED + "/mst_terrain.gdshader"
	var result := PixelizerShaderBridge.generate(_read(source), source)
	_check(result["ok"], "MST terrain generates")
	_write(generated_path, String(result["code"]))
	var manifest := PixelizerBridgeManifest.new()
	manifest.output_dir = GENERATED + "/"
	var entry := manifest.get_or_create_entry(source)
	entry.approved = true
	entry.source_hash = "not-the-real-hash"
	entry.output_path = generated_path
	entry.rules_version = PixelizerBridgeRegistry.INJECTION_RULES_VERSION
	var registry := PixelizerBridgeRegistry.new()
	registry.build([manifest])
	_check(registry.get_mapped_count() == 1, "registry maps one approved entry")
	var material := ShaderMaterial.new()
	material.shader = ResourceLoader.load(source, "Shader", ResourceLoader.CACHE_MODE_IGNORE)
	_check(registry.apply(material), "registry swaps the authored material")
	_check(material.shader.resource_path == generated_path, "swapped to the generated shader")
	_check(not registry.apply(material), "registry apply is idempotent")

	# Unapproved: not mapped, no swap.
	var unapproved := PixelizerBridgeManifest.new()
	unapproved.output_dir = GENERATED + "/"
	var unapproved_entry := unapproved.get_or_create_entry(source)
	unapproved_entry.approved = false
	unapproved_entry.output_path = generated_path
	unapproved_entry.rules_version = PixelizerBridgeRegistry.INJECTION_RULES_VERSION
	var unapproved_registry := PixelizerBridgeRegistry.new()
	unapproved_registry.build([unapproved])
	_check(unapproved_registry.get_mapped_count() == 0, "unapproved entry is not mapped")
	var unapproved_material := ShaderMaterial.new()
	unapproved_material.shader = ResourceLoader.load(source, "Shader", ResourceLoader.CACHE_MODE_IGNORE)
	_check(not unapproved_registry.apply(unapproved_material), "unapproved entry is not applied")

	# Excluded: not mapped.
	var excluded := PixelizerBridgeManifest.new()
	excluded.output_dir = GENERATED + "/"
	var excluded_entry := excluded.get_or_create_entry(source)
	excluded_entry.approved = true
	excluded_entry.excluded = true
	excluded_entry.output_path = generated_path
	excluded_entry.rules_version = PixelizerBridgeRegistry.INJECTION_RULES_VERSION
	var excluded_registry := PixelizerBridgeRegistry.new()
	excluded_registry.build([excluded])
	_check(excluded_registry.get_mapped_count() == 0, "excluded entry is not mapped")

	# Version-mismatched: not mapped, no swap.
	var drifted := PixelizerBridgeManifest.new()
	drifted.output_dir = GENERATED + "/"
	var drifted_entry := drifted.get_or_create_entry(source)
	drifted_entry.approved = true
	drifted_entry.output_path = generated_path
	drifted_entry.rules_version = 0
	var drifted_registry := PixelizerBridgeRegistry.new()
	drifted_registry.build([drifted])
	_check(drifted_registry.get_mapped_count() == 0, "version-mismatched entry is not mapped")
	var drifted_material := ShaderMaterial.new()
	drifted_material.shader = ResourceLoader.load(source, "Shader", ResourceLoader.CACHE_MODE_IGNORE)
	var drifted_authored := drifted_material.shader
	_check(not drifted_registry.apply(drifted_material), "version-mismatched entry is not applied")
	_check(drifted_material.shader == drifted_authored, "version-mismatched material stays authored")

	# Missing output: not mapped.
	var missing := PixelizerBridgeManifest.new()
	missing.output_dir = GENERATED + "/"
	var missing_entry := missing.get_or_create_entry(source)
	missing_entry.approved = true
	missing_entry.output_path = GENERATED + "/does_not_exist.gdshader"
	missing_entry.rules_version = PixelizerBridgeRegistry.INJECTION_RULES_VERSION
	var missing_registry := PixelizerBridgeRegistry.new()
	missing_registry.build([missing])
	_check(missing_registry.get_mapped_count() == 0, "missing output is not mapped")


func _test_output_dir_guard() -> void:
	var manifest := PixelizerBridgeManifest.new()
	manifest.roots = PackedStringArray([MST_SHADERS.replace("/resources/shaders", "")])
	_check(manifest.is_inside_roots(MST_SHADERS + "/out/"), "output inside a root is detected")
	_check(not manifest.is_inside_roots("res://pixelizer_bridges/"), "output outside roots is allowed")
	manifest.roots = PackedStringArray([FIXTURES])
	_check(manifest.is_inside_roots(FIXTURES), "root itself counts as inside")


func _test_external_files_untouched() -> void:
	var before := _hash_tree(MST_SHADERS)
	var result := PixelizerShaderBridge.generate(_read(MST_TERRAIN), MST_TERRAIN)
	_check(result["ok"], "MST terrain is bridgeable")
	_write(GENERATED + "/mst_terrain_check.gdshader", String(result["code"]))
	var after := _hash_tree(MST_SHADERS)
	_check(before == after, "no file under the MST addon root changed during scan/generate")
	_check(String(result["code"]).contains("anchor_macros.gdshaderinc"), "MST shader includes the bundled macros/cloud toolkit")
	_check(not String(result["code"]).contains("#define PIXELIZER_NO_CLOUD"), "MST shader (no vendored clouds) uses the bundled toolkit")
	_check(String(result["code"]).contains("cloud_shadow(v_world_pos)"), "MST shader gets the bundled cloud shadow term")
	var shader := ResourceLoader.load(GENERATED + "/mst_terrain_check.gdshader", "Shader", ResourceLoader.CACHE_MODE_IGNORE)
	_check(shader is Shader, "generated MST shader loads as a Shader resource")


# ── Helpers ──────────────────────────────────────────────────────────────────

func _clean_generated() -> void:
	var dir := DirAccess.open(GENERATED)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir():
			dir.remove(name)
		name = dir.get_next()
	dir.list_dir_end()


func _hash_tree(root: String) -> String:
	var out := {}
	_hash_tree_into(root, out)
	var keys := out.keys()
	keys.sort()
	var parts := PackedStringArray()
	for key in keys:
		parts.append("%s=%s" % [key, out[key]])
	return "\n".join(parts)


func _hash_tree_into(root: String, out: Dictionary) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if not name.begins_with("."):
			var full := root.path_join(name)
			if dir.current_is_dir():
				_hash_tree_into(full, out)
			else:
				out[full] = PixelizerShaderBridge.hash_source_file(full)
		name = dir.get_next()
	dir.list_dir_end()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _count(text: String, needle: String) -> int:
	var count := 0
	var index := text.find(needle)
	while index >= 0:
		count += 1
		index = text.find(needle, index + needle.length())
	return count


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _report() -> void:
	if _failures.is_empty():
		print("BRIDGE FIXTURES: %d checks, ALL PASS" % _checks)
		quit(0)
		return
	for failure in _failures:
		print("FAIL: ", failure)
	print("BRIDGE FIXTURES: %d checks, %d FAILURE(S)" % [_checks, _failures.size()])
	quit(1)
