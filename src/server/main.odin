package server

import "core:crypto"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import engine "../engine"

VERSION :: #config(TYPER_VERSION, "dev")

USAGE :: `usage:
  typer serve <data dir> [--listen 127.0.0.1:9334] [--packs <dir>] [--origin https://host]
  typer doctor <data dir>
  typer claim <data dir> <name> [--origin https://host]   give results saved before typists existed to a new typist
  typer version`

g_db: Db
g_packs: string
g_origin: string
g_languages: []string

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
	}
	switch args[0] {
	case "serve":
		cmd_serve(args[1:])
	case "doctor":
		cmd_doctor(args[1:])
	case "claim":
		cmd_claim(args[1:])
	case "version":
		fmt.println(VERSION)
	case:
		usage()
	}
}

usage :: proc() -> ! {
	fmt.eprintln(USAGE)
	os.exit(2)
}

@(private)
db_path :: proc(dir: string) -> string {
	return strings.concatenate({dir, "/typer.sqlite"})
}

@(private)
open_db :: proc(dir: string) {
	if err, ok := db_open(&g_db, db_path(dir)); !ok {
		fmt.eprintfln("typer: open database: %s", err)
		os.exit(1)
	}
}

cmd_doctor :: proc(args: []string) {
	if len(args) != 1 {
		usage()
	}
	open_db(args[0])
	if r := db_check(&g_db); r != "ok" {
		fmt.eprintfln("doctor: quick_check: %s", r)
		os.exit(1)
	}
	fmt.println("ok")
}

cmd_claim :: proc(args: []string) {
	if len(args) != 2 && len(args) != 4 {
		usage()
	}
	if len(args) == 4 {
		if args[2] != "--origin" {
			usage()
		}
		g_origin = args[3]
	}
	name, ok := clean_name(args[1])
	if !ok {
		fmt.eprintfln("claim: names are %d-%d letters, digits, spaces, . - _", NAME_MIN, NAME_MAX)
		os.exit(2)
	}
	open_db(args[0])
	token, claimed, cok := db_claim(&g_db, name, time.to_unix_nanoseconds(time.now()) / 1_000_000)
	if !cok {
		fmt.eprintfln("claim: %s (is the name taken?)", sql_error(g_db.conn))
		os.exit(1)
	}
	fmt.printfln("%s now owns %d result(s). Open this once in your browser:\n%s", name, claimed, key_link(token))
}

cmd_serve :: proc(args: []string) {
	if len(args) < 1 {
		usage()
	}
	data_dir := args[0]
	listen := "127.0.0.1:9334"
	g_packs = "packs"
	for i := 1; i < len(args); i += 2 {
		if i + 1 >= len(args) {
			usage()
		}
		switch args[i] {
		case "--listen":
			listen = args[i + 1]
		case "--packs":
			g_packs = args[i + 1]
		case "--origin":
			g_origin = args[i + 1]
		case:
			usage()
		}
	}
	ep, ok := net.parse_endpoint(listen)
	if !ok {
		fmt.eprintfln("serve: bad --listen %s", listen)
		os.exit(2)
	}
	if err := os.make_directory_all(data_dir); err != nil && err != .Exist {
		fmt.eprintfln("serve: data dir %s: %v", data_dir, err)
		os.exit(1)
	}
	open_db(data_dir)
	if !load_languages() || !load_quotes() {
		os.exit(1)
	}
	assets_init()
	if !serve(ep, route) {
		os.exit(1)
	}
}

@(private)
load_languages :: proc() -> bool {
	path := strings.concatenate({g_packs, "/languages.tsv"})
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("serve: %s: %v (run ./build.sh pack)", path, err)
		return false
	}
	names := make([dynamic]string)
	for line in strings.split_lines(string(data)) {
		if tab := strings.index_byte(line, '\t'); tab > 0 {
			append(&names, line[:tab])
		}
	}
	g_languages = names[:]
	return true
}

@(private)
known_language :: proc(name: string) -> bool {
	for l in g_languages {
		if l == name {
			return true
		}
	}
	return false
}

route :: proc(req: ^Request, res: ^Response) {
	get := req.method == "GET" || req.method == "HEAD"
	post := req.method == "POST"
	if post && !same_origin(req) {
		respond_text(res, 403, "cross-origin")
		return
	}
	p := req.path
	switch {
	case p == "/" && get:
		test_page(req, res)
	case strings.has_prefix(p, "/assets/") && get:
		if !serve_asset(req, res) {
			respond_text(res, 404, "not found")
		}
	case strings.has_prefix(p, "/packs/") && get:
		serve_pack(req, res)
	case p == "/quotes" && get:
		quotes_window(req, res)
	case p == "/results" && post:
		post_result(req, res)
	case strings.has_prefix(p, "/results/") && get:
		result_page(req, res)
	case p == "/history" && get:
		history_page(req, res)
	case p == "/leaderboard" && get:
		leaderboard_page(req, res)
	case p == "/me" && get:
		me_page(req, res)
	case p == "/me/name" && post:
		rename(req, res)
	case p == "/me/forget" && post:
		set_header(res, "set-cookie", clear_id_cookie())
		redirect(res, "/")
	case strings.has_prefix(p, "/key/") && get:
		use_key(req, res)
	case p == "/settings" && get:
		settings_page(req, res)
	case p == "/settings" && post:
		save_settings(req, res)
	case p == "/theme" && post:
		toggle_theme(req, res)
	case p == "/languages" && get:
		languages_page(req, res)
	case p == "/healthz" && get:
		respond_text(res, 200, "ok")
	case p == "/readyz" && get:
		if r := db_check(&g_db); r == "ok" {
			respond_text(res, 200, "ok")
		} else {
			respond_text(res, 500, r)
		}
	case:
		respond_text(res, 404 if get || post else 405, "not found" if get || post else "method not allowed")
	}
}

// Writes must come from our own pages (SameSite=Lax cookies already keep the
// identity out of cross-site posts; this keeps the rest out too).
@(private)
same_origin :: proc(req: ^Request) -> bool {
	o := header(req, "origin")
	return o == "" || g_origin == "" || o == g_origin
}

@(private)
html_response :: proc(res: ^Response, b: ^strings.Builder) {
	res.type = "text/html; charset=utf-8"
	res.body = transmute([]u8)strings.to_string(b^)
}

THEME_COOKIE :: "typer_theme"
PREFS_COOKIE :: "typer_prefs"
SETUP_COOKIE :: "typer_setup"
LONG_COOKIE :: "; Path=/; Max-Age=31536000; SameSite=Lax"

@(private)
page_for :: proc(req: ^Request) -> Page {
	p: Page
	switch cookie(req, THEME_COOKIE) {
	case "light":
		p.theme = "light"
	case "dark":
		p.theme = "dark"
	}
	p.caret = .Medium
	caret := query_value(cookie(req, PREFS_COOKIE), "caret")
	for c in Caret {
		if CARET_NAMES[c] == caret {
			p.caret = c
		}
	}
	p.user, _, p.known = current_user(req)
	return p
}

MODE2_MAX :: 1000 // the most seconds or words a test can ask for

@(private)
setup_from_query :: proc(q: string) -> (s: Test_Setup, ok: bool) {
	s = DEFAULT_SETUP
	switch query_value(q, "mode") {
	case "time":
		s.mode = .Time
	case "words":
		s.mode = .Words
	case "quote":
		s.mode = .Quote
	case:
		return s, false
	}
	if s.mode == .Quote {
		g, gok := strconv.parse_int(query_value(q, "q"), 10)
		if gok {
			if g < 1 || g > int(QUOTE_ALL) {
				return s, false
			}
			s.quotes = u32(g)
		}
	} else {
		n, nok := strconv.parse_int(query_value(q, "n"), 10)
		if !nok || n < 1 || n > MODE2_MAX {
			return s, false
		}
		s.mode2 = i32(n)
		s.punctuation = query_value(q, "p") == "1"
		s.numbers = query_value(q, "num") == "1"
	}
	if lang := query_value(q, "lang"); lang != "" {
		if !known_language(lang) && quote_collection(lang) == nil {
			return s, false
		}
		s.language = lang
	}
	return s, true
}

@(private)
test_page :: proc(req: ^Request, res: ^Response) {
	s := DEFAULT_SETUP
	if req.query != "" {
		qs, ok := setup_from_query(req.query)
		if !ok {
			respond_text(res, 400, "bad test setup")
			return
		}
		s = qs
		q := strings.builder_make()
		setup_query(&q, s)
		set_header(res, "set-cookie", strings.concatenate({SETUP_COOKIE, "=", url_encode(strings.to_string(q)), LONG_COOKIE, "; HttpOnly"}))
	} else if c := cookie(req, SETUP_COOKIE); c != "" {
		if cs, ok := setup_from_query(c); ok {
			s = cs
		}
	}
	page := Test_Page{setup = s}
	if s.mode == .Quote {
		collection := quote_collection(s.language)
		if collection == nil {
			s.mode = .Words
			s.mode2 = 25
			page.setup = s
		} else {
			seed, pos, ok := parse_queue(cookie(req, QUEUE_COOKIE))
			if !ok {
				raw: [8]u8
				crypto.rand_bytes(raw[:])
				seed = transmute(u64)raw
				pos = 0
				v := strings.builder_make()
				strings.write_u64(&v, seed, 16)
				strings.write_string(&v, ".0")
				set_header(res, "set-cookie", strings.concatenate({QUEUE_COOKIE, "=", strings.to_string(v), LONG_COOKIE}))
			}
			page.seed = seed
			page.from = pos
			page.quotes = deal_quotes(collection, s.quotes, seed, pos, DEAL)
		}
	}
	b := strings.builder_make()
	render_test_page(&b, page_for(req), page)
	html_response(res, &b)
}

// The next quotes of a browser's queue, for the island to refill itself.
@(private)
quotes_window :: proc(req: ^Request, res: ^Response) {
	q := req.query
	collection := quote_collection(query_value(q, "lang"))
	groups, gok := strconv.parse_int(query_value(q, "q"), 10)
	seed, sok := strconv.parse_u64(query_value(q, "seed"), 16)
	from, fok := strconv.parse_int(query_value(q, "from"), 10)
	if collection == nil || !gok || !sok || !fok || groups < 1 || groups > int(QUOTE_ALL) || from < 0 || from > QUEUE_MAX {
		respond_text(res, 400, "bad quote window")
		return
	}
	b := strings.builder_make()
	write_quotes_json(&b, deal_quotes(collection, u32(groups), seed, from, DEAL))
	res.type = "application/json"
	res.body = transmute([]u8)strings.to_string(b)
}

@(private)
serve_pack :: proc(req: ^Request, res: ^Response) {
	name := strings.trim_suffix(strings.trim_prefix(req.path, "/packs/"), ".bin")
	if !known_language(name) || !strings.has_suffix(req.path, ".bin") {
		respond_text(res, 404, "not found")
		return
	}
	data, err := os.read_entire_file(strings.concatenate({g_packs, "/lang/", name, ".bin"}), context.allocator)
	if err != nil {
		respond_text(res, 404, "not found")
		return
	}
	res.type = "application/octet-stream"
	res.cache = "public, max-age=86400"
	res.body = data
}

Replayed :: struct {
	view:  engine.Result_View,
	test:  engine.Test,
	quote: engine.Quote,
}

// Re-derives everything about a test from its record, and for quotes checks
// that the words typed are that quote's.
replay :: proc(record: []u8) -> (r: Replayed, ok: bool) {
	setup, events, dok := engine.record_decode(record, &r.test)
	if !dok {
		return {}, false
	}
	switch setup.mode {
	case .Quote:
		c := g_quotes[setup.language]
		if c == nil {
			return {}, false
		}
		q, found := engine.quote_by_id(&c.pack, u32(setup.mode2))
		if !found || !engine.test_matches_quote(&r.test, q.text) {
			return {}, false
		}
		r.quote = q
	case .Time, .Words:
		if !known_language(setup.language) || setup.mode2 < 1 || setup.mode2 > MODE2_MAX {
			return {}, false
		}
	case .Zen, .Custom:
		return {}, false
	}
	if !engine.record_replay(&r.test, events) {
		return {}, false
	}
	res := engine.build_result(&r.test)
	r.view = engine.Result_View {
		result      = res,
		setup       = setup,
		invalid     = engine.invalid_reason(&r.test, setup, res),
		quote_group = -1,
	}
	if setup.mode == .Quote {
		r.view.quote_group = i32(r.quote.group)
		r.view.quote_source = r.quote.source
	}
	return r, true
}

@(private)
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private)
post_result :: proc(req: ^Request, res: ^Response) {
	if header(req, "content-type") != "application/octet-stream" {
		respond_text(res, 415, "expected application/octet-stream")
		return
	}
	if !allow_write(req) {
		respond_text(res, 429, "slow down")
		return
	}
	r, ok := replay(req.body)
	if !ok {
		respond_text(res, 400, "not a complete typer record")
		return
	}
	user, _, known := current_user(req)
	if !known {
		token := new_token()
		u, created := db_create_user(&g_db, token_sha(token), now_ms())
		if !created {
			respond_text(res, 500, "could not create a typist")
			return
		}
		user = u
		set_header(res, "set-cookie", id_cookie(token))
	}
	v := r.view
	stored := Stored {
		created_at = now_ms(),
		setup      = v.setup,
		qgroup     = v.quote_group,
		wpm        = v.result.wpm,
		raw        = v.result.raw_wpm,
		acc        = v.result.acc,
		cons       = v.result.consistency,
		duration   = v.result.test_duration,
		valid      = v.invalid == "",
		user_id    = user.id,
	}
	id, created, iok := db_insert_result(&g_db, stored, req.body)
	if !iok {
		fmt.eprintfln("event=insert_failed error=%q", sql_error(g_db.conn))
		respond_text(res, 500, "could not store result")
		return
	}
	loc := strings.builder_make()
	strings.write_string(&loc, "/results/")
	strings.write_i64(&loc, id)
	set_header(res, "location", strings.to_string(loc))
	respond_text(res, 201 if created else 200, strings.to_string(loc))
}

@(private)
result_page :: proc(req: ^Request, res: ^Response) {
	id, ok := strconv.parse_i64(strings.trim_prefix(req.path, "/results/"), 10)
	if !ok || id <= 0 {
		respond_text(res, 404, "not found")
		return
	}
	record, stored, found := db_get_record(&g_db, id)
	if !found {
		respond_text(res, 404, "not found")
		return
	}
	r, rok := replay(record)
	if !rok {
		respond_text(res, 500, "stored record does not replay")
		return
	}
	v := r.view
	v.id = id
	v.typist = stored.user_name
	when_b := strings.builder_make()
	write_date(&when_b, stored.created_at)
	strings.write_string(&when_b, " UTC")
	v.finished_at = strings.to_string(when_b)
	attempts: []Stored
	if v.setup.mode == .Quote && stored.user_id != 0 {
		attempts = db_quote_attempts(&g_db, stored.user_id, v.setup.language, v.setup.mode2)
	}
	b := strings.builder_make()
	render_result_page(&b, page_for(req), v, attempts)
	html_response(res, &b)
}

@(private)
history_page :: proc(req: ^Request, res: ^Response) {
	p := page_for(req)
	bests, recent: []Stored
	if p.known {
		bests = db_user_bests(&g_db, p.user.id)
		recent = db_user_recent(&g_db, p.user.id, 100)
	}
	b := strings.builder_make()
	render_history_page(&b, p, bests, recent)
	html_response(res, &b)
}

@(private)
leaderboard_page :: proc(req: ^Request, res: ^Response) {
	q := req.query
	board := Board{mode = .Time, mode2 = 30, language = "english"}
	switch query_value(q, "mode") {
	case "words":
		board.mode = .Words
		board.mode2 = 25
	case "quote":
		board.mode = .Quote
		board.qgroup = 1
	}
	if n, ok := strconv.parse_int(query_value(q, "n"), 10); ok && n > 0 && n <= MODE2_MAX {
		board.mode2 = i32(n)
	}
	// q is a group mask, as on the test page; a board shows one group.
	if m, ok := strconv.parse_int(query_value(q, "q"), 10); ok {
		for g in 0 ..< engine.QUOTE_GROUPS {
			if m == 1 << uint(g) {
				board.qgroup = i32(g)
			}
		}
	}
	if lang := query_value(q, "lang"); lang != "" && (known_language(lang) || g_quotes[lang] != nil) {
		board.language = lang
	}
	if board.mode == .Quote {
		board.language = engine.quote_language(board.language)
	}
	b := strings.builder_make()
	render_leaderboard_page(&b, page_for(req), board, db_board(&g_db, board))
	html_response(res, &b)
}

@(private)
me_page :: proc(req: ^Request, res: ^Response) {
	p := page_for(req)
	_, token, _ := current_user(req)
	message := ""
	problem := false
	switch query_value(req.query, "m") {
	case "saved":
		message = "Saved."
	case "taken":
		message, problem = "That name is taken.", true
	case "invalid":
		message, problem = "Names are 2–24 letters, digits, spaces, dots, dashes or underscores.", true
	case "welcome":
		message = "This browser now types as you."
	}
	b := strings.builder_make()
	render_me_page(&b, p, token, message, problem)
	html_response(res, &b)
}

@(private)
rename :: proc(req: ^Request, res: ^Response) {
	user, _, known := current_user(req)
	if !known {
		redirect(res, "/me")
		return
	}
	if !allow_write(req) {
		respond_text(res, 429, "slow down")
		return
	}
	name, ok := clean_name(query_value(string(req.body), "name"))
	if !ok {
		redirect(res, "/me?m=invalid")
		return
	}
	switch db_rename_user(&g_db, user.id, name) {
	case .Renamed:
		redirect(res, "/me?m=saved")
	case .Taken:
		redirect(res, "/me?m=taken")
	case .Failed:
		respond_text(res, 500, "could not rename")
	}
}

@(private)
use_key :: proc(req: ^Request, res: ^Response) {
	token := strings.trim_prefix(req.path, "/key/")
	if !valid_token(token) {
		respond_text(res, 404, "not found")
		return
	}
	if _, ok := db_user_by_token(&g_db, token_sha(token)); !ok {
		respond_text(res, 404, "not found")
		return
	}
	set_header(res, "set-cookie", id_cookie(token))
	set_header(res, "referrer-policy", "no-referrer")
	redirect(res, "/me?m=welcome")
}

@(private)
settings_page :: proc(req: ^Request, res: ^Response) {
	b := strings.builder_make()
	render_settings_page(&b, page_for(req))
	html_response(res, &b)
}

@(private)
theme_cookie :: proc(theme: string) -> string {
	if theme == "" {
		return strings.concatenate({THEME_COOKIE, "=; Path=/; Max-Age=0; SameSite=Lax"})
	}
	return strings.concatenate({THEME_COOKIE, "=", theme, LONG_COOKIE})
}

@(private)
save_settings :: proc(req: ^Request, res: ^Response) {
	form := string(req.body)
	caret := query_value(form, "caret")
	for c in Caret {
		if CARET_NAMES[c] == caret {
			set_header(res, "set-cookie", strings.concatenate({PREFS_COOKIE, "=", url_encode(strings.concatenate({"caret=", caret})), LONG_COOKIE}))
		}
	}
	switch query_value(form, "theme") {
	case "light":
		set_header(res, "set-cookie", theme_cookie("light"))
	case "dark":
		set_header(res, "set-cookie", theme_cookie("dark"))
	case "system":
		set_header(res, "set-cookie", theme_cookie(""))
	}
	redirect(res, "/settings")
}

// The no-script theme switch; app.js flips it in place instead.
@(private)
toggle_theme :: proc(req: ^Request, res: ^Response) {
	next := "dark"
	if cookie(req, THEME_COOKIE) == "dark" {
		next = "light"
	}
	set_header(res, "set-cookie", theme_cookie(next))
	back := "/"
	ref := header(req, "referer")
	if g_origin != "" && strings.has_prefix(ref, g_origin) {
		back = ref[len(g_origin):]
	}
	if !strings.has_prefix(back, "/") || strings.has_prefix(back, "//") {
		back = "/"
	}
	redirect(res, back)
}

@(private)
languages_page :: proc(req: ^Request, res: ^Response) {
	s := DEFAULT_SETUP
	if qs, ok := setup_from_query(req.query); ok {
		s = qs
	} else if query_value(req.query, "mode") == "quote" {
		s.mode = .Quote
	}
	board := query_value(req.query, "board") == "1"
	if board {
		switch query_value(req.query, "mode") {
		case "words":
			s.mode = .Words
		case "quote":
			s.mode = .Quote
		case:
			s.mode = .Time
		}
	}
	b := strings.builder_make()
	render_languages_page(&b, page_for(req), s, board, g_quote_languages if s.mode == .Quote else g_languages)
	html_response(res, &b)
}
