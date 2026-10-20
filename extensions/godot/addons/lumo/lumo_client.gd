@tool
extends RefCounted
## Talks to Lumo over its local WebSocket (127.0.0.1). The port and the token are in
## editor-bridge.json, which Lumo writes at launch in its own folder:
##   macOS    ~/Library/Application Support/NotchBuddy/editor-bridge.json
##   Windows  %LOCALAPPDATA%\Coucou\editor-bridge.json
##   Linux    ~/.local/share/coucou/editor-bridge.json  ($XDG_DATA_HOME/coucou)
## Nothing leaves the computer. If Lumo isn't running, messages are dropped quietly.

## Lumo answered a message (ok, or the reason it didn't take it).
signal answered(event: String, ok: bool, error: String)

const IDLE_CLOSE_MS := 30_000
const CONNECT_TIMEOUT_MS := 3_000
const MAX_QUEUE := 4

var _ws := WebSocketPeer.new()
var _token := ""
var _connecting_since := 0
var _last_activity := 0
var _queue: Array[Dictionary] = []
var _in_flight: Array[Dictionary] = []  # sent, waiting for Lumo's answer (without the token)
var _retried_token := false


## Where Lumo writes its port and token on this system.
static func info_path() -> String:
	match OS.get_name():
		"macOS":
			return OS.get_environment("HOME").path_join("Library/Application Support/NotchBuddy/editor-bridge.json")
		"Windows":
			return OS.get_environment("LOCALAPPDATA").path_join("Coucou/editor-bridge.json")
		_:
			var data := OS.get_environment("XDG_DATA_HOME")
			if data.is_empty() or not data.is_absolute_path():
				data = OS.get_environment("HOME").path_join(".local/share")
			return data.path_join("coucou/editor-bridge.json")


## True when Lumo looks like it's running (its info file is there).
static func lumo_available() -> bool:
	return FileAccess.file_exists(info_path())


## Queues one event for Lumo. Returns false when Lumo isn't running.
func send(event: String, payload: Dictionary) -> bool:
	if not _ensure_connected():
		return false
	var message := payload.duplicate()
	message["hook_event_name"] = event
	# Only the newest context matters: drop older queued ones of the same kind.
	if event == "EditorContext":
		_queue = _queue.filter(func(m: Dictionary) -> bool: return m.get("hook_event_name") != "EditorContext")
	_queue.append(message)
	while _queue.size() > MAX_QUEUE:
		_queue.pop_front()
	_last_activity = Time.get_ticks_msec()
	return true


## Call often (every frame while `is_busy()`).
func poll() -> void:
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		# A retry after Lumo restarted (new token): connect again with the new one.
		if not _queue.is_empty() and not _ensure_connected():
			_fail_queue("Lumo isn't running.")
		return
	_ws.poll()
	state = _ws.get_ready_state()
	var now := Time.get_ticks_msec()
	match state:
		WebSocketPeer.STATE_CONNECTING:
			if now - _connecting_since > CONNECT_TIMEOUT_MS:
				_ws.close()
				_fail_queue("Lumo didn't answer. Is it open?")
		WebSocketPeer.STATE_OPEN:
			while _ws.get_available_packet_count() > 0:
				_on_answer(_ws.get_packet().get_string_from_utf8())
			while not _queue.is_empty():
				var message: Dictionary = _queue.pop_front()
				var wire := message.duplicate()
				wire["token"] = _token
				_ws.send_text(JSON.stringify(wire))
				_in_flight.append(message)
				_last_activity = now
			if _in_flight.is_empty() and now - _last_activity > IDLE_CLOSE_MS:
				_ws.close(1000, "idle")
		WebSocketPeer.STATE_CLOSED:
			if not _in_flight.is_empty():
				_fail_queue("Lumo closed the connection.")


## Something is queued, in flight or connected: keep polling.
func is_busy() -> bool:
	return _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED


func close() -> void:
	_ws.close()


func _ensure_connected() -> bool:
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CONNECTING:
		return true
	var info := _read_info()
	if info.is_empty():
		return false
	_token = str(info.get("token", ""))
	var port := int(info.get("port", 0))
	if _token.is_empty() or port <= 0:
		return false
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 16
	_ws.outbound_buffer_size = 1 << 21  # selection + scene details, never the image (sent as a path)
	if _ws.connect_to_url("ws://127.0.0.1:%d" % port) != OK:
		return false
	_connecting_since = Time.get_ticks_msec()
	_last_activity = _connecting_since
	_in_flight.clear()
	return true


func _read_info() -> Dictionary:
	var path := info_path()
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _on_answer(text: String) -> void:
	var sent: Dictionary = {} if _in_flight.is_empty() else _in_flight.pop_front()
	var event := str(sent.get("hook_event_name", ""))
	var parsed: Variant = JSON.parse_string(text)
	var answer: Dictionary = parsed if parsed is Dictionary else {}
	var ok := bool(answer.get("ok", false))
	var error := str(answer.get("error", ""))
	# Lumo restarted (new token): read it again and retry once.
	if not ok and error.begins_with("bad token") and not _retried_token and not sent.is_empty():
		_retried_token = true
		_queue.push_front(sent)
		_queue.append_array(_in_flight)
		_in_flight.clear()
		_ws.close()
		return
	if ok:
		_retried_token = false
	answered.emit(event, ok, error)


func _fail_queue(reason: String) -> void:
	var events: Array[String] = []
	for m in _in_flight + _queue:
		events.append(str(m.get("hook_event_name", "")))
	_queue.clear()
	_in_flight.clear()
	for e in events:
		answered.emit(e, false, reason)
