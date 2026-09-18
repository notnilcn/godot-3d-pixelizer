@tool
class_name PixelizerBridgeDock
extends VBoxContainer

## Editor dock for the Pixelizer3D shader bridge. Scans configured addon roots
## for spatial shaders, classifies them, lets a human approve/exclude each one,
## and generates reviewable `.gdshader` assets plus a `.tres` manifest.
##
## Everything here is edit-time only. The scanned addon files are never written;
## generation refuses an output dir that lies inside a scanned root.

const DEFAULT_MANIFEST := "res://pixelizer_bridges/pixelizer_bridge_manifest.tres"

var editor: EditorInterface

var manifest: PixelizerBridgeManifest
var manifest_path := ""
var _candidates := PackedStringArray()

var _manifest_edit: LineEdit
var _output_edit: LineEdit
var _roots_box: VBoxContainer
var _status: Label
var _tree: Tree
var _dir_dialog: FileDialog
var _file_dialog: FileDialog
var _dir_callback: Callable
var _file_callback: Callable
var _preview_window: Window


func setup(editor_interface: EditorInterface) -> void:
	editor = editor_interface
	name = "Pixelizer3D Bridge"
	_build_ui()
	_load_initial_manifest()


# ── UI construction ──────────────────────────────────────────────────────────

func _build_ui() -> void:
	add_theme_constant_override("separation", 4)

	var header := Label.new()
	header.text = "Pixelizer3D Shader Bridge (edit-time; source addons are never modified)"
	add_child(header)

	var manifest_row := HBoxContainer.new()
	manifest_row.add_child(_label("Manifest"))
	_manifest_edit = LineEdit.new()
	_manifest_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	manifest_row.add_child(_manifest_edit)
	manifest_row.add_child(_button("Browse", _browse_manifest))
	manifest_row.add_child(_button("Load", _load_manifest))
	add_child(manifest_row)

	var output_row := HBoxContainer.new()
	output_row.add_child(_label("Output dir"))
	_output_edit = LineEdit.new()
	_output_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output_row.add_child(_output_edit)
	output_row.add_child(_button("Browse", func() -> void:
		_open_dir_dialog(func(path: String) -> void: _output_edit.text = path)))
	add_child(output_row)

	var roots_header := HBoxContainer.new()
	roots_header.add_child(_label("Scanned roots"))
	roots_header.add_child(_button("Add root", func() -> void:
		_open_dir_dialog(func(path: String) -> void: _add_root_row(path))))
	add_child(roots_header)
	_roots_box = VBoxContainer.new()
	add_child(_roots_box)

	var actions := HBoxContainer.new()
	actions.add_child(_button("Scan", _scan))
	actions.add_child(_button("Dry run", func() -> void: _generate(true)))
	actions.add_child(_button("Generate approved", func() -> void: _generate(false)))
	actions.add_child(_button("Clean generated", _clean_generated))
	add_child(actions)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	_tree = Tree.new()
	_tree.columns = 6
	_tree.set_column_title(0, "Source")
	_tree.set_column_title(1, "Vertex")
	_tree.set_column_title(2, "Fragment")
	_tree.set_column_title(3, "Alpha")
	_tree.set_column_title(4, "Status")
	_tree.set_column_title(5, "Approved")
	_tree.set_column_expand(0, true)
	for i in range(1, 6):
		_tree.set_column_expand(i, false)
		_tree.set_column_custom_minimum_width(i, 90)
	_tree.select_mode = Tree.SELECT_ROW
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_edited.connect(_on_item_edited)
	_tree.item_activated.connect(func() -> void: _preview_selected())
	add_child(_tree)

	var row_actions := HBoxContainer.new()
	row_actions.add_child(_button("Approve", func() -> void: _set_selected("approved", true)))
	row_actions.add_child(_button("Unapprove", func() -> void: _set_selected("approved", false)))
	row_actions.add_child(_button("Exclude", func() -> void: _set_selected("excluded", true)))
	row_actions.add_child(_button("Include", func() -> void: _set_selected("excluded", false)))
	row_actions.add_child(_button("Open source", _open_selected_source))
	row_actions.add_child(_button("Preview", _preview_selected))
	add_child(row_actions)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 90
	return label


func _button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(handler)
	return button


func _set_status(text: String) -> void:
	_status.text = text
	_status.tooltip_text = text


# ── Manifest handling ────────────────────────────────────────────────────────

func _load_initial_manifest() -> void:
	_manifest_edit.text = DEFAULT_MANIFEST
	if FileAccess.file_exists(DEFAULT_MANIFEST):
		_load_manifest()


func _browse_manifest() -> void:
	_ensure_file_dialog()
	_file_callback = func(path: String) -> void:
		_manifest_edit.text = path
		_load_manifest()
	_file_dialog.current_file = ""
	_file_dialog.popup_centered(Vector2i(700, 460))


func _load_manifest() -> void:
	var path := _manifest_edit.text.strip_edges()
	if path.is_empty():
		path = DEFAULT_MANIFEST
	if FileAccess.file_exists(path):
		var resource := ResourceLoader.load(path)
		if resource is PixelizerBridgeManifest:
			manifest = resource
			manifest_path = path
			_sync_ui_from_manifest()
			_set_status("Loaded manifest %s (%d entries)." % [path, manifest.entries.size()])
			return
		_set_status("Not a PixelizerBridgeManifest: %s" % path)
		return
	# Offer to create: an empty manifest resource is written on demand.
	manifest = PixelizerBridgeManifest.new()
	manifest_path = path
	_sync_ui_from_manifest()
	_save_manifest()
	_set_status("Created manifest %s." % path)


func _ensure_manifest() -> bool:
	if manifest != null and not manifest_path.is_empty():
		return true
	_load_manifest()
	return manifest != null


func _save_manifest() -> void:
	if manifest == null or manifest_path.is_empty():
		return
	manifest.roots = _collect_roots_from_ui()
	manifest.output_dir = _output_dir_from_ui()
	DirAccess.make_dir_recursive_absolute(manifest_path.get_base_dir())
	var error := ResourceSaver.save(manifest, manifest_path)
	if error != OK:
		_set_status("Failed to save manifest (%d): %s" % [error, manifest_path])


func _sync_ui_from_manifest() -> void:
	_manifest_edit.text = manifest_path
	_output_edit.text = manifest.output_dir
	for child in _roots_box.get_children():
		child.queue_free()
	for root in manifest.roots:
		_add_root_row(root)


func _add_root_row(root_path: String) -> void:
	var row := HBoxContainer.new()
	var edit := LineEdit.new()
	edit.text = root_path
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var browse := _button("…", func() -> void:
		_open_dir_dialog(func(path: String) -> void: edit.text = path))
	var remove := _button("X", func() -> void: row.queue_free())
	row.add_child(edit)
	row.add_child(browse)
	row.add_child(remove)
	_roots_box.add_child(row)


func _collect_roots_from_ui() -> PackedStringArray:
	var roots := PackedStringArray()
	for row in _roots_box.get_children():
		var edit := row.get_child(0) as LineEdit
		if edit != null and not edit.text.strip_edges().is_empty():
			roots.append(edit.text.strip_edges())
	return roots


func _output_dir_from_ui() -> String:
	var dir := _output_edit.text.strip_edges()
	return dir if not dir.is_empty() else PixelizerBridgeManifest.DEFAULT_OUTPUT_DIR


# ── Scan ─────────────────────────────────────────────────────────────────────

func _scan() -> void:
	if not _ensure_manifest():
		return
	manifest.roots = _collect_roots_from_ui()
	manifest.output_dir = _output_dir_from_ui()
	if manifest.is_inside_roots(manifest.output_dir):
		_set_status("Refused: output dir '%s' is inside a scanned root. Pick a folder outside the addons." % manifest.output_dir)
		return
	_set_status("Scanning %d root(s)..." % manifest.roots.size())
	var sources := PackedStringArray()
	for root in manifest.roots:
		_collect_shaders(root, sources)
	# Keep manifest entries visible even when their source left the roots, so an
	# exclusion is never silently forgotten.
	for entry in manifest.entries:
		if entry != null and not entry.source_path.is_empty() and not sources.has(entry.source_path):
			sources.append(entry.source_path)
	sources.sort()
	_candidates = sources
	_populate(sources)
	_save_manifest()
	var candidates := 0
	for source in sources:
		var entry := manifest.find_entry(source)
		if entry != null and entry.has_fragment:
			candidates += 1
	_set_status("Scanned %d shader(s); %d bridgeable candidate(s); output -> %s" % [
		sources.size(), candidates, manifest.output_dir])


func _collect_shaders(path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := path.path_join(name)
		if dir.current_is_dir():
			_collect_shaders(full, out)
		elif name.ends_with(".gdshader"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _populate(sources: PackedStringArray) -> void:
	_tree.clear()
	var root := _tree.create_item()
	for source in sources:
		var code := _read_text(source)
		var scan := PixelizerShaderBridge.scan_candidate(code, source)
		var entry := manifest.get_or_create_entry(source)
		entry.has_vertex = scan["has_vertex"]
		entry.has_fragment = scan["has_fragment"]
		entry.writes_alpha = scan["writes_alpha"]
		var item := _tree.create_item(root)
		item.set_text(0, source)
		item.set_text(1, "yes" if entry.has_vertex else "no")
		item.set_text(2, "yes" if entry.has_fragment else "no")
		item.set_text(3, "ALPHA" if entry.writes_alpha else "1.0")
		item.set_text(4, _status_for(entry, scan))
		item.set_cell_mode(5, TreeItem.CELL_MODE_CHECK)
		item.set_editable(5, true)
		item.set_checked(5, entry.approved)
		item.set_metadata(0, source)


func _status_for(entry: PixelizerBridgeEntry, scan: Dictionary) -> String:
	if not scan["candidate"]:
		return "Not bridgeable"
	if entry.excluded:
		return "Excluded"
	var current_hash := PixelizerShaderBridge.hash_source_file(entry.source_path)
	var output_exists := not entry.output_path.is_empty() and FileAccess.file_exists(entry.output_path)
	if not entry.approved:
		if output_exists:
			return "Stale" if current_hash != entry.source_hash else "Up-to-date"
		return "New"
	if entry.output_path.is_empty() and entry.source_hash.is_empty():
		return "Approved"
	if entry.output_path.is_empty() or not output_exists:
		return "Missing output"
	if current_hash != entry.source_hash:
		return "Stale"
	if entry.rules_version != PixelizerBridgeRegistry.INJECTION_RULES_VERSION:
		return "Stale"
	var generated_hash := PixelizerShaderBridge.hash_source_file(entry.output_path)
	if not entry.generated_hash.is_empty() and generated_hash != entry.generated_hash:
		return "Drift"
	return "Up-to-date"


# ── Generate / clean ─────────────────────────────────────────────────────────

func _generate(dry_run: bool) -> void:
	if not _ensure_manifest():
		return
	if _candidates.is_empty():
		_scan()
	manifest.output_dir = _output_dir_from_ui()
	if manifest.is_inside_roots(manifest.output_dir):
		_set_status("Refused: output dir '%s' is inside a scanned root. Pick a folder outside the addons." % manifest.output_dir)
		return
	var generated := 0
	var skipped := 0
	var refused := 0
	for source in _candidates:
		var entry := manifest.find_entry(source)
		if entry == null or entry.excluded or not entry.approved:
			continue
		var code := _read_text(source)
		if code.is_empty():
			skipped += 1
			continue
		var result := PixelizerShaderBridge.generate(code, source)
		if not result["ok"]:
			skipped += 1
			continue
		var output_path := _output_path_for(source)
		if not dry_run:
			var dir_error := DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
			if dir_error != OK:
				refused += 1
				continue
			var file := FileAccess.open(output_path, FileAccess.WRITE)
			if file == null:
				refused += 1
				continue
			file.store_string(result["code"])
			file.close()
			entry.output_path = output_path
			entry.source_hash = PixelizerShaderBridge.hash_source_file(source)
			entry.generated_hash = PixelizerShaderBridge.hash_text(result["code"])
			entry.rules_version = PixelizerBridgeRegistry.INJECTION_RULES_VERSION
		generated += 1
	if dry_run:
		_set_status("Dry run: %d approved shader(s) would be generated, %d skipped. Nothing written." % [generated, skipped])
		return
	_save_manifest()
	if editor != null:
		editor.get_resource_filesystem().scan()
	_populate(_candidates)
	_set_status("Generated %d bridge shader(s); %d skipped; %d write error(s). Manifest: %s" % [
		generated, skipped, refused, manifest_path])


func _clean_generated() -> void:
	if not _ensure_manifest():
		return
	var removed := 0
	for entry in manifest.entries:
		if entry == null or entry.output_path.is_empty():
			continue
		if FileAccess.file_exists(entry.output_path):
			if DirAccess.remove_absolute(entry.output_path) == OK:
				removed += 1
		entry.output_path = ""
		entry.generated_hash = ""
	_save_manifest()
	if editor != null:
		editor.get_resource_filesystem().scan()
	_populate(_candidates)
	_set_status("Removed %d generated bridge shader(s). Manifest entries kept (approved state preserved)." % removed)


func _output_path_for(source_path: String) -> String:
	var base := manifest.output_dir.trim_suffix("/")
	var relative := source_path
	if relative.begins_with("res://"):
		relative = relative.trim_prefix("res://")
	else:
		relative = relative.replace(":", "").trim_prefix("/")
	return base + "/" + relative


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


# ── Row actions ──────────────────────────────────────────────────────────────

func _selected_source() -> String:
	var item := _tree.get_selected()
	return "" if item == null else String(item.get_metadata(0))


func _set_selected(field: String, value: bool) -> void:
	if not _ensure_manifest():
		return
	var source := _selected_source()
	if source.is_empty():
		return
	var entry := manifest.get_or_create_entry(source)
	match field:
		"approved":
			entry.approved = value
			if value:
				entry.excluded = false
		"excluded":
			entry.excluded = value
			if value:
				entry.approved = false
	_save_manifest()
	var item := _tree.get_selected()
	if item != null:
		item.set_checked(5, entry.approved)
		var code := _read_text(source)
		item.set_text(4, _status_for(entry, PixelizerShaderBridge.scan_candidate(code, source)))


func _on_item_edited() -> void:
	if manifest == null:
		return
	var item := _tree.get_edited()
	if item == null:
		return
	var source := String(item.get_metadata(0))
	if source.is_empty():
		return
	var entry := manifest.get_or_create_entry(source)
	entry.approved = item.is_checked(5)
	if entry.approved:
		entry.excluded = false
	_save_manifest()


func _open_selected_source() -> void:
	var source := _selected_source()
	if source.is_empty() or editor == null:
		return
	var resource := ResourceLoader.load(source)
	if resource != null:
		editor.edit_resource(resource)
	else:
		OS.shell_open(ProjectSettings.globalize_path(source))


func _preview_selected() -> void:
	var source := _selected_source()
	if source.is_empty():
		return
	var code := _read_text(source)
	var result := PixelizerShaderBridge.generate(code, source)
	var diff_text: String
	var generated_text: String
	if result["ok"]:
		diff_text = "// Injected lines:\n//   " + "\n//   ".join(result["injected_lines"]) \
			+ "\n\n// --- source vs generated ---\n" + PixelizerShaderBridge.preview_diff(code, result["code"])
		generated_text = result["code"]
	else:
		diff_text = "// Not bridgeable: " + result["reason"]
		generated_text = code
	_show_preview_window(source, diff_text, generated_text)


# ── Dialogs ──────────────────────────────────────────────────────────────────

func _ensure_dir_dialog() -> void:
	if _dir_dialog != null:
		return
	_dir_dialog = FileDialog.new()
	_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = FileDialog.ACCESS_RESOURCES
	_dir_dialog.dir_selected.connect(func(path: String) -> void:
		if _dir_callback.is_valid():
			_dir_callback.call(path))
	add_child(_dir_dialog)


func _open_dir_dialog(callback: Callable) -> void:
	_dir_callback = callback
	_ensure_dir_dialog()
	_dir_dialog.popup_centered(Vector2i(700, 460))


func _ensure_file_dialog() -> void:
	if _file_dialog != null:
		return
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.add_filter("*.tres", "Resource")
	_file_dialog.file_selected.connect(func(path: String) -> void:
		if _file_callback.is_valid():
			_file_callback.call(path))
	add_child(_file_dialog)


func _show_preview_window(source: String, diff_text: String, generated_text: String) -> void:
	if _preview_window == null:
		_preview_window = Window.new()
		_preview_window.title = "Pixelizer3D Bridge Preview"
		_preview_window.size = Vector2i(960, 720)
		_preview_window.close_requested.connect(func() -> void: _preview_window.hide())
		var split := VSplitContainer.new()
		split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var diff_edit := TextEdit.new()
		diff_edit.name = "Diff"
		diff_edit.editable = false
		diff_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
		var generated_edit := TextEdit.new()
		generated_edit.name = "Generated"
		generated_edit.editable = false
		generated_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
		split.add_child(diff_edit)
		split.add_child(generated_edit)
		_preview_window.add_child(split)
		add_child(_preview_window)
	_preview_window.title = "Preview: " + source
	var split := _preview_window.get_child(0) as VSplitContainer
	(split.get_child(0) as TextEdit).text = diff_text
	(split.get_child(1) as TextEdit).text = generated_text
	_preview_window.popup_centered()
