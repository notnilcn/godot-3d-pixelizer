class_name PixelizerBridgeManifest
extends Resource

## A reviewable, diffable record of which external shaders the bridge is allowed
## to rewrite and where the generated assets live. Saved as a plain `.tres` with
## ResourceSaver and edited from the bridge dock.
##
## The manifest is intentionally NOT a global singleton: every manager names the
## manifests it trusts (`PixelizerManager3D.bridge_manifests`), so a project can
## ship several (e.g. one per addon) and remove one by deleting the resource.

const DEFAULT_OUTPUT_DIR := "res://pixelizer_bridges/"
const FILE_NAME := "pixelizer_bridge_manifest.tres"

## Folder that generated bridge shaders are written into. Refused at scan time
## when it lies inside a scanned root (the bridge never writes into a source
## addon).
@export var output_dir := DEFAULT_OUTPUT_DIR
## Source trees the scanner walks for `shader_type spatial;` shaders.
@export var roots := PackedStringArray()
## One entry per discovered/approved source shader.
@export var entries: Array[PixelizerBridgeEntry] = []


## The entry for `source_path`, or null.
func find_entry(source_path: String) -> PixelizerBridgeEntry:
	for entry in entries:
		if entry != null and entry.source_path == source_path:
			return entry
	return null


## The entry for `source_path`, created (approved = false, excluded = false) when
## absent. Never auto-approves.
func get_or_create_entry(source_path: String) -> PixelizerBridgeEntry:
	var existing := find_entry(source_path)
	if existing != null:
		return existing
	var entry := PixelizerBridgeEntry.new()
	entry.source_path = source_path
	entries.append(entry)
	return entry


## True when `path` (a res:// or absolute path) is inside any configured root.
func is_inside_roots(path: String) -> bool:
	var target := path.replace("\\", "/").trim_suffix("/")
	for root in roots:
		var base := String(root).replace("\\", "/").trim_suffix("/")
		if base.is_empty():
			continue
		if target == base or target.begins_with(base + "/"):
			return true
	return false
