@tool
extends EditorDebuggerPlugin

## MCP Debugger Plugin — bridges editor ↔ game runtime over the debugger channel.
##
## The game runs as a separate OS process. Even in "Embed" mode the game's
## SceneTree is unreachable from the editor. Godot's debugger protocol
## (EditorDebuggerSession.send_message / EngineDebugger.register_message_capture)
## is the engine's supported IPC and works regardless of embed mode.
##
## Protocol (prefix "ogm"):
##   Editor → Game:  "ogm:call"      [request_id, method, params_json]
##   Game → Editor:  "ogm:response"  [request_id, result_json]
##   Game → Editor:  "ogm:error"     [request_id, message]
##   Game → Editor:  "ogm:hello"     [pid, cmdline_args]  (boot beacon)
##
## Multi-instance (Debug → Run Multiple Instances):
##   Each game process gets its own debugger session. _game_sessions keeps them
##   in launch order; the 1-based position is the public "instance" index that
##   runtime tools accept (params.instance, or call_runtime's instance arg).
##   instance 0 / omitted targets the first game session, which preserves the
##   single-instance behavior for every existing caller.

const CAPTURE_PREFIX := "ogm"
const DEFAULT_TIMEOUT_SEC := 15.0
const GAME_READY_WAIT_SEC := 20.0

var _bridge: Node = null
var _next_request_id: int = 1
# request_id -> {"done": bool, "result": Dictionary, "session_id": int}
# _capture writes directly to the entry; call_runtime polls it.
# Signal/lambda capture was unreliable in this context — the on_response
# callable connected to _response_received never fired when _capture
# emitted from the debugger message handler.
var _pending: Dictionary = {}
# The "editor self-session" concept needs care: the debugger's default tab
# (session 0) is created before any game runs, but the engine REUSES it for
# the first game connection (EditorDebuggerNode hands idle tabs to new peers
# before adding new ones). So a session only counts as a game session once
# its `started` signal fires — never skip session 0 permanently.
var _editor_self_session_id := -1
# Game sessions in launch order; index + 1 is the public instance number.
var _game_sessions: Array[int] = []
var _session_ready: Dictionary = {}  # session_id -> bool
var _session_info: Dictionary = {}  # session_id -> {"pid": int, "args": Array}

# Buffer for debugger inspection messages (stack_dump, stack_frame_vars,
# evaluated). EditorDebuggerSession has NO add_session_message_listener in
# Godot 4.x — _capture on the plugin is the only way to receive these.
var _debug_msg_buffer: Array = []

signal _game_hello()


func _has_capture(prefix: String) -> bool:
	return prefix == CAPTURE_PREFIX or prefix == "console" or prefix == "stack_dump" or prefix == "stack_frame_vars" or prefix == "evaluated"


func _setup_session(session_id: int) -> void:
	# The first _setup_session fires before EditorInterface.is_playing_scene()
	# can ever be true — that's the debugger's default tab. Pin it for
	# reference only: it is later reused by the first game connection, so
	# game-session tracking happens in _on_session_started, not here.
	if _editor_self_session_id == -1 and not EditorInterface.is_playing_scene():
		_editor_self_session_id = session_id
	var session := get_session(session_id)
	if session:
		session.started.connect(_on_session_started.bind(session_id))
		session.stopped.connect(_on_session_stopped.bind(session_id))


func _track_session(session_id: int) -> void:
	if not _game_sessions.has(session_id):
		_game_sessions.append(session_id)
	_session_ready[session_id] = false


func _on_session_started(session_id: int) -> void:
	# A remote peer connected to this tab — it is a game instance now,
	# regardless of which tab it landed on (see _setup_session note).
	_track_session(session_id)
	if _bridge:
		_bridge.send_event("debugger_session_started", {
			"instance": _game_sessions.find(session_id) + 1,
			"count": _game_sessions.size(),
		})


func _on_session_stopped(session_id: int) -> void:
	if not _game_sessions.has(session_id):
		return
	var instance := _game_sessions.find(session_id) + 1
	_game_sessions.erase(session_id)
	_session_ready.erase(session_id)
	_session_info.erase(session_id)
	# Fail only this session's in-flight requests — other instances keep going.
	for rid in _pending.keys():
		var entry: Dictionary = _pending[rid]
		if int(entry.get("session_id", -1)) == session_id:
			entry["done"] = true
			entry["result"] = _fail("RUNTIME_ERROR", "Game instance %d stopped" % instance)
			_pending.erase(rid)
	if _bridge:
		_bridge.send_event("debugger_session_stopped", {
			"instance": instance,
			"count": _game_sessions.size(),
		})


func set_bridge(bridge: Node) -> void:
	_bridge = bridge


func is_game_running() -> bool:
	return EditorInterface.is_playing_scene()


## instance: 0 = any ready game instance, N = that 1-based game instance.
func is_game_ready(instance: int = 0) -> bool:
	if not is_game_running():
		return false
	if instance <= 0:
		return _session_ready.values().has(true)
	if instance > _game_sessions.size():
		return false
	return _session_ready.get(_game_sessions[instance - 1], false)


## Snapshot of every game instance the editor is running, in launch order.
func get_instances() -> Array:
	var out := []
	for i in _game_sessions.size():
		var sid: int = _game_sessions[i]
		var session := get_session(sid)
		var info: Dictionary = _session_info.get(sid, {})
		out.append({
			"instance": i + 1,
			"session_id": sid,
			"active": session != null and session.is_active(),
			"ready": _session_ready.get(sid, false),
			"pid": int(info.get("pid", 0)),
			"args": info.get("args", []),
		})
	return out


func get_instance_count() -> int:
	return _game_sessions.size()


## 1-based instance index for a debugger session id (0 = not a game session).
func instance_index_for(session_id: int) -> int:
	return _game_sessions.find(session_id) + 1


## Resolve the debugger session a runtime call should go to.
## instance 0 = first active game session (launch order); N = that instance.
func _resolve_session(instance: int) -> Dictionary:
	if not is_game_running():
		return {"error": _fail("RUNTIME_NOT_CONNECTED", "Game not running")}
	if instance > 0:
		if instance > _game_sessions.size():
			return {"error": _fail("INSTANCE_NOT_FOUND", "Game instance %d not found (%d instance(s) running)" % [instance, _game_sessions.size()])}
		var sid: int = _game_sessions[instance - 1]
		var s := get_session(sid)
		if s == null or not s.is_active():
			return {"error": _fail("RUNTIME_NOT_CONNECTED", "Game instance %d is not active" % instance)}
		return {"session": s, "session_id": sid}
	for sid in _game_sessions:
		var s := get_session(sid)
		if s != null and s.is_active():
			return {"session": s, "session_id": sid}
	# Fallback: any active session that isn't the editor self-session.
	var s := _first_active_session()
	if s == null:
		return {"error": _fail("RUNTIME_NOT_CONNECTED", "No active debugger session")}
	return {"session": s, "session_id": -1}


func _is_session_ready(session_id: int) -> bool:
	if session_id < 0:
		return _session_ready.values().has(true)
	return _session_ready.get(session_id, false)


## Async: call a method on the game-side runtime autoload via debugger channel.
## Returns the result Dictionary, or a fail dict on timeout/error.
## instance: 0 = default (params["instance"] if present, else first game
## session); N = that 1-based game instance. The "instance" key is consumed
## here and never reaches the game.
func call_runtime(method: String, params: Dictionary = {}, timeout_sec: float = DEFAULT_TIMEOUT_SEC, instance: int = 0) -> Dictionary:
	if instance == 0:
		instance = int(params.get("instance", 0))
	params = params.duplicate()
	params.erase("instance")
	var resolved := _resolve_session(instance)
	if resolved.has("error"):
		return resolved["error"]
	var session: EditorDebuggerSession = resolved["session"]
	var sid: int = resolved["session_id"]
	# Wait for the target instance's hello beacon if not ready yet
	if not _is_session_ready(sid):
		var waited := 0.0
		while not _is_session_ready(sid) and is_game_running() and waited < GAME_READY_WAIT_SEC:
			await Engine.get_main_loop().process_frame
			waited += 0.016
		if not _is_session_ready(sid):
			if instance > 0:
				return _fail("RUNTIME_NOT_CONNECTED", "Game instance %d runtime did not become ready (no ogm:hello beacon)" % instance)
			return _fail("RUNTIME_NOT_CONNECTED", "Game runtime did not become ready (no ogm:hello beacon)")

	var request_id := _next_request_id
	_next_request_id += 1

	# Store pending result in a dictionary that _capture can write to directly.
	# This avoids signal/lambda capture issues — the on_response lambda
	# connected to _response_received never fired when _capture emitted
	# from the debugger message handler. Polling a shared dict works reliably.
	var pending_entry := {"done": false, "result": {}, "session_id": sid}
	_pending[request_id] = pending_entry

	session.send_message("ogm:call", [request_id, method, JSON.stringify(params)])

	# Wait with timeout — poll the pending entry.
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while not pending_entry["done"] and Time.get_ticks_msec() < deadline:
		if not is_game_running():
			_pending.erase(request_id)
			return _fail("RUNTIME_NOT_CONNECTED", "Game stopped during call")
		await Engine.get_main_loop().process_frame

	if not pending_entry["done"]:
		_pending.erase(request_id)
		return _fail("TIMEOUT", "Runtime call '%s' timed out after %.1fs" % [method, timeout_sec])

	_pending.erase(request_id)
	return pending_entry["result"]


func _capture(message: String, data: Array, session_id: int) -> bool:
	match message:
		"ogm:hello":
			_track_session(session_id)
			_session_ready[session_id] = true
			var info := {"pid": 0, "args": []}
			if data.size() >= 1:
				info["pid"] = int(data[0])
			# OS.get_cmdline_args() arrives as PackedStringArray, not Array.
			if data.size() >= 2 and (data[1] is Array or data[1] is PackedStringArray):
				info["args"] = Array(data[1])
			_session_info[session_id] = info
			_game_hello.emit()
			return true
		"ogm:response":
			if data.size() < 2:
				return true
			var rid: int = int(data[0])
			var result_json: String = str(data[1])
			var parsed = JSON.parse_string(result_json)
			var result_dict: Dictionary = parsed if parsed is Dictionary else {"raw": result_json}
			if _pending.has(rid):
				var entry: Dictionary = _pending[rid]
				entry["done"] = true
				entry["result"] = result_dict
			return true
		"ogm:error":
			if data.size() < 2:
				return true
			var rid: int = int(data[0])
			var msg: String = str(data[1])
			if _pending.has(rid):
				var entry: Dictionary = _pending[rid]
				entry["done"] = true
				entry["result"] = _fail("RUNTIME_ERROR", msg)
			return true
		"ogm:log":
			if data.size() >= 2:
				var lvl: String = str(data[0])
				var log_msg: String = str(data[1])
				if _bridge:
					_bridge.add_log(lvl, "game", log_msg, instance_index_for(session_id))
			return true
		"console:output":
			if data.size() > 0:
				if _bridge:
					_bridge.add_log("info", "game", str(data[0]), instance_index_for(session_id))
				else:
					printerr("[MCP] console:output but _bridge is null")
			return true
		"console:error":
			if data.size() > 0:
				if _bridge:
					_bridge.add_log("error", "game", str(data[0]), instance_index_for(session_id))
				else:
					printerr("[MCP] console:error but _bridge is null")
			return true
		"console:warning":
			if data.size() > 0:
				if _bridge:
					_bridge.add_log("warning", "game", str(data[0]), instance_index_for(session_id))
				else:
					printerr("[MCP] console:warning but _bridge is null")
			return true
		"stack_dump":
			_debug_msg_buffer.append({"message": "stack_dump", "data": data})
			return true
		"stack_frame_vars":
			_debug_msg_buffer.append({"message": "stack_frame_vars", "data": data})
			return true
		"evaluated":
			_debug_msg_buffer.append({"message": "evaluated", "data": data})
			return true
	return false


func wait_debug_message(prefix: String, timeout_ms: int = 3000) -> Dictionary:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < timeout_ms:
		for i in _debug_msg_buffer.size():
			var entry: Dictionary = _debug_msg_buffer[i]
			if str(entry["message"]).begins_with(prefix):
				_debug_msg_buffer.remove_at(i)
				return entry
		await Engine.get_main_loop().process_frame
	return {}


func clear_debug_messages() -> void:
	_debug_msg_buffer.clear()


func _first_active_session() -> EditorDebuggerSession:
	var sessions := get_sessions()
	# Prefer the first tracked game session; fall back to any active session
	# that isn't the editor self-session.
	for sid in _game_sessions:
		var s := get_session(sid)
		if s is EditorDebuggerSession and s.is_active():
			return s
	for s in sessions:
		if s is EditorDebuggerSession and s.is_active():
			# Skip the editor self-session — it has no game-side capture.
			# We can't compare by id here because get_sessions doesn't
			# expose ids; rely on _game_sessions having been populated by
			# _setup_session for the real game sessions.
			return s
	return null


func _fail(code: String, message: String) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message}}
