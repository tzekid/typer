package server

import "core:fmt"
import "core:mem/virtual"
import "core:nbio"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

// HTTP/1.1 for many concurrent visitors behind Caddy: one event loop
// (io_uring on Linux, kqueue on macOS), any number of keep-alive connections,
// bounded heads and bodies, deadlines, and a fresh arena per request. Handlers
// run inline on the loop; all of them take microseconds, so one core serves
// tens of thousands of requests a second and the database, rate limiter and
// leaderboard cache need no locks.

HEAD_MAX :: 16 * 1024
BODY_MAX :: 1024 * 1024 // a 120 s test at 200 wpm records about 115 KB
IDLE_TIMEOUT :: 15 * time.Second
HEAD_DEADLINE :: 10 * time.Second
BODY_DEADLINE :: 30 * time.Second
MAX_CONNECTIONS :: 8192

Header :: struct {
	name, value: string,
}

Request :: struct {
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
	}
	return "Unknown"
}

SECURITY_HEADERS :: "content-security-policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'\r\n" + "x-content-type-options: nosniff\r\n" + "referrer-policy: same-origin\r\n" + "x-frame-options: DENY\r\n"

@(private)
Conn :: struct {
	sock:     net.TCP_Socket,
	loop:     ^Loop,
	have:     int,
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
}

// Serves forever.
serve :: proc(listen: net.Endpoint, handler: Handler) -> bool {
	listener, err := net.listen_tcp(listen)
	if err != nil {
		fmt.eprintfln("event=listen_failed address=%s error=%v", net.endpoint_to_string(listen, context.temp_allocator), err)
		return false
	}
	_ = net.set_blocking(listener, false)
	fmt.printfln("event=server_start address=%s", net.endpoint_to_string(listen, context.temp_allocator))
	run_loop(listener, handler)
	return false
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
	nbio.accept_poly(listener, loop, on_accept)
	if err := nbio.run(); err != nil {
		fmt.eprintfln("event=loop_failed error=%v", err)
	}
}

@(private)
on_accept :: proc(op: ^nbio.Operation, loop: ^Loop) {
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
	c.sock = op.accept.client
	c.loop = loop
	_ = virtual.arena_init_growing(&c.arena)
	read_more(c, IDLE_TIMEOUT)
}

@(private)
drop :: proc(c: ^Conn) {
	nbio.close(c.sock)
	virtual.arena_destroy(&c.arena)
	c.loop.connections -= 1
	free(c)
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
	c.req = {}
	if !parse_head(string(c.buf[:head_end - 4]), &c.req) {
		fail(c, 400)
		return
	}
	length := 0
	if cl := header(&c.req, "content-length"); cl != "" {
		v, ok := strconv.parse_int(cl, 10)
		if !ok || v < 0 {
			fail(c, 400)
			return
		}
		length = v
	}
	if length > BODY_MAX {
		fail(c, 413)
		return
	}
	// The head is parsed into the arena, so the buffer can be reused at once.
	body := make([]u8, length)
	got := copy(body, c.buf[head_end:c.have])
	consumed := head_end + got
	copy(c.buf[:], c.buf[consumed:c.have])
	c.have -= consumed
	c.req.body = body
	if got < length {
		nbio.recv_poly(c.sock, {body[got:]}, c, on_body, all = true, timeout = BODY_DEADLINE)
		return
	}
	respond(c)
}

@(private)
on_body :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.recv.err != nil || op.recv.received == 0 {
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
	c.loop.handler(&c.req, &c.res)
	c.head_out = response_head(&c.req, &c.res)
	fmt.printfln(
		"event=request method=%s path=%s status=%d bytes=%d micros=%.0f",
		c.req.method,
		c.req.path,
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
	if op.send.err != nil || !c.req.keep_alive {
		drop(c)
		return
	}
	c.started = time.tick_now()
	next(c)
}

@(private)
fail :: proc(c: ^Conn, status: int) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "HTTP/1.1 %d %s\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", status, status_text(status))
	c.head_out = transmute([]u8)strings.to_string(b)
	c.req.keep_alive = false
	nbio.send_poly(c.sock, {c.head_out}, c, on_sent, timeout = IDLE_TIMEOUT)
}

@(private)
parse_head :: proc(head: string, req: ^Request) -> bool {
	lines := strings.split(head, "\r\n")
	if len(lines) == 0 {
		return false
	}
	parts := strings.split(lines[0], " ")
	if len(parts) != 3 || !strings.has_prefix(parts[2], "HTTP/1.") {
		return false
	}
	req.method = parts[0]
	target := parts[1]
	if len(target) == 0 || target[0] != '/' {
		return false
	}
	if q := strings.index_byte(target, '?'); q >= 0 {
		req.path = target[:q]
		req.query = target[q + 1:]
	} else {
		req.path = target
	}
	req.headers = make([dynamic]Header, 0, len(lines))
	for line in lines[1:] {
		c := strings.index_byte(line, ':')
		if c <= 0 {
			return false
		}
		append(&req.headers, Header{line[:c], strings.trim_space(line[c + 1:])})
	}
	conn := header(req, "connection")
	req.keep_alive = parts[2] == "HTTP/1.1" ? !strings.equal_fold(conn, "close") : strings.equal_fold(conn, "keep-alive")
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
		fmt.sbprintf(&b, "content-encoding: %s\r\nvary: accept-encoding\r\n", res.encoding)
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
			v, ok := strconv.parse_int(s[i + 1:i + 3], 16)
			if !ok {
				return "", false
			}
			strings.write_byte(&b, u8(v))
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
