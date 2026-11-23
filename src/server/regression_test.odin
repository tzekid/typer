#+test
package server

import "base:runtime"
import "core:mem/virtual"
import "core:net"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import engine "../engine"

@(test)
request_framing :: proc(t: ^testing.T) {
	req: Request
	testing.expect(t, parse_head("GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive, close", &req))
	testing.expect(t, !req.keep_alive)
	testing.expect_value(t, req.path, string("/healthz"))
	n, valid := body_length("01234")
	testing.expect(t, valid && n == 1234)
	_, invalid := body_length("+2")
	testing.expect(t, !invalid)
	n, valid = body_length("999999999999999999999999")
	testing.expect(t, valid && n > BODY_MAX)
	testing.expect_value(t, encoding_quality("gzip, br;q=0", "br"), f64(0))
	testing.expect_value(t, encoding_quality("gzip, br;q=0", "gzip"), f64(1))
	v, decoded := url_decode("caf%C3%A9")
	testing.expect(t, decoded && v == "café")
}

@(test)
wasm_result_round_trip :: proc(t: ^testing.T) {
	g_packs = "build/packs"
	if !load_languages() do testing.fail_now(t, "Build packs first")
	if err, ok := db_open(&g_db, ":memory:"); !ok do testing.fail_now(t, err)
	defer db_close(&g_db)
	g_origin = "https://typer.example"
	assets_init()
	body, err := os.read_entire_file("build/fixture.tyr", context.allocator)
	if err != nil do testing.fail_now(t, "Run scripts/test.sh to generate a browser-engine record")
	req := Request{path = "/me/session", method = "POST", peer = net.IP4_Loopback}
	append(&req.headers, Header{"origin", g_origin})
	res := Response{status = 200}
	route(&req, &res)
	if len(res.headers) == 0 do testing.fail_now(t, "missing session cookie")
	session := strings.split(res.headers[0].value, ";")[0]
	append(&req.headers, Header{"cookie", session})
	append(&req.headers, Header{"content-type", "application/octet-stream"})
	req.path, req.body = "/results", body
	for expected in ([?]int{201, 200}) {
		res = {status = 200}
		route(&req, &res)
		testing.expect_value(t, res.status, expected)
		testing.expect_value(t, string(res.body), string("/results/1"))
	}
	user, token, known := current_user(&req)
	testing.expect(t, known)
	h := db_history(&g_db, user.id)
	if len(h.groups) != 1 do testing.fail_now(t, "missing saved setup")
	testing.expect_value(t, h.groups[0].analysed, 1)
	req.path, req.method = strings.concatenate({"/key/", token}), "HEAD"
	res = {status = 200}
	route(&req, &res)
	testing.expect_value(t, res.status, 200)
	for field in res.headers do testing.expect(t, field.name != "set-cookie")
	req.path, req.method = "/key", "POST"
	req.body = transmute([]u8)strings.concatenate({"token=", token})
	res = {status = 200}
	route(&req, &res)
	testing.expect_value(t, res.status, 303)
	req.path, req.method = "/results/1", "GET"
	res = {status = 200}
	route(&req, &res)
	testing.expect_value(t, res.status, 200)
	testing.expect(t, strings.contains(string(res.body), "data-seconds"))
}

@(test)
quote_analytics_on_blank_lines :: proc(t: ^testing.T) {
	files, err := os.read_all_directory_by_path("build/packs/quotes", context.allocator)
	if err != nil do testing.fail_now(t, "Build quote packs first")
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	checked := 0
	for file in files {
		if !strings.has_suffix(file.name, ".bin") do continue
		data, read_error := os.read_entire_file(file.fullpath, runtime.heap_allocator())
		if read_error != nil do testing.fail_now(t, file.name)
		defer delete(data, runtime.heap_allocator())
		pack, valid := engine.quote_pack_view(data)
		if !valid do testing.fail_now(t, file.name)
		for _, i in pack.records {
			virtual.arena_free_all(&arena)
			q := engine.quote_at(&pack, i)
			blank := false
			for token in strings.split(q.text, " ") {
				if strings.trim_space(token) == "" {
					blank = true
					break
				}
			}
			if !blank do continue
			test: engine.Test
			engine.test_reset(&test, {mode = .Quote})
			engine.test_add_quote(&test, q.text)
			ms := 100.0
			for j in 0 ..< engine.word_count(&test) {
				for ch in engine.target_word(&test, j) {
					engine.test_insert(&test, ms, ch)
					ms += 10
				}
			}
			engine.test_finalize(&test)
			if test.phase != .Finished do testing.fail_now(t, "quote did not finish")
			_, _, _, _, _, ok := analysis_header(analysis_encode(analyse_test(&test)))
			if !ok do testing.fail_now(t, "a real code quote produced unreadable analytics")
			checked += 1
		}
	}
	testing.expect(t, checked >= 1527)
	fmt.printfln("Verified analytics for %d quotes with whitespace-only tokens", checked)
}

@(test)
language_pack_generation :: proc(t: ^testing.T) {
	index, err := os.read_entire_file("build/packs/languages.tsv", context.allocator)
	if err != nil do testing.fail_now(t, "Build packs first")
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	lines := strings.split_lines(string(index))
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	checked := 0
	for line in lines {
		virtual.arena_free_all(&arena)
		fields := strings.split(line, "\t")
		if len(fields) != 3 do continue
		data, read_error := os.read_entire_file(strings.concatenate({"build/packs/lang/", fields[0], ".bin"}), runtime.heap_allocator())
		if read_error != nil do testing.fail_now(t, fields[0])
		defer delete(data, runtime.heap_allocator())
		p, valid := engine.pack_view(data)
		if !valid do testing.fail_now(t, fields[0])
		g: engine.Generator
		engine.generator_init(&g, p.list, 15, false, false)
		for i in 0 ..< 150 {
			word := engine.generator_next(&g, i, 150)
			if len(word) == 0 || strings.contains_any(word, " \t\n") do testing.fail_now(t, fmt.tprintf("%s word %d: %q (remaining %q)", fields[0], i, word, g.section))
		}
		checked += 1
	}
	testing.expect(t, checked > 400)
}
