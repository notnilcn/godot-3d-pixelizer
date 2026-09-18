class_name PixelizerBridgeEntry
extends Resource

## One bridge candidate: an external spatial shader plus the generated, anchor
## aware asset that carries the injected hooks. Entries live in a
## PixelizerBridgeManifest and are the unit of approval for the bridge.
##
## The source addon is never written to; only `output_path` (a file the bridge
## tool owns) is generated. `source_hash` is the sha256 of the source file
## bytes, so a changed source is detected as Stale and its bridge is not
## applied at runtime until it is regenerated.

## res:// path of the external shader this entry describes.
@export var source_path := ""
## sha256 (hex) of the source file bytes at approval/generation time.
@export var source_hash := ""
## Explicit human approval; only approved entries are applied at runtime.
@export var approved := false
## Explicit exclusion (kept in the manifest so a rescan does not forget it).
@export var excluded := false
## Hook-site facts discovered by the scanner (for the dock preview).
@export var has_vertex := false
@export var has_fragment := false
@export var writes_alpha := false
## res:// path of the generated bridge shader ("" until generated).
@export var output_path := ""
## sha256 (hex) of the generated file bytes.
@export var generated_hash := ""
## INJECTION_RULES_VERSION used to generate `output_path`.
@export var rules_version := 0
