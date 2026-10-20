package server

import "core:strings"
import "core:time"

import engine "../engine"

// Server-rendered pages. Everything except the typing surface works as plain
// HTML; the test page carries its setup as JSON for the island. With script,
// app.js swaps <header> and <main> in place instead of loading a new page,
// so `kind` (on <main>) tells it which page it is looking at.

Caret :: enum {
	Off,
	Fast,
	Medium,
	Slow,
}

CARET_NAMES := [Caret]string {
	.Off    = "off",
	.Fast   = "fast",
	.Medium = "medium",
	.Slow   = "slow",
}

CARET_MS := [Caret]int {
	.Off    = 0,
	.Fast   = 85,
	.Medium = 100,
	.Slow   = 150,
}

Test_Setup :: struct {
	mode:        engine.Mode, // .Time, .Words or .Quote
	mode2:       i32,
	punctuation: bool,
	numbers:     bool,
	language:    string,
	quotes:      u32, // selected quote length groups, a bit per group
}

DEFAULT_SETUP :: Test_Setup {
	mode     = .Time,
	mode2    = 30,
	language = "english",
	quotes   = QUOTE_DEFAULT,
}

// What every page needs to know about the visitor.
Page :: struct {
	theme: string, // "light", "dark" or "" for the system's
	caret: Caret,
	user:  User,
	known: bool, // user is set
}

w :: strings.write_string

@(private)
page_start :: proc(b: ^strings.Builder, p: Page, title: string, kind: string, preload: []string = nil) {
	w(b, `<!doctype html><html lang="en"`)
	if p.theme != "" {
		w(b, ` data-theme="`)
		w(b, p.theme)
		w(b, `"`)
	}
	w(b, `><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark">`)
	w(b, `<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)"><meta name="theme-color" content="#171717" media="(prefers-color-scheme: dark)"><title>`)
	engine.html_text(b, title)
	w(b, `</title>`)
	for name in preload {
		w(b, `<link rel="preload" href="`)
		w(b, asset_url(name))
		w(b, `" as="`)
		w(b, "fetch" if strings.has_suffix(name, ".wasm") else "font")
		if strings.has_suffix(name, ".woff2") do w(b, `" type="font/woff2`)
		w(b, `" crossorigin>`)
	}
	w(b, `<link rel="stylesheet" href="`)
	w(b, asset_url("app.css"))
	w(b, `"><script src="`)
	w(b, asset_url("app.js"))
	w(b, `" defer></script><script src="`)
	w(b, asset_url("island.js"))
	w(b, `" data-wasm="`)
	w(b, asset_url("core.wasm"))
	w(b, `" defer></script></head><body><header class="top"><a class="mark" href="/">&lt;{ typer }&gt;</a>`)
	w(b, `<form class="theme" method="post" action="/theme"><button type="submit" data-theme-toggle aria-label="Switch between light and dark">&lt;{ <span class="glyph"></span> }&gt;</button></form><nav>`)
	for item in ([?][3]string{{"/", "play", "test"}, {"/leaderboard", "leaderboard", "leaderboard"}, {"/history", "history", "history"}, {"/settings", "settings", "settings"}}) {
		w(b, `<a href="`)
		w(b, item[0])
		w(b, `"`)
		if item[2] == kind do w(b, ` aria-current="page"`)
		w(b, `>`)
		w(b, item[1])
		w(b, `</a>`)
	}
	if p.known {
		w(b, `<a class="me" href="/me"`)
		if kind == "me" do w(b, ` aria-current="page"`)
		w(b, `>`)
		engine.html_text(b, p.user.name)
		w(b, `</a>`)
	}
	w(b, `</nav></header><main tabindex="-1" data-page="`)
	w(b, kind)
	w(b, `">`)
}

@(private)
page_end :: proc(b: ^strings.Builder) {
	w(b, `</main><footer class="foot"><a href="https://github.com/tzekid/typer">source</a> · rules, words and quotes from <a href="https://monkeytype.com">Monkeytype</a></footer></body></html>`)
}

// A row of the settings and "you" pages: what it is on the left, the
// control on the right.
@(private)
setting_start :: proc(b: ^strings.Builder, title: string, about: string) {
	w(b, `<section class="setting"><div class="about"><h3>`)
	engine.html_text(b, title)
	w(b, `</h3><p>`)
	engine.html_text(b, about)
	w(b, `</p></div><div class="control">`)
}

@(private)
setting_end :: proc(b: ^strings.Builder) {
	w(b, `</div></section>`)
}

// Pill-shaped radio choices; the inputs stay real for forms and keyboards.
@(private)
segmented :: proc(b: ^strings.Builder, name: string, label: string, choices: [][2]string, checked: string) {
	w(b, `<div class="seg" role="radiogroup" aria-label="`)
	engine.html_attr(b, label)
	w(b, `">`)
	for c in choices {
		w(b, `<label><input type="radio" name="`)
		w(b, name)
		w(b, `" value="`)
		w(b, c[0])
		w(b, `"`)
		if c[0] == checked do w(b, ` checked`)
		w(b, `><span>`)
		engine.html_text(b, c[1])
		w(b, `</span></label>`)
	}
	w(b, `</div>`)
}

@(private)
toast :: proc(b: ^strings.Builder, message: string) {
	w(b, `<p class="toast" role="status">`)
	engine.html_text(b, message)
	w(b, `</p>`)
}

@(private)
mode_word :: proc(m: engine.Mode) -> string {
	#partial switch m {
	case .Words:
		return "words"
	case .Quote:
		return "quote"
	}
	return "time"
}

setup_query :: proc(b: ^strings.Builder, s: Test_Setup) {
	w(b, "mode=")
	w(b, mode_word(s.mode))
	if s.mode == .Quote {
		w(b, "&q=")
		strings.write_int(b, int(s.quotes))
	} else {
		w(b, "&n=")
		strings.write_int(b, int(s.mode2))
		if s.punctuation do w(b, "&p=1")
		if s.numbers do w(b, "&num=1")
	}
	if s.language != "english" {
		w(b, "&lang=")
		w(b, url_encode(s.language))
	}
}

@(private)
setup_href :: proc(b: ^strings.Builder, s: Test_Setup) {
	q := strings.builder_make(context.temp_allocator)
	w(&q, "/?")
	setup_query(&q, s)
	engine.html_attr(b, strings.to_string(q))
}

@(private)
mode_link :: proc(b: ^strings.Builder, label: string, s: Test_Setup, on: bool) {
	w(b, `<a href="`)
	setup_href(b, s)
	w(b, `"`)
	if on do w(b, ` class="on" aria-current="true"`)
	w(b, `>`)
	engine.html_text(b, label)
	w(b, `</a>`)
}

@(private)
int_label :: proc(n: i32) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, int(n))
	return strings.to_string(b)
}

Test_Page :: struct {
	setup:  Test_Setup,
	quotes: []engine.Quote, // dealt queue window, quote mode
	seed:   u64,
	from:   int,
}

render_test_page :: proc(b: ^strings.Builder, p: Page, t: Test_Page) {
	s := t.setup
	page_start(b, p, "typer", "test", {"DMMono-latin.woff2", "core.wasm"})
	// The bar keeps its width whatever the mode: punctuation and numbers dim
	// for quotes, and every mode's options share one stacked slot.
	w(b, `<nav class="bar" aria-label="test setup"><span class="group`)
	if s.mode == .Quote {
		w(b, ` off" title="quotes come with their own punctuation and numbers"><span>punctuation</span><span>numbers</span>`)
	} else {
		w(b, `">`)
		x := s
		x.punctuation = !s.punctuation
		mode_link(b, "punctuation", x, s.punctuation)
		x = s
		x.numbers = !s.numbers
		mode_link(b, "numbers", x, s.numbers)
	}
	w(b, `</span><i class="sep"></i><span class="group">`)
	for m in ([?]engine.Mode{.Time, .Words, .Quote}) {
		x := s
		x.mode = m
		if m != s.mode {
			x.mode2 = 30 if m == .Time else 25
		}
		mode_link(b, mode_word(m), x, s.mode == m)
	}
	w(b, `</span><i class="sep"></i><span class="group stack">`)
	for m in ([?]engine.Mode{.Time, .Words, .Quote}) {
		here := m == s.mode
		w(b, `<span class="set"`)
		if !here do w(b, ` inert`)
		w(b, `>`)
		x := s
		x.mode = m
		if m == .Quote {
			x.quotes = QUOTE_ALL
			mode_link(b, "all", x, here && s.quotes == QUOTE_ALL)
			for name, g in engine.QUOTE_GROUP_NAMES {
				x.quotes = 1 << u32(g)
				mode_link(b, name, x, here && s.quotes == x.quotes)
			}
		} else {
			options := [?]i32{15, 30, 60, 120} if m == .Time else [?]i32{10, 25, 50, 100}
			for n in options {
				x.mode2 = n
				mode_link(b, int_label(n), x, here && s.mode2 == n)
			}
		}
		w(b, `</span>`)
	}
	w(b, `</span><i class="sep"></i><a class="lang" href="/languages?`)
	q := strings.builder_make(context.temp_allocator)
	setup_query(&q, s)
	engine.html_attr(b, strings.to_string(q))
	w(b, `">`)
	engine.html_text(b, engine.quote_language(s.language) if s.mode == .Quote else s.language)
	w(b, `</a></nav>`)

	w(b, `<section id="stage" class="stage"><div id="timer" class="timer" aria-hidden="true"></div>`)
	w(b, `<div class="lines-clip"><div id="lines" class="lines"><canvas id="words"></canvas><div id="caret" class="caret idle" aria-hidden="true"></div></div></div>`)
	w(b, `<textarea id="typer-input" class="typer-input" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" aria-label="typing input"></textarea>`)
	w(b, `<div id="result" hidden></div><div id="after" class="after" hidden><button type="button" data-next>next test <kbd>tab</kbd></button>`)
	w(b, `<button type="button" class="quiet" data-repeat>repeat <kbd>esc</kbd></button><a data-result-link hidden>saved result</a></div>`)
	w(b, `<p id="words-text" class="sr-only" aria-live="polite"></p></section>`)
	w(b, `<p id="hint" class="hint"><kbd>tab</kbd> restart · twice for `)
	w(b, "a new quote" if s.mode == .Quote else "new words")
	w(b, `</p>`)

	w(b, `<script id="typer-config" type="application/json">{"mode":`)
	strings.write_int(b, int(s.mode))
	w(b, `,"mode2":`)
	strings.write_int(b, int(s.mode2))
	w(b, `,"punctuation":`)
	w(b, "true" if s.punctuation else "false")
	w(b, `,"numbers":`)
	w(b, "true" if s.numbers else "false")
	w(b, `,"language":`)
	engine.json_string(b, s.language)
	w(b, `,"pack":`)
	engine.json_string(b, strings.concatenate({"/packs/", s.language, ".bin"}, context.temp_allocator))
	w(b, `,"caretMs":`)
	strings.write_int(b, CARET_MS[p.caret])
	if s.mode == .Quote {
		w(b, `,"quoteGroups":`)
		strings.write_int(b, int(s.quotes))
		w(b, `,"quoteLanguage":`)
		engine.json_string(b, engine.quote_language(s.language))
		w(b, `,"queue":{"seed":"`)
		strings.write_u64(b, t.seed, 16)
		w(b, `","from":`)
		strings.write_int(b, t.from)
		w(b, `},"quotes":`)
		write_quotes_json(b, t.quotes)
	}
	w(b, `}</script>`)
	page_end(b)
}

render_result_page :: proc(b: ^strings.Builder, p: Page, v: engine.Result_View, attempts: []Stored) {
	page_start(b, p, "result · typer", "result")
	engine.render_result(b, v)
	if len(attempts) > 1 {
		w(b, `<h2>`)
		engine.html_text(b, v.typist)
		w(b, ` on this quote</h2>`)
		results_table(b, attempts, false, 0, v.id)
	}
	w(b, `<p class="after"><a class="button" href="/">play</a><a class="button quiet" href="/leaderboard">leaderboard</a></p>`)
	page_end(b)
}

@(private)
setup_label :: proc(b: ^strings.Builder, s: Stored) {
	engine.mode_label(b, s.setup)
	if s.setup.mode == .Quote && s.qgroup >= 0 && s.qgroup < engine.QUOTE_GROUPS {
		w(b, " ")
		w(b, engine.QUOTE_GROUP_NAMES[s.qgroup])
	}
	w(b, " ")
	engine.html_text(b, s.setup.language)
	if .Punctuation in s.setup.flags do w(b, " punctuation")
	if .Numbers in s.setup.flags do w(b, " numbers")
}

// ranked: leaderboard columns (rank, typist); highlight: the visitor's user id;
// current: a result id to mark.
@(private)
results_table :: proc(b: ^strings.Builder, rows: []Stored, ranked: bool, highlight: i64, current: i64) {
	w(b, `<table><thead><tr>`)
	if ranked {
		w(b, `<th class="num">#</th><th>typist</th>`)
	} else {
		w(b, `<th>date</th><th>test</th>`)
	}
	w(b, `<th class="num">wpm</th><th class="num">acc</th><th class="num">raw</th><th class="num">consistency</th>`)
	if ranked do w(b, `<th>date</th>`)
	w(b, `</tr></thead><tbody>`)
	for s, i in rows {
		w(b, `<tr`)
		classes := strings.builder_make(context.temp_allocator)
		if !s.valid do w(&classes, "invalid ")
		if highlight != 0 && s.user_id == highlight do w(&classes, "you ")
		if s.id == current do w(&classes, "current ")
		if strings.builder_len(classes) > 0 {
			w(b, ` class="`)
			w(b, strings.trim_space(strings.to_string(classes)))
			w(b, `"`)
		}
		w(b, `>`)
		if ranked {
			w(b, `<td class="num rank`)
			if i < 3 do w(b, ` top`)
			w(b, `">`)
			strings.write_int(b, i + 1)
			w(b, `</td><td><a href="/results/`)
			strings.write_i64(b, s.id)
			w(b, `">`)
			engine.html_text(b, s.user_name)
			w(b, `</a></td>`)
		} else {
			w(b, `<td class="date"><a href="/results/`)
			strings.write_i64(b, s.id)
			w(b, `">`)
			write_date(b, s.created_at)
			w(b, `</a></td><td>`)
			setup_label(b, s)
			if !s.valid do w(b, `<span class="tag">invalid</span>`)
			w(b, `</td>`)
		}
		w(b, `<td class="num strong">`)
		engine.write_fixed(b, s.wpm, 2)
		w(b, `</td><td class="num">`)
		engine.write_fixed(b, s.acc, 2)
		w(b, `%</td><td class="num">`)
		engine.write_fixed(b, s.raw, 2)
		w(b, `</td><td class="num">`)
		engine.write_fixed(b, s.cons, 2)
		w(b, `%</td>`)
		if ranked {
			w(b, `<td class="date">`)
			write_date(b, s.created_at)
			w(b, `</td>`)
		}
		w(b, `</tr>`)
	}
	w(b, `</tbody></table>`)
}

render_history_page :: proc(b: ^strings.Builder, p: Page, bests: []Stored, recent: []Stored) {
	page_start(b, p, "history · typer", "history")
	if !p.known {
		w(b, `<p class="empty">Your history starts with your first finished test. It stays with this browser; the key link on your name's page brings it to another one.</p>`)
		page_end(b)
		return
	}
	w(b, `<h2>personal bests</h2>`)
	if len(bests) == 0 {
		w(b, `<p class="empty">No valid results yet.</p>`)
	} else {
		w(b, `<div class="bests">`)
		for s in bests {
			w(b, `<a class="best" href="/results/`)
			strings.write_i64(b, s.id)
			w(b, `"><span class="what">`)
			setup_label(b, s)
			w(b, `</span><span class="wpm">`)
			engine.write_fixed(b, s.wpm, 0)
			w(b, `<small>wpm</small></span><span class="more">`)
			engine.write_fixed(b, s.acc, 0)
			w(b, `% acc · `)
			write_day(b, s.created_at)
			w(b, `</span></a>`)
		}
		w(b, `</div>`)
	}
	w(b, `<h2>recent</h2>`)
	if len(recent) == 0 {
		w(b, `<p class="empty">Nothing typed yet.</p>`)
	} else {
		results_table(b, recent, false, 0, 0)
	}
	page_end(b)
}

BOARD_TIMES := [?]i32{15, 30, 60, 120}
BOARD_WORDS := [?]i32{10, 25, 50, 100}

@(private)
board_href :: proc(b: ^strings.Builder, board: Board) {
	q := strings.builder_make(context.temp_allocator)
	w(&q, "/leaderboard?mode=")
	w(&q, mode_word(board.mode))
	if board.mode == .Quote {
		w(&q, "&q=")
		strings.write_int(&q, 1 << uint(board.qgroup))
	} else {
		w(&q, "&n=")
		strings.write_int(&q, int(board.mode2))
	}
	if board.language != "english" {
		w(&q, "&lang=")
		w(&q, url_encode(board.language))
	}
	engine.html_attr(b, strings.to_string(q))
}

@(private)
board_link :: proc(b: ^strings.Builder, label: string, board: Board, on: bool) {
	w(b, `<a href="`)
	board_href(b, board)
	w(b, `"`)
	if on do w(b, ` class="on" aria-current="true"`)
	w(b, `>`)
	engine.html_text(b, label)
	w(b, `</a>`)
}

render_leaderboard_page :: proc(b: ^strings.Builder, p: Page, board: Board, rows: []Stored) {
	page_start(b, p, "leaderboard · typer", "leaderboard")
	// The same bar as the test page: a mode, then its options in one
	// stacked slot so the bar keeps its width.
	quote_lang := engine.quote_language(board.language)
	w(b, `<nav class="bar" aria-label="leaderboard"><span class="group">`)
	board_link(b, "time", Board{mode = .Time, mode2 = 30, language = board.language}, board.mode == .Time)
	board_link(b, "words", Board{mode = .Words, mode2 = 25, language = board.language}, board.mode == .Words)
	board_link(b, "quote", Board{mode = .Quote, qgroup = 1, language = quote_lang}, board.mode == .Quote)
	w(b, `</span><i class="sep"></i><span class="group stack">`)
	for m in ([?]engine.Mode{.Time, .Words, .Quote}) {
		here := m == board.mode
		w(b, `<span class="set"`)
		if !here do w(b, ` inert`)
		w(b, `>`)
		if m == .Quote {
			for name, g in engine.QUOTE_GROUP_NAMES {
				board_link(b, name, Board{mode = .Quote, qgroup = i32(g), language = quote_lang}, here && board.qgroup == i32(g))
			}
		} else {
			for n in (BOARD_TIMES if m == .Time else BOARD_WORDS) {
				board_link(b, int_label(n), Board{mode = m, mode2 = n, language = board.language}, here && board.mode2 == n)
			}
		}
		w(b, `</span>`)
	}
	w(b, `</span><i class="sep"></i><a class="lang" href="/languages?board=1&amp;mode=`)
	w(b, mode_word(board.mode))
	w(b, `">`)
	engine.html_text(b, board.language)
	w(b, `</a></nav>`)
	if len(rows) == 0 {
		w(b, `<p class="empty">Nobody has a valid result here yet. <a href="/">Be the first.</a></p>`)
	} else {
		results_table(b, rows, true, p.user.id if p.known else 0, 0)
	}
	w(b, `<p class="note">Each typist's best valid result, without punctuation or numbers.</p>`)
	page_end(b)
}

render_me_page :: proc(b: ^strings.Builder, p: Page, token: string, message: string, problem: bool) {
	page_start(b, p, "you · typer", "me")
	if !p.known {
		w(b, `<p class="empty">You become a typist the moment you finish a test: this browser keeps your name and history, no account needed.</p>`)
		page_end(b)
		return
	}
	setting_start(b, "name", "How you appear on the leaderboard.")
	w(b, `<form method="post" action="/me/name" class="row"><input name="name" maxlength="24" required value="`)
	engine.html_attr(b, p.user.name)
	w(b, `" aria-label="name"><button>save</button></form>`)
	if message != "" && problem {
		w(b, `<p class="problem">`)
		engine.html_text(b, message)
		w(b, `</p>`)
	}
	setting_end(b)
	setting_start(b, "key link", "Open it on another device to type as you there. Anyone with it can, so keep it to yourself.")
	w(b, `<div class="row"><input class="key" readonly value="`)
	engine.html_attr(b, key_link(token))
	w(b, `" aria-label="key link"><button type="button" class="quiet" data-copy>copy</button></div>`)
	setting_end(b)
	setting_start(b, "this browser", "Forgetting only signs this browser out; your results stay, and the key link brings them back.")
	w(b, `<form method="post" action="/me/forget"><button class="quiet danger">forget me here</button></form>`)
	setting_end(b)
	if message != "" && !problem {
		toast(b, message)
	}
	page_end(b)
}

render_settings_page :: proc(b: ^strings.Builder, p: Page) {
	page_start(b, p, "settings · typer", "settings")
	w(b, `<form class="settings" method="post" action="/settings" data-autosave>`)
	setting_start(b, "smooth motion", "How the caret and the lines glide. Off moves them in the same frame as the letter.")
	segmented(b, "caret", "smooth motion", {{"off", "off"}, {"fast", "fast"}, {"medium", "medium"}, {"slow", "slow"}}, CARET_NAMES[p.caret])
	setting_end(b)
	setting_start(b, "theme", "Light or dark, or whatever your system uses. The ◐ button up top flips it too.")
	segmented(b, "theme", "theme", {{"system", "system"}, {"light", "light"}, {"dark", "dark"}}, p.theme if p.theme != "" else "system")
	setting_end(b)
	w(b, `<noscript><p><button>save</button></p></noscript><p class="toast" role="status" data-saved hidden>saved</p></form>`)
	page_end(b)
}

render_languages_page :: proc(b: ^strings.Builder, p: Page, s: Test_Setup, board: bool, languages: []string) {
	page_start(b, p, "languages · typer", "languages")
	w(b, `<div class="find"><input type="search" placeholder="find a language" aria-label="find a language" autocomplete="off" data-filter=".languages li" autofocus></div><ul class="languages">`)
	for l in languages {
		w(b, `<li><a href="`)
		if board {
			x := Board{mode = s.mode, mode2 = 30 if s.mode == .Time else 25, language = l}
			board_href(b, x)
		} else {
			x := s
			x.language = l
			setup_href(b, x)
		}
		w(b, `"`)
		if l == s.language do w(b, ` class="on"`)
		w(b, `>`)
		engine.html_text(b, l)
		w(b, `</a></li>`)
	}
	w(b, `</ul><p class="empty" data-none hidden>No language by that name.</p>`)
	page_end(b)
}

// UTC "YYYY-MM-DD" from unix milliseconds.
write_day :: proc(b: ^strings.Builder, unix_ms: i64) {
	t := time.unix(unix_ms / 1000, 0)
	y, mon, d := time.date(t)
	strings.write_int(b, y)
	strings.write_byte(b, '-')
	if int(mon) < 10 do strings.write_byte(b, '0')
	strings.write_int(b, int(mon))
	strings.write_byte(b, '-')
	if d < 10 do strings.write_byte(b, '0')
	strings.write_int(b, d)
}

// UTC "YYYY-MM-DD HH:MM" from unix milliseconds.
write_date :: proc(b: ^strings.Builder, unix_ms: i64) {
	t := time.unix(unix_ms / 1000, 0)
	y, mon, d := time.date(t)
	h, min, _ := time.clock(t)
	pad :: proc(b: ^strings.Builder, v: int) {
		if v < 10 do strings.write_byte(b, '0')
		strings.write_int(b, v)
	}
	strings.write_int(b, y)
	strings.write_byte(b, '-')
	pad(b, int(mon))
	strings.write_byte(b, '-')
	pad(b, d)
	strings.write_byte(b, ' ')
	pad(b, h)
	strings.write_byte(b, ':')
	pad(b, min)
}
