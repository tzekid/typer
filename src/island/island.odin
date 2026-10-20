package island

import "base:runtime"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

import engine "../engine"

// The typing surface, compiled to wasm32-freestanding. island.js forwards
// browser events here and executes the draw commands this produces; all test
// logic, layout and rendering decisions live on this side.

foreign import env "env"

@(default_calling_convention = "c")
foreign env {
	js_measure :: proc(ptr: [^]u8, len: u32) -> f32 ---
	js_result :: proc(html: [^]u8, html_len: u32, record: [^]u8, record_len: u32) ---
}

ENGLISH :: #load("../../build/packs/lang/english.bin")

Color :: enum u32 {
	Bg,
	Main,
	Caret,
	Sub,
	Sub_Alt,
	Text,
	Error,
	Error_Extra,
}

Cmd_Op :: enum u32 {
	Clear     = 1,
	Rect      = 2,
	Text      = 3,
	Text_Clip = 4, // text clipped to x in [a, b)
}

// Set on text ops whose bytes live in the word text pool, which stays put
// until mt_text_gen() changes: island.js may cache the decoded string.
CMD_CACHEABLE :: u32(0x80)

// 32 bytes; island.js reads these through typed array views.
Cmd :: struct {
	op:    Cmd_Op,
	color: Color,
	x, y:  f32,
	a, b:  f32,
	ptr:   u32,
	len:   u32,
}

Word_Layout :: struct {
	text_off: u32, // display text (no commit char) in `texts`
	text_len: u32,
	pw_off:   u32, // prefix widths in `prefix`, runes + 1 entries
	runes:    u32,
	width:    f32,
	extra_w:  f32, // width of typed characters beyond the word
	x:        f32,
	line:     i32,
	drawn_w:  f32, // width covered when last drawn, cleared on redraw
	newline:  bool, // committed with Enter: shown as ↵ and ends the line
}

LINES_VISIBLE :: 3
WORDS_AHEAD :: 100
// Key releases right after the end still count, like upstream's fade-out.
FINISH_GRACE_MS :: 150

State :: struct {
	test:          engine.Test,
	gen:           engine.Generator,
	setup:         engine.Setup,
	pack_bytes:    []u8,
	pack:          engine.Pack,
	raw:           [dynamic]engine.Raw_Event,
	reported:      bool,

	width:         f32,
	font_px:       f32,
	line_h:        f32,
	space_w:       f32,

	texts:         [dynamic]u8,
	inbox:         [dynamic]u8, // strings handed in by island.js
	quote_text:    [dynamic]u8,
	quote_source:  [dynamic]u8,
	quote_lang:    [dynamic]u8,
	quote_group:   i32,
	prefix:        [dynamic]f32,
	words:         [dynamic]Word_Layout,
	top_line:      i32,
	full_redraw:   bool,
	dirty:         [dynamic]i32,
	text_gen:      u32,
	texts_at:      uintptr,
	timer_value:   i64,
	timer_text:    [32]u8,
	timer_len:     int,
	timer_changed: bool,
	caret:         [2]f32,

	cmds:          [dynamic]Cmd,
	next_wake:     f64,
	input_utf8:    [dynamic]u8,
	html:          strings.Builder,
	record:        []u8,
}

@(private)
s: State

// Per-frame text bytes. Fixed so pointers handed to draw commands stay valid
// for the whole frame.
@(private)
scratch: struct {
	buf: [16 * 1024]u8,
	len: int,
}

@(private)
scratch_put :: proc(rs: []rune) -> (ptr: u32, n: u32) {
	start := scratch.len
	for r in rs {
		b, k := utf8.encode_rune(r)
		if scratch.len + k > len(scratch.buf) {
			break
		}
		copy(scratch.buf[scratch.len:], b[:k])
		scratch.len += k
	}
	return u32(uintptr(&scratch.buf[start])), u32(scratch.len - start)
}

@(private)
scratch_put_string :: proc(str: string) -> (ptr: u32, n: u32) {
	start := scratch.len
	k := min(len(str), len(scratch.buf) - scratch.len)
	copy(scratch.buf[scratch.len:], str[:k])
	scratch.len += k
	return u32(uintptr(&scratch.buf[start])), u32(k)
}

// Freestanding targets default to the nil allocator: use the wasm page
// allocator for long-lived data and an arena, reset after every call, for
// temporaries.
@(private)
temp_arena: runtime.Arena

// Built by hand rather than from default_context, which would also pull in
// a random generator nothing here uses.
@(private)
ctx :: proc "contextless" () -> runtime.Context {
	c: runtime.Context
	context = c
	c.allocator = runtime.default_wasm_allocator()
	c.assertion_failure_proc = runtime.default_assertion_failure_proc
	context = c
	if temp_arena.backing_allocator.procedure == nil {
		_ = runtime.arena_init(&temp_arena, 1 << 20, c.allocator)
	}
	c.temp_allocator = runtime.arena_allocator(&temp_arena)
	return c
}

// A buffer island.js writes strings into before calling mt_set_quote.
@(export)
mt_inbox :: proc "c" (n: u32) -> [^]u8 {
	context = ctx()
	resize(&s.inbox, int(n))
	return raw_data(s.inbox)
}

// The next quote, from the inbox: text, then source, then quote language.
@(export)
mt_set_quote :: proc "c" (text_len, source_len, lang_len: u32, id: u32, group: i32) {
	context = ctx()
	t := s.inbox[:text_len]
	src := s.inbox[text_len:text_len + source_len]
	lang := s.inbox[text_len + source_len:text_len + source_len + lang_len]
	clear(&s.quote_text)
	append(&s.quote_text, ..t)
	clear(&s.quote_source)
	append(&s.quote_source, ..src)
	clear(&s.quote_lang)
	append(&s.quote_lang, ..lang)
	s.quote_group = group
	s.setup.mode2 = i32(id)
}

@(export)
mt_has_tabs :: proc "c" () -> b32 {
	for r in s.test.target {
		if r == '\t' {
			return true
		}
	}
	return false
}

// Repaint everything, e.g. after the theme changed.
@(export)
mt_redraw :: proc "c" () {
	s.full_redraw = true
}

@(export)
mt_alloc :: proc "c" (n: u32) -> [^]u8 {
	context = ctx()
	return raw_data(make([]u8, int(n)))
}

@(export)
mt_init :: proc "c" (font_px, width: f32) {
	context = ctx()
	s.font_px = font_px
	s.line_h = math.round(font_px * 1.6)
	s.width = width
	s.html = strings.builder_make()
}

// Takes ownership of a buffer filled through mt_alloc.
@(export)
mt_set_pack :: proc "c" (ptr: [^]u8, n: u32) -> b32 {
	context = ctx()
	bytes := ptr[:n]
	p, ok := engine.pack_view(bytes)
	if !ok {
		return false
	}
	if s.pack_bytes != nil {
		delete(s.pack_bytes)
	}
	s.pack_bytes = bytes
	s.pack = p
	return true
}

@(export)
mt_use_english :: proc "c" () -> b32 {
	context = ctx()
	buf := make([]u8, len(ENGLISH))
	copy(buf, ENGLISH)
	return mt_set_pack(raw_data(buf), u32(len(buf)))
}

@(export)
mt_key_count :: proc "c" () -> u32 {
	return u32(len(engine.TRACKED_KEYS))
}

@(export)
mt_key_name_ptr :: proc "c" (i: u32) -> [^]u8 {
	return raw_data(engine.TRACKED_KEYS[i])
}

@(export)
mt_key_name_len :: proc "c" (i: u32) -> u32 {
	return u32(len(engine.TRACKED_KEYS[i]))
}

@(export)
mt_phase :: proc "c" () -> u32 {
	return u32(s.test.phase)
}

// (Re)start a test. flags: bit 0 punctuation, bit 1 numbers, bit 2 the same
// words again (seed and quote as last time).
@(export)
mt_start :: proc "c" (mode, mode2: i32, flags: u32, seed_lo, seed_hi: u32) {
	context = ctx()
	quote := engine.Mode(mode) == .Quote
	s.setup = engine.Setup {
		mode     = engine.Mode(mode),
		mode2    = s.setup.mode2 if quote else mode2,
		seed     = u64(seed_lo) | u64(seed_hi) << 32,
		language = string(s.quote_lang[:]) if quote else s.pack.list.name,
	}
	if flags & 1 != 0 do s.setup.flags += {.Punctuation}
	if flags & 2 != 0 do s.setup.flags += {.Numbers}
	if flags & 4 != 0 do s.setup.flags += {.Repeated}
	cfg := engine.Config {
		mode        = s.setup.mode,
		mode2       = mode2,
		punctuation = .Punctuation in s.setup.flags,
		numbers     = .Numbers in s.setup.flags,
	}
	engine.test_reset(&s.test, cfg)
	engine.generator_init(&s.gen, s.pack.list, s.setup.seed, cfg.punctuation, cfg.numbers)
	clear(&s.raw)
	clear(&s.texts)
	reserve(&s.texts, 64 * 1024) // keeps word text addresses stable for island.js's cache
	clear(&s.prefix)
	clear(&s.words)
	s.top_line = 0
	s.timer_value = -2 // forces the timer text to be cleared
	s.reported = false
	s.full_redraw = true
	clear(&s.dirty)
	if quote {
		engine.test_add_quote(&s.test, string(s.quote_text[:]))
		for i in 0 ..< engine.word_count(&s.test) {
			add_target_layout(i)
		}
		note_texts_moved()
	} else {
		top_up_words()
	}
	layout_from(0)
	free_all(context.temp_allocator)
}

@(private)
word_bound :: proc() -> int {
	if s.setup.mode == .Words && s.setup.mode2 > 0 {
		return int(s.setup.mode2)
	}
	return max(int)
}

// Keep WORDS_AHEAD words generated past the active one.
@(private)
top_up_words :: proc() {
	if s.setup.mode == .Quote {
		return
	}
	bound := word_bound()
	for {
		n := int(engine.word_count(&s.test))
		if n >= bound || n >= int(s.test.active) + WORDS_AHEAD {
			break
		}
		w := engine.generator_next(&s.gen, n, bound)
		last := n == bound - 1
		engine.test_add_word(&s.test, w, 0 if last else ' ')
		add_layout(w, false)
	}
	s.test.all_generated = s.setup.mode == .Words && int(engine.word_count(&s.test)) >= bound
	note_texts_moved()
}

@(private)
note_texts_moved :: proc() {
	if at := uintptr(raw_data(s.texts)); at != s.texts_at {
		s.texts_at = at
		s.text_gen += 1
	}
}

// Layout for a word already in the test: tabs show as →, an Enter commit as ↵.
@(private)
add_target_layout :: proc(i: i32) {
	target := engine.target_word(&s.test, i)
	newline := len(target) > 0 && target[len(target) - 1] == '\n'
	body := target
	if len(target) > 0 && (target[len(target) - 1] == ' ' || newline) {
		body = target[:len(target) - 1]
	}
	b := strings.builder_make(context.temp_allocator)
	for r in body {
		strings.write_rune(&b, '→' if r == '\t' else r)
	}
	if newline {
		strings.write_rune(&b, '↵')
	}
	add_layout(strings.to_string(b), newline)
}

@(private)
add_layout :: proc(w: string, newline: bool) {
	l := Word_Layout {
		text_off = u32(len(s.texts)),
		text_len = u32(len(w)),
		pw_off   = u32(len(s.prefix)),
		runes    = u32(utf8.rune_count_in_string(w)),
		newline  = newline,
	}
	append(&s.texts, w)
	append(&s.prefix, 0)
	text := s.texts[l.text_off:]
	i := 0
	for _ in 0 ..< l.runes {
		_, n := utf8.decode_rune(text[i:])
		i += n
		append(&s.prefix, js_measure(raw_data(text), u32(i)))
	}
	l.width = s.prefix[l.pw_off + l.runes]
	append(&s.words, l)
}

@(private)
measure_space :: proc() {
	sp := " "
	s.space_w = js_measure(raw_data(sp), 1)
}

// Line breaking from word i on; earlier words keep their places.
@(private)
layout_from :: proc(from: int) {
	if s.space_w == 0 {
		measure_space()
	}
	x: f32
	line: i32
	if from > 0 && from <= len(s.words) {
		p := s.words[from - 1]
		x = p.x + p.width + p.extra_w + s.space_w
		line = p.line
		if p.newline {
			x = 0
			line += 1
		}
	}
	for i in from ..< len(s.words) {
		w := &s.words[i]
		ww := w.width + w.extra_w
		if x > 0 && x + ww > s.width {
			line += 1
			x = 0
		}
		if (w.x != x || w.line != line) && line < s.top_line + LINES_VISIBLE {
			s.full_redraw = true
		}
		w.x = x
		w.line = line
		x += ww + s.space_w
		if w.newline {
			x = 0
			line += 1
		}
	}
	scroll()
}

@(private)
scroll :: proc() {
	a := int(s.test.active)
	if a >= len(s.words) {
		return
	}
	line := s.words[a].line
	if line >= s.top_line + LINES_VISIBLE - 1 {
		s.top_line = line - (LINES_VISIBLE - 2)
		s.full_redraw = true
	}
	for w, i in s.words {
		if w.line >= s.top_line {
			s.test.first_rendered_word = i32(i)
			break
		}
	}
}

// Typed characters past the word's own letters (excluding a commit char).
@(private)
extras :: proc(i: int) -> []rune {
	input := engine.word_input(&s.test, i32(i))
	n := int(s.words[i].runes)
	end := len(input)
	if end > 0 && i < int(s.test.active) && (input[end - 1] == ' ' || input[end - 1] == '\n') {
		end -= 1
	}
	if end <= n {
		return nil
	}
	return input[n:end]
}

@(private)
encode :: proc(buf: ^[dynamic]u8, rs: []rune) -> (off, n: u32) {
	off = u32(len(buf))
	for r in rs {
		b, k := utf8.encode_rune(r)
		append(buf, ..b[:k])
	}
	return off, u32(len(buf)) - off
}

@(private)
measure_runes :: proc(rs: []rune) -> f32 {
	scratch.len = 0
	ptr, n := scratch_put(rs)
	return js_measure(([^]u8)(uintptr(ptr)), n)
}

// After the active word's input changed: re-measure its extra letters and
// re-flow the rest of the text if its width changed.
@(private)
after_input :: proc(word: int) {
	append(&s.dirty, i32(word))
	if word < len(s.words) {
		w := &s.words[word]
		ex := extras(word)
		new_w: f32
		if len(ex) > 0 {
			new_w = measure_runes(ex)
		}
		if new_w != w.extra_w {
			w.extra_w = new_w
			layout_from(word)
		}
	}
	top_up_words()
	if len(s.words) > 0 {
		layout_from(max(int(s.test.active) - 1, 0))
	}
}

@(private)
deadline :: proc() -> f64 {
	return s.test.start_ms + f64(s.setup.mode2) * 1000
}

// Time mode ends exactly at start + N seconds; anything at or after it is late.
@(private)
check_deadline :: proc(ms: f64) {
	if s.test.phase == .Active && s.setup.mode == .Time && ms >= deadline() {
		apply(engine.Raw_Event{ms = deadline(), kind = .Time_Up})
	}
}

@(private)
apply :: proc(e: engine.Raw_Event) {
	append(&s.raw, e)
	engine.test_apply(&s.test, e)
	if s.test.phase == .Finished && !s.reported {
		report()
	}
}

@(private)
report :: proc() {
	s.reported = true
	res := engine.build_result(&s.test, context.temp_allocator)
	strings.builder_reset(&s.html)
	view := engine.Result_View {
		result  = res,
		setup   = s.setup,
		invalid = engine.invalid_reason(&s.test, s.setup, res),
	}
	if s.setup.mode == .Quote {
		view.quote_group = s.quote_group
		view.quote_source = string(s.quote_source[:])
	}
	engine.render_result(&s.html, view)
	if s.record != nil {
		delete(s.record)
	}
	s.record = engine.record_encode(s.setup, &s.test, s.raw[:])
	html := strings.to_string(s.html)
	js_result(raw_data(html), u32(len(html)), raw_data(s.record), u32(len(s.record)))
}

@(export)
mt_key_down :: proc "c" (ms: f64, code: u32, repeat: b32) {
	context = ctx()
	defer free_all(context.temp_allocator)
	check_deadline(ms)
	if s.test.phase == .Finished {
		return
	}
	apply(engine.Raw_Event{ms = ms, kind = .Key_Down_Repeat if repeat else .Key_Down, code = u16(code)})
}

@(export)
mt_key_up :: proc "c" (ms: f64, code: u32) {
	context = ctx()
	defer free_all(context.temp_allocator)
	check_deadline(ms)
	if s.test.phase == .Finished {
		return
	}
	apply(engine.Raw_Event{ms = ms, kind = .Key_Up, code = u16(code)})
}

// Also blocks characters that would push the active word past the line end.
@(export)
mt_before_insert :: proc "c" (cp: u32) -> b32 {
	context = ctx()
	defer free_all(context.temp_allocator)
	if !engine.test_before_insert(&s.test, rune(cp)) {
		return false
	}
	a := int(s.test.active)
	if a < len(s.words) && !engine.is_space(rune(cp)) && cp != '\n' {
		w := s.words[a]
		input := engine.word_input(&s.test, i32(a))
		if len(input) >= int(w.runes) {
			rs := make([]rune, len(input) - int(w.runes) + 1, context.temp_allocator)
			copy(rs, input[w.runes:])
			rs[len(rs) - 1] = rune(cp)
			if w.x + w.width + measure_runes(rs) > s.width {
				return false
			}
		}
	}
	return true
}

// Returns true when the textarea must be re-synced instead of letting the
// browser insert the character itself: the word was committed, or the input
// did not simply gain this character.
@(export)
mt_insert :: proc "c" (ms: f64, cp: u32) -> b32 {
	context = ctx()
	defer free_all(context.temp_allocator)
	check_deadline(ms)
	if s.test.phase >= .Finishing {
		return true
	}
	word := s.test.active
	before := len(engine.word_input(&s.test, word))
	apply(engine.Raw_Event{ms = ms, kind = .Insert, arg = i32(cp)})
	after_input(int(word))
	after := engine.word_input(&s.test, word)
	return !(s.test.active == word && len(after) == before + 1 && after[before] == rune(cp))
}

@(export)
mt_before_delete :: proc "c" () -> b32 {
	context = ctx()
	return b32(engine.test_before_delete(&s.test))
}

@(export)
mt_delete :: proc "c" (ms: f64, word: b32, remaining: i32) {
	context = ctx()
	defer free_all(context.temp_allocator)
	check_deadline(ms)
	if s.test.phase >= .Finishing {
		return
	}
	apply(engine.Raw_Event{ms = ms, kind = .Delete_Word if word else .Delete_Char, arg = remaining})
	after_input(int(s.test.active))
}

// The test's words as plain text: the canvas has no text, so island.js puts
// this in a visually hidden element for screen readers (and tests).
@(export)
mt_words_ptr :: proc "c" () -> [^]u8 {
	context = ctx()
	clear(&s.input_utf8)
	for w, i in s.words {
		if i > 0 do append(&s.input_utf8, ' ')
		append(&s.input_utf8, ..s.texts[w.text_off:w.text_off + w.text_len])
	}
	return raw_data(s.input_utf8)
}

// The active word's input as UTF-8, for keeping the textarea in sync.
@(export)
mt_input_ptr :: proc "c" () -> [^]u8 {
	context = ctx()
	clear(&s.input_utf8)
	encode(&s.input_utf8, engine.word_input(&s.test, s.test.active))
	return raw_data(s.input_utf8)
}

@(export)
mt_input_len :: proc "c" () -> u32 {
	return u32(len(s.input_utf8))
}

@(export)
mt_resize :: proc "c" (width: f32) {
	context = ctx()
	defer free_all(context.temp_allocator)
	s.width = width
	s.full_redraw = true
	layout_from(0)
}

@(export)
mt_height :: proc "c" () -> f32 {
	return s.line_h * (LINES_VISIBLE + 1)
}

@(export)
mt_cmds :: proc "c" () -> [^]Cmd {
	return raw_data(s.cmds)
}

// Milliseconds until mt_frame wants to run again; < 0 for never.
@(export)
mt_next_wake :: proc "c" () -> f64 {
	return s.next_wake
}

@(private)
push :: proc(c: Cmd) {
	append(&s.cmds, c)
}

@(private)
text_cmd :: proc(color: Color, x, y: f32, ptr, n: u32, clip_a: f32 = 0, clip_b: f32 = 0, cacheable := false) {
	op := Cmd_Op.Text if clip_a == clip_b else .Text_Clip
	if cacheable {
		op = Cmd_Op(u32(op) | CMD_CACHEABLE)
	}
	push(Cmd{op = op, color = color, x = x, y = y, a = clip_a, b = clip_b, ptr = ptr, len = n})
}

@(export)
mt_text_gen :: proc "c" () -> u32 {
	return s.text_gen
}

// Caret position in canvas coordinates; island.js moves a DOM caret there so
// the compositor animates it and the canvas is never repainted for it.
@(export)
mt_caret_x :: proc "c" () -> f32 {
	return s.caret.x
}

@(export)
mt_caret_y :: proc "c" () -> f32 {
	return s.caret.y
}

@(export)
mt_line_height :: proc "c" () -> f32 {
	return s.line_h
}

// Draw commands for what changed since the last frame: everything after a
// start, resize, re-flow or scroll; otherwise just the words whose input
// changed and the timer when its value did.
@(export)
mt_frame :: proc "c" (now: f64) -> u32 {
	context = ctx()
	defer free_all(context.temp_allocator)
	check_deadline(now)
	clear(&s.cmds)
	scratch.len = 0
	s.next_wake = -1

	if s.test.phase == .Finishing {
		if now >= s.test.end_ms + FINISH_GRACE_MS {
			apply(engine.Raw_Event{ms = now, kind = .Finalize})
		} else {
			s.next_wake = s.test.end_ms + FINISH_GRACE_MS - now
		}
	}
	if s.test.phase == .Finished {
		return 0
	}

	active := int(s.test.active)
	texts := u32(uintptr(raw_data(s.texts)))
	if s.full_redraw {
		push(Cmd{op = .Clear, color = .Bg})
		for &w, i in s.words {
			if w.line < s.top_line - 1 {
				continue
			}
			if w.line >= s.top_line + LINES_VISIBLE {
				break
			}
			draw_word(i, &w, active, texts)
		}
		s.full_redraw = false
	} else {
		for d, k in s.dirty {
			seen := false
			for e in s.dirty[:k] {
				seen ||= e == d
			}
			if seen || int(d) >= len(s.words) {
				continue
			}
			w := &s.words[d]
			if w.line < s.top_line || w.line >= s.top_line + LINES_VISIBLE {
				continue
			}
			push(Cmd{op = .Rect, color = .Bg, x = w.x - 2, y = line_top(w.line), a = max(w.drawn_w, w.width + w.extra_w) + 4, b = s.line_h})
			draw_word(int(d), w, active, texts)
		}
	}
	clear(&s.dirty)
	draw_timer(now)
	place_caret()
	return u32(len(s.cmds))
}

@(private)
// Row 0 holds the line above the visible ones: island.js clips it away, and
// it is what slides out of view when the text scrolls up a line.
line_top :: proc(line: i32) -> f32 {
	return f32(line - s.top_line + 1) * s.line_h
}

@(private)
draw_timer :: proc(now: f64) {
	value: i64 = -1
	if s.test.phase == .Active {
		if s.setup.mode == .Time {
			left := deadline() - now
			value = i64(math.ceil(max(left, 0) / 1000))
			wake := math.mod(left, 1000)
			s.next_wake = wake if s.next_wake < 0 else min(s.next_wake, wake)
		} else {
			value = i64(s.test.active) << 32 | i64(engine.word_count(&s.test))
		}
	}
	if value == s.timer_value {
		return
	}
	s.timer_value = value
	s.timer_changed = true
	b := strings.builder_from_bytes(s.timer_text[:])
	if value >= 0 && s.setup.mode == .Time {
		strings.write_i64(&b, value)
	} else if value >= 0 {
		strings.write_int(&b, int(s.test.active))
		strings.write_byte(&b, '/')
		strings.write_int(&b, int(engine.word_count(&s.test)))
	}
	s.timer_len = strings.builder_len(b)
}

// The timer is page text, not canvas: island.js sets it when it changed.
@(export)
mt_timer_changed :: proc "c" () -> b32 {
	changed := s.timer_changed
	s.timer_changed = false
	return b32(changed)
}

@(export)
mt_timer_ptr :: proc "c" () -> [^]u8 {
	return raw_data(s.timer_text[:])
}

@(export)
mt_timer_len :: proc "c" () -> u32 {
	return u32(s.timer_len)
}

@(export)
mt_top_line :: proc "c" () -> i32 {
	return s.top_line
}

// Line of the active word, so island.js can tell a move along a line from a
// jump to another one.
@(export)
mt_caret_line :: proc "c" () -> i32 {
	a := int(s.test.active)
	if a >= len(s.words) {
		return -1
	}
	return s.words[a].line
}

@(private)
draw_word :: proc(i: int, w: ^Word_Layout, active: int, texts: u32) {
	y := line_top(w.line) + s.line_h / 2
	w.drawn_w = w.width + w.extra_w
	text_cmd(.Sub, w.x, y, texts + w.text_off, w.text_len, cacheable = true)
	if i > active {
		return
	}
	input := engine.word_input(&s.test, i32(i))
	target := engine.target_word(&s.test, i32(i))
	typed := min(len(input), int(w.runes))
	pw := s.prefix[w.pw_off:]
	// runs of correct / incorrect letters, drawn clipped over the base text
	j := 0
	for j < typed {
		ok := input[j] == target[j]
		k := j + 1
		for k < typed && (input[k] == target[k]) == ok {
			k += 1
		}
		text_cmd(.Text if ok else .Error, w.x, y, texts + w.text_off, w.text_len, w.x + pw[j], w.x + pw[k], cacheable = true)
		j = k
	}
	if ex := extras(i); len(ex) > 0 {
		ptr, n := scratch_put(ex)
		text_cmd(.Error_Extra, w.x + w.width, y, ptr, n)
	}
	if i < active && !runes_equal(input, target) {
		push(Cmd{op = .Rect, color = .Error, x = w.x, y = y + s.font_px * 0.62, a = w.width + w.extra_w, b = max(2, s.font_px * 0.06)})
	}
}

@(private)
runes_equal :: proc(a, b: []rune) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

@(private)
place_caret :: proc() {
	a := int(s.test.active)
	if a >= len(s.words) {
		return
	}
	w := s.words[a]
	input := engine.word_input(&s.test, i32(a))
	x := w.x + s.prefix[w.pw_off + u32(min(len(input), int(w.runes)))]
	if len(input) > int(w.runes) {
		x = w.x + w.width + w.extra_w
	}
	s.caret = {x, line_top(w.line)}
}
