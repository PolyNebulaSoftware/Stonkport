extends Node
## Minimal static HTTP/1.1 file server over [TCPServer].
##
## Just enough HTTP for Godot WASM builds, which require correct MIME types
## (application/wasm etc.) and therefore cannot be opened via file://.
## Single-threaded: connections are polled in _process() and each client is
## served exactly one GET/HEAD response before the socket is closed.

const MAX_REQUEST_BYTES := 8192
const CLIENT_TIMEOUT_MSEC := 10_000
const PORT_ATTEMPTS := 10

const MIME_TYPES := {
	"html": "text/html",
	"htm": "text/html",
	"js": "text/javascript",
	"mjs": "text/javascript",
	"wasm": "application/wasm",
	"pck": "application/octet-stream",
	"json": "application/json",
	"png": "image/png",
	"svg": "image/svg+xml",
	"ico": "image/x-icon",
	"css": "text/css",
}

const STATUS_TEXT := {
	200: "OK",
	400: "Bad Request",
	403: "Forbidden",
	404: "Not Found",
	405: "Method Not Allowed",
	431: "Request Header Fields Too Large",
}

## Identity endpoint so the launcher can verify that whatever occupies its
## base port is really another instance of this app (and not some unrelated
## program) before sending the browser there.
const LAUNCHER_PING_PATH := "__launcher_ping"
const LAUNCHER_PING_BODY := "StonkportLauncher"

var _server := TCPServer.new()
var _clients := {}  # StreamPeerTCP -> {"buffer": String, "since": int}
var _root := ""
var _port := -1


## Binds 127.0.0.1 on the first free port starting at port_hint.
## Returns the bound port, or -1 if none could be acquired.
func start(port_hint: int, root_dir: String) -> int:
	_root = root_dir
	for attempt in PORT_ATTEMPTS:
		var port := port_hint + attempt
		if _server.listen(port, "127.0.0.1") == OK:
			_port = port
			return port
	push_error("LocalWebServer: ports %d-%d all busy." % [port_hint, port_hint + PORT_ATTEMPTS - 1])
	return -1


func stop() -> void:
	for peer in _clients.keys():
		peer.disconnect_from_host()
	_clients.clear()
	if _server.is_listening():
		_server.stop()
	_port = -1


func get_port() -> int:
	return _port


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		peer.set_no_delay(true)
		_clients[peer] = {"buffer": "", "since": Time.get_ticks_msec()}
	var now := Time.get_ticks_msec()
	for peer in _clients.keys():
		var since: int = _clients[peer]["since"]
		if now - since > CLIENT_TIMEOUT_MSEC:
			_drop(peer)
			continue
		_poll_client(peer)


## Dead sockets are reaped by CLIENT_TIMEOUT_MSEC instead of status checks,
## so this stays independent of StreamPeerTCP status enum availability.
func _poll_client(peer: StreamPeerTCP) -> void:
	peer.poll()
	var state: Dictionary = _clients[peer]
	var buffer := String(state["buffer"])
	var available := peer.get_available_bytes()
	if available > 0:
		var chunk: PackedByteArray = peer.get_partial_data(available)[1]
		buffer += chunk.get_string_from_ascii()
		state["buffer"] = buffer
		if buffer.length() > MAX_REQUEST_BYTES:
			_respond_error(peer, 431)
			_drop(peer)
			return
	var end := buffer.find("\r\n\r\n")
	if end == -1:
		return  # headers not complete yet
	_handle_request(peer, buffer.substr(0, end))
	_drop(peer)


func _handle_request(peer: StreamPeerTCP, raw: String) -> void:
	var parts := raw.get_slice("\r\n", 0).split(" ", false)
	var method: String = parts[0] if parts.size() > 0 else ""
	var target: String = parts[1] if parts.size() > 1 else "/"
	if method != "GET" and method != "HEAD":
		_respond_error(peer, 405)
		return
	var path := target.get_slice("?", 0).uri_decode()
	var segments := PackedStringArray()
	for segment in path.split("/"):
		if segment.is_empty() or segment == ".":
			continue
		if segment == "..":
			_respond_error(peer, 403)
			return
		segments.append(segment)
	var rel := "/".join(segments)
	if rel == LAUNCHER_PING_PATH:
		_send(peer, 200, "text/plain", LAUNCHER_PING_BODY.to_utf8_buffer(), method == "HEAD")
		return
	if rel.is_empty() or path.ends_with("/"):
		rel = rel.path_join("index.html")
	var file_path := _root.path_join(rel)
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		_respond_error(peer, 404)
		return
	var body := file.get_buffer(file.get_length())
	file.close()
	var mime: String = MIME_TYPES.get(file_path.get_extension().to_lower(), "application/octet-stream")
	_send(peer, 200, mime, body, method == "HEAD")


func _send(peer: StreamPeerTCP, code: int, mime: String, body: PackedByteArray, head_only: bool) -> void:
	var status: String = STATUS_TEXT.get(code, "OK")
	var header := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" % [
		code, status, mime, body.size(),
	]
	peer.put_data(header.to_utf8_buffer())
	if not head_only and not body.is_empty():
		peer.put_data(body)


func _respond_error(peer: StreamPeerTCP, code: int) -> void:
	var status: String = STATUS_TEXT.get(code, "Error")
	var body := ("<html><body><h1>%d %s</h1></body></html>" % [code, status]).to_utf8_buffer()
	_send(peer, code, "text/html", body, false)


func _drop(peer: StreamPeerTCP) -> void:
	_clients.erase(peer)
	peer.disconnect_from_host()
