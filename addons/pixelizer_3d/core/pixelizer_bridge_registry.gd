class_name PixelizerBridgeRegistry
extends RefCounted

## Runtime half of the shader bridge: a deterministic `source_path -> generated
## Shader` lookup built from approved, generated manifest entries.
##
## It never generates or rewrites shader source, reads no source files and does
## no hashing. Stale-source detection and generated-output drift reporting are
## editor concerns handled by the bridge dock. Runtime fails safe by only
## mapping entries whose `output_path` exists, so the failure mode is always
## "rendered as authored", never a broken shader.
##
## `apply()` performs at most one operation — assign a pre-generated Shader to a
## ShaderMaterial in place, so the owning system keeps pushing its own uniforms
## to the same material instance.
##
## Owned by PixelizerManager3D; rebuilt when its manifest list changes.

## Bump whenever the editor-time transform changes. Entries generated with an
## older version are not applied at runtime.
const INJECTION_RULES_VERSION := 2

var _map: Dictionary = {}          # source_path -> output_path
var _outputs: Dictionary = {}      # output_path -> true (generated shader set)
var _shaders: Dictionary = {}      # output_path -> Shader (lazy)
var _warnings := PackedStringArray()
var _mapped_count := 0


## Rebuild from a list of PixelizerBridgeManifest resources. Entries that are
## null, excluded, unapproved, version-mismatched or whose output is missing are
## skipped with a warning; they never enter the map.
func build(manifests: Array) -> void:
	_map.clear()
	_outputs.clear()
	_shaders.clear()
	_warnings = PackedStringArray()
	_mapped_count = 0
	for manifest in manifests:
		if manifest == null or not (manifest is PixelizerBridgeManifest):
			continue
		for entry in (manifest as PixelizerBridgeManifest).entries:
			if entry == null or entry.source_path.is_empty():
				continue
			if entry.excluded or not entry.approved:
				continue
			if entry.rules_version != INJECTION_RULES_VERSION:
				_warnings.append("rules version drift (%d != %d): %s" % [
					entry.rules_version, INJECTION_RULES_VERSION, entry.source_path])
				continue
			if entry.output_path.is_empty():
				_warnings.append("approved but not generated: %s" % entry.source_path)
				continue
			if not FileAccess.file_exists(entry.output_path):
				_warnings.append("missing generated output: %s" % entry.output_path)
				continue
			_map[entry.source_path] = entry.output_path
			_outputs[entry.output_path] = true
			_mapped_count += 1


## The bridged Shader for `material`'s current source shader, or null when the
## source is unapproved / missing / version-mismatched / already bridged.
func resolve(material: ShaderMaterial) -> Shader:
	if material == null:
		return null
	var shader := material.shader
	if shader == null:
		return null
	var source_path := shader.resource_path
	if source_path.is_empty() or not _map.has(source_path):
		return null
	var output_path: String = _map[source_path]
	if _shaders.has(output_path):
		return _shaders[output_path] as Shader
	var resource := ResourceLoader.load(output_path)
	if not (resource is Shader):
		_warnings.append("failed to load bridged shader: %s" % output_path)
		return null
	_shaders[output_path] = resource
	return resource as Shader


## Swap `material.shader` to its bridged shader in place. Returns true only when
## a swap actually happened (idempotent: a second call on the same material
## returns false).
func apply(material: ShaderMaterial) -> bool:
	var target := resolve(material)
	if target == null:
		return false
	if material.shader == target:
		return false
	material.shader = target
	return true


func is_generated_shader(shader: Shader) -> bool:
	return shader != null and _outputs.has(shader.resource_path)


func get_mapped_count() -> int:
	return _mapped_count


func get_warnings() -> PackedStringArray:
	return _warnings
