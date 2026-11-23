package server

import "base:runtime"
import "base:intrinsics"
import "core:sys/posix"
import "core:fmt"
import "core:mem/virtual"
import "core:nbio"
import "core:net"
import "core:encoding/hex"
import "core:strings"
import "core:slice"
import "core:time"

// HTTP/1.1 for many concurrent visitors behind Caddy: one event loop
// (io_uring on Linux, kqueue on macOS), any number of keep-alive connections,
// bounded heads and bodies, deadlines, and a fresh arena per request. Handlers
// run inline on the loop; all of them take microseconds, so one core serves
// tens of thousands of requests a second and the database, rate limiter and
// leaderboard cache need no locks.
//
// Memory has a worst case that fits the service's 128 MB limit: each
// connection keeps its 16 KB buffer and at most ARENA_KEEP between requests,
// and all bodies in flight share BODIES_MAX.

HEAD_MAX :: 16 * 1024
BODY_MAX :: 1024 * 1024 // a 120 s test at 200 wpm records about 115 KB
IDLE_TIMEOUT :: 15 * time.Second
HEAD_DEADLINE :: 10 * time.Second
BODY_DEADLINE :: 30 * time.Second
BODIES_MAX :: 16 * 1024 * 1024
ARENA_KEEP :: 64 * 1024
MAX_CONNECTIONS :: 512

Header :: struct {
	name, value: string,
}

Request :: struct {
	peer:       net.Address,
	method:     string,
	path:       string,
	query:      string,
	headers:    [dynamic]Header,
	body:       []u8,
	keep_alive: bool,
}

Response :: struct {
	status:   int,
	type:     string,
	cache:    string,
	encoding: string,
	shared_body: bool, // immutable asset or mapped pack with process lifetime
	body:     []u8,
	headers:  [dynamic]Header,
}

Handler :: proc(req: ^Request, res: ^Response)

header :: proc(req: ^Request, name: string) -> string {
	for h in req.headers {
		if strings.equal_fold(h.name, name) {
			return h.value
		}
	}
	return ""
}

set_header :: proc(res: ^Response, name, value: string) {
	append(&res.headers, Header{name, value})
}

respond_text :: proc(res: ^Response, status: int, text: string) {
	res.status = status
	res.type = "text/plain; charset=utf-8"
	res.body = transmute([]u8)text
}

redirect :: proc(res: ^Response, location: string) {
	res.status = 303
	set_header(res, "location", location)
}

@(private)
status_text :: proc(code: int) -> string {
	switch code {
	case 200:
		return "OK"
	case 201:
		return "Created"
	case 303:
		return "See Other"
	case 400:
		return "Bad Request"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 409:
		return "Conflict"
	case 413:
		return "Payload Too Large"
	case 415:
		return "Unsupported Media Type"
	case 429:
		return "Too Many Requests"
	case 431:
		return "Request Header Fields Too Large"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 503:
		return "Service Unavailable"
	}
	return "Unknown"
}

SECURITY_HEADERS :: "content-security-policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'\r\n" + "x-content-type-options: nosniff\r\n" + "referrer-policy: no-referrer\r\n" + "x-frame-options: DENY\r\n"

@(private)
Conn :: struct {
	sock:     net.TCP_Socket,
	peer:     net.Address,
	loop:     ^Loop,
	have:     int,
	body_remaining: int,
	response_bytes: int,
	started:  time.Tick, // first byte of the request being read
	req:      Request,
	res:      Response,
	head_out: []u8,
	arena:    virtual.Arena,
	buf:      [HEAD_MAX]u8,
}

@(private)
Loop :: struct {
	listener:    net.TCP_Socket,
	handler:     Handler,
	connections: int,
	scratch:     virtual.Arena,
	responses:   int,
	bodies:      int, // bytes of request bodies being received or handled
}

@(private)
stopping: bool

request_shutdown :: proc "c" (_: posix.Signal) {
	intrinsics.volatile_store(&stopping, true)
}

serve :: proc(listen: net.Endpoint, handler: Handler) -> bool {
	listener, err := net.listen_tcp(listen)
	if err != nil {
		fmt.eprintfln("event=listen_failed address=%s error=%v", net.endpoint_to_string(listen, context.temp_allocator), err)
		return false
	}
	_ = net.set_blocking(listener, false)
	fmt.printfln("event=server_start address=%s", net.endpoint_to_string(listen, context.temp_allocator))
	_ = posix.signal(.SIGTERM, request_shutdown)
	run_loop(listener, handler)
	return intrinsics.volatile_load(&stopping)
}

@(private)
run_loop :: proc(listener: net.TCP_Socket, handler: Handler) {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintfln("event=loop_failed error=%v", err)
		return
	}
	defer nbio.release_thread_event_loop()
	if err := nbio.associate_socket(listener); err != nil {
		fmt.eprintfln("event=loop_failed error=%v", err)
		return
	}
	loop := new(Loop)
	loop^ = {
		listener = listener,
		handler  = handler,
	}
	_ = virtual.arena_init_growing(&loop.scratch)
	defer virtual.arena_destroy(&loop.scratch)
	nbio.accept_poly(listener, loop, on_accept)
	for !intrinsics.volatile_load(&stopping) {
		if err := nbio.tick(time.Second); err != nil && !intrinsics.volatile_load(&stopping) {
			fmt.eprintfln("event=loop_failed error=%v", err)
			return
		}
	}
	nbio.close(listener)
	started := time.tick_now()
	for loop.connections > 0 && time.tick_since(started) < 5 * time.Second {
		_ = nbio.tick(100 * time.Millisecond)
	}
}

@(private)
on_accept :: proc(op: ^nbio.Operation, loop: ^Loop) {
	if intrinsics.volatile_load(&stopping) {
		if op.accept.err == nil do nbio.close(op.accept.client)
		return
	}
	nbio.accept_poly(loop.listener, loop, on_accept)
	if op.accept.err != nil {
		fmt.eprintfln("event=accept_failed error=%v", op.accept.err)
		return
	}
	if loop.connections >= MAX_CONNECTIONS {
		nbio.close(op.accept.client)
		return
	}
	loop.connections += 1
	c := new(Conn)
	ep, _ := net.peer_endpoint(op.accept.client)
	c.peer = ep.address
	c.sock = op.accept.client
	c.loop = loop
	_ = virtual.arena_init_growing(&c.arena)
	read_more(c, IDLE_TIMEOUT)
}

@(private)
drop :: proc(c: ^Conn) {
	nbio.close(c.sock)
	release_body(c)
	c.loop.responses -= c.response_bytes
	virtual.arena_destroy(&c.arena)
	c.loop.connections -= 1
	free(c)
}

// Bodies are allocated outside the arena so the budget can count them exactly
// and hand their memory back as soon as the handler is done with them.
@(private)
release_body :: proc(c: ^Conn) {
	if len(c.req.body) > 0 {
		c.loop.bodies -= len(c.req.body)
		delete(c.req.body, runtime.heap_allocator())
	}
	c.req.body = nil
}

// After a large request, give its memory back rather than keep it on an idle connection.
@(private)
shrink_arena :: proc(c: ^Conn) {
	if c.arena.total_used > ARENA_KEEP {
		virtual.arena_destroy(&c.arena)
		_ = virtual.arena_init_growing(&c.arena)
	} else {
		virtual.arena_free_all(&c.arena)
	}
}

@(private)
read_more :: proc(c: ^Conn, timeout: time.Duration) {
	nbio.recv_poly(c.sock, {c.buf[c.have:]}, c, on_recv, timeout = timeout)
}

@(private)
on_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.recv.err != nil || op.recv.received == 0 {
		drop(c)
		return
	}
	if c.have == 0 {
		c.started = time.tick_now()
	}
	c.have += op.recv.received
	next(c)
}

@(private)
find_head_end :: proc(b: []u8) -> int {
	for i := 0; i + 3 < len(b); i += 1 {
		if b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n' {
			return i + 4
		}
	}
	return -1
}

// Handle the next request in the buffer, or read until one is complete.
@(private)
next :: proc(c: ^Conn) {
	// The previous response has been sent, so its arena memory is free to reuse.
	context.allocator = virtual.arena_allocator(&c.arena)
	context.temp_allocator = context.allocator
	head_end := find_head_end(c.buf[:c.have])
	if head_end < 0 {
		if c.have == 0 {
			read_more(c, IDLE_TIMEOUT)
			return
		}
		if c.have == HEAD_MAX {
			fail(c, 431)
			return
		}
		left := HEAD_DEADLINE - time.tick_since(c.started)
		if left <= 0 {
			drop(c)
			return
		}
		read_more(c, left)
		return
	}

	virtual.arena_free_all(&c.arena)
	c.req = {peer = c.peer}
	if !parse_head(strings.clone(string(c.buf[:head_end - 4])), &c.req) {
		fail(c, 400)
		return
	}
	// Only Content-Length bodies are read: a chunked body left in the buffer
	// would be parsed as the proxy's next request on this connection.
	if header(&c.req, "transfer-encoding") != "" {
		fail(c, 501)
		return
	}
	length := 0
	if cl := header(&c.req, "content-length"); cl != "" {
		v, ok := body_length(cl)
		if !ok {
			fail(c, 400)
			return
		}
		length = v
	}
	if length > BODY_MAX {
		fail(c, 413)
		return
	}
	if c.loop.bodies + length > BODIES_MAX {
		fail(c, 503)
		return
	}
	// The head is parsed into the arena, so the buffer can be reused at once.
	body: []u8
	if length > 0 {
		body = make([]u8, length, runtime.heap_allocator())
		c.loop.bodies += length
	}
	got := copy(body, c.buf[head_end:c.have])
	consumed := head_end + got
	copy(c.buf[:], c.buf[consumed:c.have])
	c.have -= consumed
	c.req.body = body
	c.body_remaining = length - got
	if got < length {
		nbio.recv_poly(c.sock, {body[got:]}, c, on_body, all = true, timeout = BODY_DEADLINE)
		return
	}
	respond(c)
}

@(private)
on_body :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.recv.err != nil || op.recv.received != c.body_remaining {
		drop(c)
		return
	}
	context.allocator = virtual.arena_allocator(&c.arena)
	context.temp_allocator = context.allocator
	respond(c)
}

@(private)
respond :: proc(c: ^Conn) {
	started := time.tick_now()
	c.res = Response {
		status = 200,
	}
	// Analysis and rendering can allocate much more than the finished page.
	// Release these temporaries before a slow socket starts its send.
	scratch := &c.loop.scratch
	defer {
		if scratch.total_used > ARENA_KEEP {
			virtual.arena_destroy(scratch)
			_ = virtual.arena_init_growing(scratch)
		} else {
			virtual.arena_free_all(scratch)
		}
	}
	context.allocator = virtual.arena_allocator(scratch)
	context.temp_allocator = context.allocator
	c.loop.handler(&c.req, &c.res)
	head := response_head(&c.req, &c.res)
	hold := len(head)
	send_body := c.req.method != "HEAD" && len(c.res.body) > 0
	if send_body && !c.res.shared_body do hold += len(c.res.body)
	context.allocator = virtual.arena_allocator(&c.arena)
	context.temp_allocator = context.allocator
	if c.loop.responses + hold > BODIES_MAX {
		release_body(c)
		fail(c, 503)
		return
	}
	c.response_bytes = hold
	c.loop.responses += hold
	c.head_out = slice.clone(head)
	if send_body && !c.res.shared_body do c.res.body = slice.clone(c.res.body)
	release_body(c)
	fmt.printfln(
		"event=request method=%s path=%s status=%d bytes=%d micros=%.0f",
		c.req.method,
		"/key/[redacted]" if strings.has_prefix(c.req.path, "/key/") else c.req.path,
		c.res.status,
		len(c.res.body),
		time.duration_microseconds(time.tick_since(started)),
	)
	if len(c.res.body) > 0 && c.req.method != "HEAD" {
		nbio.send_poly(c.sock, {c.head_out, c.res.body}, c, on_sent, timeout = IDLE_TIMEOUT)
	} else {
		nbio.send_poly(c.sock, {c.head_out}, c, on_sent, timeout = IDLE_TIMEOUT)
	}
}

@(private)
on_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.send.err != nil || !c.req.keep_alive || intrinsics.volatile_load(&stopping) {
		drop(c)
		return
	}
	c.loop.responses -= c.response_bytes
	c.response_bytes = 0
	c.started = time.tick_now()
	shrink_arena(c)
	next(c)
}

@(private)
fail :: proc(c: ^Conn, status: int) {
	fmt.printfln("event=request_refused status=%d", status)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "HTTP/1.1 %d %s\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", status, status_text(status))
	c.head_out = transmute([]u8)strings.to_string(b)
	c.req.keep_alive = false
	nbio.send_poly(c.sock, {c.head_out}, c, on_sent, timeout = IDLE_TIMEOUT)
}

@(private)
body_length :: proc(s: string) -> (int, bool) {
	n := 0
	if len(s) == 0 do return 0, false
	for c in s {
		if c < '0' || c > '9' do return 0, false
		n = min(BODY_MAX + 1, n * 10 + int(c - '0'))
	}
	return n, true
}

http_token :: proc(s: string) -> bool {
	for c in s {
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' do continue
		if !strings.contains_rune("!#$%&'*+-.^_`|~", c) do return false
	}
	return len(s) > 0
}

parse_head :: proc(head: string, req: ^Request) -> bool {
	lines := strings.split(head, "\r\n")
	if len(lines) == 0 {
		return false
	}
	parts := strings.split(lines[0], " ")
	if len(parts) != 3 || !http_token(parts[0]) || (parts[2] != "HTTP/1.0" && parts[2] != "HTTP/1.1") {
		return false
	}
	req.method = parts[0]
	target := parts[1]
	if len(target) == 0 || target[0] != '/' {
		return false
	}
	for c in target {
		if c <= ' ' || c == 127 do return false
	}
	if q := strings.index_byte(target, '?'); q >= 0 {
		req.path = target[:q]
		req.query = target[q + 1:]
	} else {
		req.path = target
	}
	req.headers = make([dynamic]Header, 0, len(lines))
	seen := make(map[string]bool)
	close, keep := false, false
	for line in lines[1:] {
		c := strings.index_byte(line, ':')
		if c <= 0 {
			return false
		}
		name := strings.to_lower(line[:c])
		if !http_token(name) do return false
		raw := line[c + 1:]
		for b in raw {
			if b < 32 && b != '\t' || b == 127 do return false
		}
		value := strings.trim(raw, " \t")
		switch name {
		case "host", "origin", "transfer-encoding", "content-length", "sec-fetch-site", "referer":
			if seen[name] || value == "" do return false
			seen[name] = true
		case "connection":
			for part in strings.split(value, ",") {
				token := strings.trim_space(part)
				if strings.equal_fold(token, "close") do close = true
				if strings.equal_fold(token, "keep-alive") do keep = true
			}
		}
		append(&req.headers, Header{name, value})
	}
	if parts[2] == "HTTP/1.1" && !seen["host"] do return false
	req.keep_alive = !close && (parts[2] == "HTTP/1.1" || keep)
	return true
}

@(private)
response_head :: proc(req: ^Request, res: ^Response) -> []u8 {
	b := strings.builder_make(0, 768)
	fmt.sbprintf(&b, "HTTP/1.1 %d %s\r\n", res.status, status_text(res.status))
	if res.type != "" {
		fmt.sbprintf(&b, "content-type: %s\r\n", res.type)
	}
	if res.encoding != "" {
		fmt.sbprintf(&b, "content-encoding: %s\r\n", res.encoding)
	}
	fmt.sbprintf(&b, "content-length: %d\r\n", len(res.body))
	fmt.sbprintf(&b, "cache-control: %s\r\n", res.cache if res.cache != "" else "no-store")
	strings.write_string(&b, SECURITY_HEADERS)
	for h in res.headers {
		fmt.sbprintf(&b, "%s: %s\r\n", h.name, h.value)
	}
	if !req.keep_alive {
		strings.write_string(&b, "connection: close\r\n")
	}
	strings.write_string(&b, "\r\n")
	return b.buf[:]
}

// Decodes one query or form component (+ as space, %XX escapes).
url_decode :: proc(s: string, allocator := context.allocator) -> (string, bool) {
	b := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '+':
			strings.write_byte(&b, ' ')
		case '%':
			if i + 2 >= len(s) {
				return "", false
			}
			v, ok := hex.decode_sequence(s[i + 1:i + 3])
			if !ok do return "", false
			strings.write_byte(&b, v)
			i += 2
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b), true
}

url_encode :: proc(s: string) -> string {
	b := strings.builder_make()
	hex := "0123456789ABCDEF"
	for c in transmute([]u8)s {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' {
			strings.write_byte(&b, c)
		} else {
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 0xF])
		}
	}
	return strings.to_string(b)
}

query_value :: proc(query: string, key: string) -> string {
	q := query
	for len(q) > 0 {
		pair := q
		if amp := strings.index_byte(q, '&'); amp >= 0 {
			pair = q[:amp]
			q = q[amp + 1:]
		} else {
			q = ""
		}
		k, v := pair, ""
		if eq := strings.index_byte(pair, '='); eq >= 0 {
			k, v = pair[:eq], pair[eq + 1:]
		}
		if k == key {
			d, ok := url_decode(v)
			return d if ok else ""
		}
	}
	return ""
}

cookie :: proc(req: ^Request, name: string) -> string {
	for part in strings.split(header(req, "cookie"), ";") {
		p := strings.trim_space(part)
		if strings.has_prefix(p, name) && len(p) > len(name) && p[len(name)] == '=' {
			v, _ := url_decode(p[len(name) + 1:])
			return v
		}
	}
	return ""
}
