extends RefCounted

## Game handler — godot_game / godot_game_time.
## Docs: 02-Tools/Game-Control.md
##
## godot_game: play, stop, pause, resume, status, instances
## godot_game_time: freeze, unfreeze, step, step_until
##
## Runtime operations (freeze/step/step_until/input) are forwarded to the
## runtime autoload via the debugger channel. When the editor runs multiple
## game instances, params.instance (1-based launch order) selects the target;
## "instances" lists them. Omitted/0 targets the first instance.

const _EC = preload("res://addons/open_godot_mcp/utils/error_codes.gd")

var _bridge: Node


func handle(tool: String, action: String, params: Dictionary) -> Dictionary:
	if tool == "godot_game_time":
		return await _handle_game_time(action, params)
	return await _handle_game(action, params)


func _handle_game(action: String, params: Dictionary) -> Dictionary:
	match action:
		"play":
			return await _play(params)
		"stop":
			return _stop()
		"pause":
			return await _pause(params)
		"resume":
			return await _resume(params)
		"status":
			return await _status(params)
		"instances":
			return _instances()
		_:
			return _EC.fail("INVALID_ARGUMENT", "Unknown action: %s" % action)


func _play(params: Dictionary) -> Dictionary:
	var scene: String = params.get("scene", "")
	var frozen: bool = params.get("frozen", false)
	# Autoload is injected + persisted at plugin._enter_tree; no per-play
	# injection needed here.
	# Determine scene to play
	var play_scene := ""
	if scene.is_empty():
		# Current editor scene
		var ed := EditorInterface.get_edited_scene_root()
		if ed:
			play_scene = ed.scene_file_path
	elif scene == "main":
		play_scene = ProjectSettings.get_setting("application/run/main_scene", "")
	else:
		play_scene = scene
	# If frozen, set time_scale=0 before play via editor settings
	if frozen:
		# We'll set time_scale after the game starts via runtime
		ProjectSettings.set_setting("open_godot_mcp/_frozen_on_start", true)
	else:
		ProjectSettings.set_setting("open_godot_mcp/_frozen_on_start", false)
	# Play the scene
	if scene == "main" or (scene.is_empty() and play_scene == ProjectSettings.get_setting("application/run/main_scene", "")):
		EditorInterface.play_main_scene()
	elif scene == "current" or play_scene.is_empty():
		EditorInterface.play_current_scene()
	else:
		EditorInterface.play_custom_scene(play_scene)
	# Wait a frame for the game to start
	await Engine.get_main_loop().process_frame
	return _EC.ok({"runtime_ready": EditorInterface.is_playing_scene()})


func _stop() -> Dictionary:
	EditorInterface.stop_playing_scene()
	return _EC.ok()


func _pause(params: Dictionary) -> Dictionary:
	return await _call_runtime_game_time("pause", params)


func _resume(params: Dictionary) -> Dictionary:
	return await _call_runtime_game_time("resume", params)


## List every PIE game instance (Debug → Run Multiple Instances) in launch
## order — the 1-based "instance" index accepted by all runtime tools.
func _instances() -> Dictionary:
	if _bridge == null:
		return _EC.fail("INTERNAL_ERROR", "Bridge not set")
	var dbg: EditorDebuggerPlugin = _bridge.get_debugger()
	if dbg == null:
		return _EC.fail("RUNTIME_NOT_CONNECTED", "Debugger plugin not available")
	var list: Array = dbg.get_instances()
	return _EC.ok({"instances": list, "count": list.size(), "is_playing": EditorInterface.is_playing_scene()})


func _status(params: Dictionary) -> Dictionary:
	var is_playing := EditorInterface.is_playing_scene()
	var instance := int(params.get("instance", 0))
	var dbg_ready := false
	if _bridge:
		var dbg: EditorDebuggerPlugin = _bridge.get_debugger()
		if dbg:
			dbg_ready = dbg.is_game_ready(instance)
	var result := {"is_playing": is_playing, "runtime_connected": dbg_ready, "fps": 0}
	if _bridge:
		var dbg: EditorDebuggerPlugin = _bridge.get_debugger()
		if dbg:
			result["instances"] = dbg.get_instances()
			result["instance_count"] = dbg.get_instance_count()
	# FPS and viewport come from the game process — query the runtime
	# autoload via the debugger channel. Fall back to 0 / unknown when
	# the game isn't connected so `status` still works as a liveness probe.
	if dbg_ready and _bridge:
		var dbg: EditorDebuggerPlugin = _bridge.get_debugger()
		var snap: Dictionary = await dbg.call_runtime("profiler", {"action": "snapshot", "instance": instance})
		if snap.get("ok", false):
			result["fps"] = int(snap.get("fps", 0))
			result["process_time_ms"] = float(snap.get("process_time", 0.0))
			result["physics_time_ms"] = float(snap.get("physics_time", 0.0))
			result["memory"] = int(snap.get("memory", 0))
			result["draw_calls"] = int(snap.get("draw_calls", 0))
		# Viewport/window geometry from the game's root viewport via exec.
		# NOTE: eval only produces a value for code with an explicit `return` --
		# a bare expression yields null, which used to drop viewport_size from
		# every status response. Keep the `return` and the flat int payload
		# (Vector2/Vector2i do not survive the bridge as {x, y} reliably).
		var vp: Dictionary = await dbg.call_runtime("exec", {
			"action": "eval",
			"instance": instance,
			"code": (
				"var _vp := get_viewport()\n"
				+ "var _vs := _vp.get_visible_rect().size\n"
				+ "var _ws := DisplayServer.window_get_size()\n"
				+ "var _sc := _vp.get_screen_transform().get_scale()\n"
				+ "return {\"vw\": int(_vs.x), \"vh\": int(_vs.y),"
				+ " \"ww\": int(_ws.x), \"wh\": int(_ws.y),"
				+ " \"sx\": float(_sc.x), \"sy\": float(_sc.y)}"
			),
		})
		if vp.get("ok", false):
			var vp_result: Variant = vp.get("result", null)
			if vp_result is Dictionary and vp_result.has("vw"):
				# viewport_size is the design/stretch space that node rects and
				# godot_runtime_state report in; window_size is the pixel space
				# godot_input mouse coordinates land in. They differ whenever
				# display/window/stretch is active -- input_scale converts.
				result["viewport_size"] = {"width": int(vp_result["vw"]), "height": int(vp_result["vh"])}
				result["window_size"] = {"width": int(vp_result["ww"]), "height": int(vp_result["wh"])}
				result["input_scale"] = {"x": float(vp_result["sx"]), "y": float(vp_result["sy"])}
	return _EC.ok(result)


func _handle_game_time(action: String, params: Dictionary) -> Dictionary:
	match action:
		"freeze":
			return await _call_runtime_game_time("freeze", params)
		"unfreeze":
			return await _call_runtime_game_time("unfreeze", params)
		"step":
			return await _call_runtime_game_time("step", params)
		"step_until":
			return await _call_runtime_game_time("step_until", params)
		"pause":
			return await _call_runtime_game_time("pause", params)
		"resume":
			return await _call_runtime_game_time("resume", params)
		_:
			return _EC.fail("INVALID_ARGUMENT", "Unknown action: %s" % action)


# ---- Runtime communication via debugger channel ----

func _call_runtime_game_time(method: String, params: Dictionary) -> Dictionary:
	if _bridge == null:
		return _EC.fail("INTERNAL_ERROR", "Bridge not set")
	var dbg: EditorDebuggerPlugin = _bridge.get_debugger()
	if dbg == null:
		return _EC.fail("RUNTIME_NOT_CONNECTED", "Debugger plugin not available")
	var call_params := {"action": method}
	call_params.merge(params, true)
	return await dbg.call_runtime("game_time", call_params)


func _get_game_viewport() -> Viewport:
	# Kept for compatibility — returns the editor's root viewport, which
	# is NOT the game viewport. Prefer querying the game via the debugger
	# channel (see _status). The game's viewport is only reachable from
	# inside the game process.
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		return tree.root.get_viewport()
	return null

