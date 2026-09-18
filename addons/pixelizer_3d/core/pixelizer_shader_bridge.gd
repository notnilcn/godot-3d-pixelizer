class_name PixelizerShaderBridge
extends RefCounted

## Editor-only, deterministic text transform that turns a third-party spatial
## shader into a standalone, anchor-aware `.gdshader` asset.
##
## This file contains NO runtime material mutation and no RenderingServer use:
## it is a pure function of (source text, source path, files on disk). The
## generated asset is written by the bridge dock and is reviewable in git; the
## game only ever loads the pre-generated Shader and swaps it into a material
## (see PixelizerBridgeRegistry).
##
## Why source rewriting is unavoidable: Godot stage built-ins (MODEL_MATRIX,
## ALBEDO, ...) are illegal inside helper functions, so the anchor payload hooks
## must expand textually *inside* the real vertex()/fragment() bodies. Godot
## cannot merge a third-party shader with the macros header without rewriting
## the text, and the third-party file must never be edited.
##
## Injection contract (same semantics as anchor_macros.gdshaderinc):
##   vertex():    PIXELIZER_VERTEX(0) as the first statement (synthesized when
##                the source has no vertex()).
##   fragment():  `ALBEDO *= 1.0 - cloud_shadow(v_world_pos);` (only when the
##                source does not own a cloud toolkit), then
##                `if (PIXELIZER_META_ACTIVE(0)) { PIXELIZER_META_LIGHT(0); }`
##                followed by `PIXELIZER_CLIP(<alpha>)` as the last statements,
##                so the payload overrides the source albedo and the clip reads
##                the source's final alpha.
##   global:      `#define PIXELIZER_NO_CLOUD` around the macros include when the
##                source owns its own cloud functions (e.g. a vendored
##                cloud_fbm.gdshaderinc), so the bundle's cloud toolkit does not
##                collide. For every other source the bundled
##                cloud_fbm.gdshaderinc is included and the injected shadow term
##                reads the same cloud_* uniforms the manager pushes to
##                registered cloud/pixelized materials.
##
## Bump INJECTION_RULES_VERSION whenever the transform changes; entries generated
## with an older version are not applied at runtime. The constant lives on the
## runtime registry (`PixelizerBridgeRegistry`), which is the component that
## gates on it.

const INJECTION_RULES_VERSION := PixelizerBridgeRegistry.INJECTION_RULES_VERSION

## The macros header and the vocabulary the bridge injects. The header exposes
## both ANCHOR_* (native) and PIXELIZER_* (bridge alias) entry points.
const MACROS_INCLUDE := "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"
const MACROS_FILE := "anchor_macros.gdshaderinc"
const MACROS_ALIAS_FILE := "pixelizer_macros.gdshaderinc"
const INCLUDE_DEPTH_CAP := 16

const _INCLUDE_RE := "#[ \\t]*include\\s+\"([^\"]+)\""
const _FUNC_RE_TEMPLATE := "(?m)^[ \\t]*void[ \\t]+%s[ \\t]*\\("
const _FIRST_FUNC_RE := "(?m)^[ \\t]*void[ \\t]+[A-Za-z_][A-Za-z0-9_]*[ \\t]*\\("
const _ALPHA_RE := "\\bALPHA\\b"
## A source owns its cloud toolkit when any of the shared cloud_* entry points
## is declared/used in the flattened text; those sources keep their uniforms and
## the bundled cloud_fbm.gdshaderinc is not included.
const _CLOUD_OWNER_RE := "\\bclouds_enabled\\b|\\bcloud_shadow\\b|\\bcloud_coverage_from_noise\\b"


## Classifies a shader (top-level text, or a thin wrapper that includes its real
## body). Returns:
##   {candidate: bool, has_vertex: bool, has_fragment: bool, writes_alpha: bool,
##    reason: String}
## `path` is the res:// source path; it anchors relative `#include` resolution.
static func scan_candidate(code: String, path: String) -> Dictionary:
	var result := {
		"candidate": false,
		"has_vertex": false,
		"has_fragment": false,
		"writes_alpha": false,
		"reason": "",
	}
	if code.strip_edges().is_empty():
		result["reason"] = "empty source"
		return result
	if is_opted_in(code):
		result["reason"] = "already opted in (macros include / PIXELIZER_VERTEX / ANCHOR_VERTEX)"
		return result
	var flatten := flatten_includes(code, _base_dir(path), {}, 0)
	if not flatten["ok"]:
		result["reason"] = flatten["reason"]
		return result
	var flattened: String = flatten["code"]
	if is_opted_in(flattened):
		result["reason"] = "already opted in (macros include in flattened source)"
		return result
	var vertex_span := find_function_span(flattened, "vertex")
	var fragment_span := find_function_span(flattened, "fragment")
	result["has_vertex"] = not vertex_span.is_empty()
	result["has_fragment"] = not fragment_span.is_empty()
	if not result["has_fragment"]:
		result["reason"] = "no fragment() (not bridgeable)"
		return result
	var body := flattened.substr(fragment_span[0], fragment_span[1] - fragment_span[0])
	result["writes_alpha"] = _regex_has(body, _ALPHA_RE)
	result["candidate"] = true
	return result


## Builds the injected source. Returns:
##   {ok: bool, code: String, injected_lines: PackedStringArray, reason: String}
## Deterministic: the same inputs always produce byte-identical output. Never
## touches `source_path` on disk.
static func generate(source_code: String, source_path: String) -> Dictionary:
	var result := {
		"ok": false,
		"code": "",
		"injected_lines": PackedStringArray(),
		"reason": "",
	}
	if source_code.strip_edges().is_empty():
		result["reason"] = "empty source"
		return result
	if is_opted_in(source_code):
		result["reason"] = "already opted in; nothing to generate"
		return result
	var flatten := flatten_includes(source_code, _base_dir(source_path), {}, 0)
	if not flatten["ok"]:
		result["reason"] = flatten["reason"]
		return result
	var resolvable: String = flatten["code"]
	if is_opted_in(resolvable):
		result["reason"] = "already opted in (flattened source)"
		return result

	var vertex_span := find_function_span(resolvable, "vertex")
	var fragment_span := find_function_span(resolvable, "fragment")
	if fragment_span.is_empty():
		result["reason"] = "no fragment() (not bridgeable)"
		return result
	var first_func := _find_first_function(resolvable)
	if first_func < 0:
		result["reason"] = "no function definition found after flattening includes"
		return result

	var body := resolvable.substr(fragment_span[0], fragment_span[1] - fragment_span[0])
	var alpha_expr := "ALPHA" if _regex_has(body, _ALPHA_RE) else "1.0"
	var owns_clouds := _regex_has(resolvable, _CLOUD_OWNER_RE)

	# Sources without a cloud toolkit get the bundled one through the macros
	# include plus the matching shadow term; sources that own one skip the
	# bundled include so the cloud_* declarations do not collide.
	var cloud_hook := ""
	var header := ""
	if owns_clouds:
		header = "#define PIXELIZER_NO_CLOUD\n#include \"%s\"\n#undef PIXELIZER_NO_CLOUD\n\n" % MACROS_INCLUDE
	else:
		header = "#include \"%s\"\n\n" % MACROS_INCLUDE
		cloud_hook = "\tALBEDO *= 1.0 - cloud_shadow(v_world_pos);\n"

	var fragment_hook := "\n%s\tif (PIXELIZER_META_ACTIVE(0)) {\n\t\tPIXELIZER_META_LIGHT(0);\n\t}\n\tPIXELIZER_CLIP(%s);\n" % [cloud_hook, alpha_expr]
	var vertex_hook := "\n\tPIXELIZER_VERTEX(0);\n"

	var injected := PackedStringArray()
	injected.append("fragment(): PIXELIZER_META_ACTIVE/PIXELIZER_META_LIGHT + PIXELIZER_CLIP(%s)" % alpha_expr)
	if owns_clouds:
		injected.append("global: #define PIXELIZER_NO_CLOUD (source owns its cloud toolkit)")
	else:
		injected.append("fragment(): ALBEDO *= 1.0 - cloud_shadow(v_world_pos) (bundled cloud_fbm)")
	if not vertex_span.is_empty():
		injected.append("vertex(): PIXELIZER_VERTEX(0)")
	else:
		injected.append("vertex(): synthesized PIXELIZER_VERTEX(0)")
	injected.append("#include %s" % MACROS_INCLUDE)

	# Apply body edits from the end of the file backwards so earlier indices stay
	# valid; the header goes in last, before the first function definition.
	var edits: Array = []
	edits.append({"pos": fragment_span[1], "text": fragment_hook})
	if not vertex_span.is_empty():
		edits.append({"pos": int(vertex_span[0]) + 1, "text": vertex_hook})
	edits.sort_custom(func(a, b): return a["pos"] > b["pos"])
	var out := resolvable
	for edit in edits:
		out = out.insert(edit["pos"], edit["text"])

	if vertex_span.is_empty():
		out += "\nvoid vertex() {\n\tPIXELIZER_VERTEX(0);\n}\n"
	out = out.insert(first_func, header)

	var source_hash := hash_source_file(source_path) if not source_path.is_empty() else hash_text(source_code)
	var banner := _banner(source_path, source_hash)
	out = banner + out

	result["ok"] = true
	result["code"] = out
	result["injected_lines"] = injected
	result["reason"] = ""
	return result


## A simple LCS line diff for the dock preview. Additions are prefixed `+`,
## removals `-`, context lines are unchanged. Deterministic and allocation-safe
## (falls back to a plain concatenation for very large inputs).
static func preview_diff(source_code: String, generated_code: String) -> String:
	var a := source_code.split("\n")
	var b := generated_code.split("\n")
	var n := a.size()
	var m := b.size()
	if n * m > 4_000_000:
		return "// diff too large: %d x %d lines\n" % [n, m] + generated_code
	var dp := PackedInt32Array()
	dp.resize((n + 1) * (m + 1))
	var stride := m + 1
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if a[i] == b[j]:
				dp[i * stride + j] = dp[(i + 1) * stride + (j + 1)] + 1
			else:
				dp[i * stride + j] = maxi(dp[(i + 1) * stride + j], dp[i * stride + (j + 1)])
	var lines := PackedStringArray()
	var i := 0
	var j := 0
	while i < n and j < m:
		if a[i] == b[j]:
			lines.append("  " + a[i])
			i += 1
			j += 1
		elif dp[(i + 1) * stride + j] >= dp[i * stride + (j + 1)]:
			lines.append("- " + a[i])
			i += 1
		else:
			lines.append("+ " + b[j])
			j += 1
	while i < n:
		lines.append("- " + a[i])
		i += 1
	while j < m:
		lines.append("+ " + b[j])
		j += 1
	return "\n".join(lines)


## True when the source already carries the pixelizer hooks (so it is a source,
## not a bridge target).
static func is_opted_in(code: String) -> bool:
	return code.contains("PIXELIZER_VERTEX") \
		or code.contains("ANCHOR_VERTEX") \
		or code.contains(MACROS_FILE) \
		or code.contains(MACROS_ALIAS_FILE)


## sha256 (hex) of the raw bytes of `path`, or of `fallback`'s UTF-8 bytes when
## the file cannot be read.
static func hash_source_file(path: String, fallback := "") -> String:
	if not path.is_empty() and FileAccess.file_exists(path):
		return hash_bytes(FileAccess.get_file_as_bytes(path))
	return hash_text(fallback)


static func hash_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func hash_text(text: String) -> String:
	return hash_bytes(text.to_utf8_buffer())


## Recursively inlines `#include "..."` so the generated file compiles with no
## path context. Resolves relative includes against the including file's dir,
## skips repeats like an include guard (visited set), and fails on a missing or
## unreadable include. Returns {ok, code, reason}.
static func flatten_includes(code: String, base_dir: String, visited: Dictionary, depth: int) -> Dictionary:
	if depth > INCLUDE_DEPTH_CAP:
		return {"ok": false, "code": "", "reason": "include depth cap (%d) exceeded" % INCLUDE_DEPTH_CAP}
	if not code.contains("#include"):
		return {"ok": true, "code": code, "reason": ""}
	var regex := RegEx.new()
	regex.compile(_INCLUDE_RE)
	var output := ""
	var last := 0
	for match in regex.search_all(code):
		output += code.substr(last, match.get_start() - last)
		var include_path := match.get_string(1)
		var resolved := include_path
		if not (include_path.begins_with("res://") or include_path.begins_with("user://") or include_path.is_absolute_path()):
			resolved = base_dir.path_join(include_path) if not base_dir.is_empty() else include_path
		resolved = resolved.simplify_path()
		if visited.has(resolved):
			last = match.get_end()
			continue
		visited[resolved] = true
		if not FileAccess.file_exists(resolved):
			return {"ok": false, "code": "", "reason": "missing include: %s" % resolved}
		var error := FileAccess.get_open_error()
		var included := FileAccess.get_file_as_string(resolved)
		if included.is_empty() and error != OK:
			return {"ok": false, "code": "", "reason": "cannot read include: %s (err %d)" % [resolved, error]}
		var sub := flatten_includes(included, resolved.get_base_dir(), visited, depth + 1)
		if not sub["ok"]:
			return sub
		output += sub["code"]
		last = match.get_end()
	output += code.substr(last)
	return {"ok": true, "code": output, "reason": ""}


## Returns [open_brace_index, close_brace_index] for `void <name>(...) { ... }`,
## ignoring braces inside comments and strings. Empty when not found.
static func find_function_span(code: String, name: String) -> Array:
	var regex := RegEx.new()
	regex.compile(_FUNC_RE_TEMPLATE % name)
	var match := regex.search(code)
	if match == null:
		return []
	var open := code.find("{", match.get_end())
	if open < 0:
		return []
	var depth := 0
	var index := open
	var length := code.length()
	var in_line_comment := false
	var in_block_comment := false
	while index < length:
		var ch := code[index]
		var next := code[index + 1] if index + 1 < length else ""
		if in_line_comment:
			if ch == "\n":
				in_line_comment = false
		elif in_block_comment:
			if ch == "*" and next == "/":
				in_block_comment = false
				index += 1
		elif ch == "/" and next == "/":
			in_line_comment = true
			index += 1
		elif ch == "/" and next == "*":
			in_block_comment = true
			index += 1
		elif ch == "\"":
			index += 1
			while index < length and code[index] != "\"":
				if code[index] == "\\":
					index += 1
				index += 1
		elif ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return [open, index]
		index += 1
	return []


static func _find_first_function(code: String) -> int:
	var regex := RegEx.new()
	regex.compile(_FIRST_FUNC_RE)
	var match := regex.search(code)
	return match.get_start() if match != null else -1


static func _regex_has(text: String, pattern: String) -> bool:
	var regex := RegEx.new()
	regex.compile(pattern)
	return regex.search(text) != null


static func _base_dir(path: String) -> String:
	return path.get_base_dir() if not path.is_empty() else ""


static func _banner(source_path: String, source_hash: String) -> String:
	return "// ==========================================================================\n" \
		+ "// GENERATED by Pixelizer3D shader bridge - DO NOT EDIT.\n" \
		+ "// Source (never modified): %s\n" % source_path \
		+ "// Source SHA256: %s\n" % source_hash \
		+ "// rules_version: %d\n" % INJECTION_RULES_VERSION \
		+ "// Regenerate from the Pixelizer3D bridge dock (Project > Tools).\n" \
		+ "// This file is derived; delete it and its manifest entry to revise the bridge.\n" \
		+ "// ==========================================================================\n\n"
