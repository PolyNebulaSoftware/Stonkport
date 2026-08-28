extends Node
## Minimal static HTTP/1.1 file server over [TCPServer].
##
## Just enough HTTP for Godot WASM builds, which require correct MIME types
## (application/wasm etc.) and therefore cannot be opened via file://.
## Single-threaded: connections are polled in _process() and each client is
## served exactly one GET/HEAD response before the socket is closed — except
## /__proxy relays, which park the socket until the upstream answer arrives.
##
## The /__proxy relay exists for the WASM build: browsers cannot call the
## finance APIs directly (no CORS headers), so the web app has this server
## fetch them instead. Relayed hosts are allowlisted so the endpoint cannot
## be abused as an open local proxy by other pages.

const MAX_REQUEST_BYTES := 8192
const CLIENT_TIMEOUT_MSEC := 10_000
const PORT_ATTEMPTS := 10

## Same-origin data relay for the WASM build (see header). Only https URLs on
## known finance API hosts are relayed; anything else is refused with 400.
const RELAY_PATH := "__proxy"
const RELAY_ATTEMPT_TIMEOUT_SEC := 4.0
const RELAY_MAX_BODY_BYTES := 4_194_304
const RELAY_ALLOWED_HOSTS := [
	"finance.yahoo.com",
	"query1.finance.yahoo.com",
	"query2.finance.yahoo.com",
	"data-api.binance.vision",
]
## Upstream transport chain tried per relayed fetch: direct first, then
## public CORS proxies. Fetched server-side their missing CORS headers do
## not matter, so they rescue fetches when Yahoo refuses the direct route.
const RELAY_DIRECT := ""   # sentinel: fetch the upstream URL as-is
const RELAY_PROXIES := [
	"https://api.allorigins.win/raw?url=%s",
	"https://api.codetabs.com/v1/proxy/?quest=%s",
	"https://corsproxy.io/?url=%s",
]

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
	204: "No Content",
	400: "Bad Request",
	403: "Forbidden",
	404: "Not Found",
	405: "Method Not Allowed",
	431: "Request Header Fields Too Large",
	502: "Bad Gateway",
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
var _relay_transport := 0  # RELAY chain index that last answered (sticky)


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
	var raw := buffer.substr(0, end)
	# Socket ownership moves to the handler: relay requests park the socket
	# for the upstream round-trip instead of the usual serve-and-close.
	_clients.erase(peer)
	_dispatch(peer, raw)


func _dispatch(peer: StreamPeerTCP, raw: String) -> void:
	var parts := raw.get_slice("\r\n", 0).split(" ", false)
	var method: String = parts[0] if parts.size() > 0 else ""
	var target: String = parts[1] if parts.size() > 1 else "/"
	if method == "OPTIONS":
		# CORS preflight — same-origin callers never need it, harmless anyway.
		_send(peer, 204, "text/plain", PackedByteArray(), false,
				"Access-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n")
		_drop(peer)
		return
	if method != "GET" and method != "HEAD":
		_respond_error(peer, 405)
		_drop(peer)
		return
	if target == "/%s" % RELAY_PATH or target.begins_with("/%s?" % RELAY_PATH):
		_relay(peer, method, target)
		return
	_handle_request(peer, method, target)
	_drop(peer)


func _handle_request(peer: StreamPeerTCP, method: String, target: String) -> void:
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


## Relays a /__proxy request to its allowlisted upstream and copies the
## response back. Runs as a coroutine: _dispatch() parked the socket, and it
## stays open until an upstream transport answers or the chain is exhausted.
## Transports are tried round-robin from the one that last succeeded, so a
## blocked direct route does not stall every request.
func _relay(peer: StreamPeerTCP, method: String, target: String) -> void:
	var upstream := _relay_target(target)
	if upstream.is_empty():
		_respond_error(peer, 400)
		_drop(peer)
		return
	var transports: Array = [RELAY_DIRECT]
	transports.append_array(RELAY_PROXIES)
	for i in transports.size():
		var tmpl: String = transports[(_relay_transport + i) % transports.size()]
		var url := upstream if tmpl.is_empty() else tmpl % upstream.uri_encode()
		var res: Array = await _relay_fetch(url)
		if not res[0]:
			continue
		_relay_transport = (_relay_transport + i) % transports.size()
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return  # browser gave up while the upstream round-trip ran
		# Upstream status passes through (e.g. Yahoo 429) so callers can react.
		_send(peer, int(res[1]), res[3], res[2], method == "HEAD")
		_drop(peer)
		return
	_respond_error(peer, 502)
	_drop(peer)


## One transport attempt. Returns [ok, status, body, mime]; "ok" covers any
## 2xx/3xx answer — 429/5xx and transport failures rotate to the next one.
func _relay_fetch(url: String) -> Array:
	var http := HTTPRequest.new()
	http.timeout = RELAY_ATTEMPT_TIMEOUT_SEC
	http.body_size_limit = RELAY_MAX_BODY_BYTES
	add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return [false, 0, PackedByteArray(), ""]
	var res: Array = await http.request_completed
	var mime := "application/json"
	for header in http.get_response_headers():
		if header.to_lower().begins_with("content-type:"):
			mime = header.substr(13).strip_edges()
			break
	http.queue_free()
	var ok: bool = res[0] == HTTPRequest.RESULT_SUCCESS \
			and int(res[1]) >= 200 and int(res[1]) < 400
	return [ok, int(res[1]), res[3], mime]


## Extracts the "url=" parameter from a /__proxy target and enforces the
## https + allowlisted-host policy. Returns "" for anything disallowed.
func _relay_target(target: String) -> String:
	var url := ""
	for pair in target.get_slice("?", 1).split("&", false):
		if pair.begins_with("url="):
			url = pair.substr(4).uri_decode()
			break
	if not url.begins_with("https://"):
		return ""
	var host := url.substr(8).get_slice("/", 0).get_slice(":", 0).to_lower()
	if not RELAY_ALLOWED_HOSTS.has(host):
		return ""
	return url


func _send(peer: StreamPeerTCP, code: int, mime: String, body: PackedByteArray, head_only: bool, extra_headers := "") -> void:
	var status: String = STATUS_TEXT.get(code, "OK")
	var header := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\n%sConnection: close\r\n\r\n" % [
		code, status, mime, body.size(), extra_headers,
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
