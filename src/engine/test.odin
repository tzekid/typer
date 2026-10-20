package engine

import "core:slice"

// The typing test state machine. The platform feeds raw events in arrival
// order (key down/up, inserted characters, browser-applied deletions, time up);
// the engine decides navigation, correctness and when the test ends, and
// records an event log equivalent to upstream Monkeytype's. Every statistic is
// derived from that log afterwards (stats.odin).

Mode :: enum u8 {
	Time,
	Words,
	Quote,
	Zen,
	Custom,
}

Stop_On_Error :: enum u8 {
	Off,
	Letter,
	Word,
}

Confidence :: enum u8 {
	Off,
	On,
	Max,
}

Difficulty :: enum u8 {
	Normal,
	Expert,
	Master,
}

Config :: struct {
	mode:          Mode,
	mode2:         i32, // seconds for time mode, word count for words mode (0 = infinite)
	punctuation:   bool,
	numbers:       bool,
	stop_on_error: Stop_On_Error,
	confidence:    Confidence,
	difficulty:    Difficulty,
	freedom_mode:  bool,
	strict_space:  bool,
	quick_end:     bool,
	language:      Language_Rules,
}

// Finishing: the test has ended but key releases still count (upstream's
// finish() awaits its fade-out before force-releasing held keys).
Phase :: enum u8 {
	Ready,
	Active,
	Finishing,
	Finished,
}

Event_Kind :: enum u8 {
	Key_Down,
	Key_Up,
	Timer_Start,
	Timer_End,
	Input,
}

Input_Type :: enum u8 {
	None,
	Insert_Text,
	Insert_Composition_Text,
	Delete_Content_Backward,
	Delete_Word_Backward,
}

Event_Flag :: enum u8 {
	Correct,
	Commits_Word,
	Last_Word,
	Input_Stopped,
	Automatic,
	Estimated,
	Cleared_Next_Word,
}
Event_Flags :: bit_set[Event_Flag;u8]

Event :: struct {
	ms:         f64, // platform clock
	t:          f64, // ms since test start, set when the log is finalized
	word_index: i32,
	char_index: i32,
	input_len:  i32, // input length of word_index after the event (what the textarea holds)
	data:       rune,
	code:       u16,
	kind:       Event_Kind,
	input_type: Input_Type,
	flags:      Event_Flags,
}

Delete_Kind :: enum u8 {
	Char,
	Word,
}

// remaining = -1 for a delete: the browser removed the sentinel because the
// word input was already empty, i.e. the user is backspacing into the
// previous word.
DELETE_INTO_PREVIOUS :: i32(-1)

@(private)
Word_Slot :: struct {
	off, len, cap: i32,
}

@(private)
Pressed :: struct {
	code: u16,
	ms:   f64,
}

Test :: struct {
	cfg:                 Config,
	phase:               Phase,
	active:              i32,
	bailed_out:          bool,
	all_generated:       bool,
	first_rendered_word: i32, // words before this have scrolled off and can't be backspaced into

	target:              [dynamic]rune,
	target_off:          [dynamic]i32,
	input_pool:          [dynamic]rune,
	slots:               [dynamic]Word_Slot,

	keydowns:            [dynamic]Event,
	keyups:              [dynamic]Event,
	timers:              [dynamic]Event,
	inputs:              [dynamic]Event,
	pressed:             [dynamic]Pressed,
	no_code_index:       u16,

	start_ms:            f64,
	end_ms:              f64,

	log:                 [dynamic]Event, // finalized at finish: sorted, with t
}

test_reset :: proc(t: ^Test, cfg: Config) {
	t.cfg = cfg
	t.phase = .Ready
	t.active = 0
	t.bailed_out = false
	t.all_generated = false
	t.first_rendered_word = 0
	clear(&t.target)
	clear(&t.target_off)
	append(&t.target_off, 0)
	clear(&t.input_pool)
	clear(&t.slots)
	clear(&t.keydowns)
	clear(&t.keyups)
	clear(&t.timers)
	clear(&t.inputs)
	clear(&t.pressed)
	t.no_code_index = 0
	t.start_ms = 0
	t.end_ms = 0
	clear(&t.log)
}

test_destroy :: proc(t: ^Test) {
	delete(t.target)
	delete(t.target_off)
	delete(t.input_pool)
	delete(t.slots)
	delete(t.keydowns)
	delete(t.keyups)
	delete(t.timers)
	delete(t.inputs)
	delete(t.pressed)
	delete(t.log)
}

// commit: ' ' or '\n' after the word, 0 for the final word of a finite test.
test_add_word :: proc(t: ^Test, text: string, commit: rune) {
	for r in text {
		append(&t.target, r)
	}
	if commit != 0 {
		append(&t.target, commit)
	}
	append(&t.target_off, i32(len(t.target)))
	append(&t.slots, Word_Slot{off = -1})
}

word_count :: proc(t: ^Test) -> i32 {
	return i32(len(t.target_off) - 1)
}

// Target word including its commit character (upstream textWithCommit).
target_word :: proc(t: ^Test, i: i32) -> []rune {
	if i < 0 || i >= word_count(t) {
		return nil
	}
	return t.target[t.target_off[i]:t.target_off[i + 1]]
}

word_input :: proc(t: ^Test, i: i32) -> []rune {
	if i < 0 || i >= i32(len(t.slots)) {
		return nil
	}
	s := t.slots[i]
	if s.off < 0 {
		return nil
	}
	return t.input_pool[s.off:s.off + s.len]
}

@(private)
ensure_slot :: proc(t: ^Test, i: i32) {
	for i32(len(t.slots)) <= i {
		append(&t.slots, Word_Slot{off = -1})
	}
	if t.slots[i].off >= 0 {
		return
	}
	cap := i32(len(target_word(t, i))) + 24
	if t.cfg.mode == .Zen {
		cap = 32
	}
	off := i32(len(t.input_pool))
	resize(&t.input_pool, len(t.input_pool) + int(cap))
	t.slots[i] = Word_Slot{off = off, len = 0, cap = cap}
}

@(private)
input_append :: proc(t: ^Test, i: i32, r: rune) {
	ensure_slot(t, i)
	s := &t.slots[i]
	if s.len < s.cap {
		t.input_pool[s.off + s.len] = r
		s.len += 1
	}
}

@(private)
input_truncate :: proc(t: ^Test, i: i32, n: i32) {
	ensure_slot(t, i)
	s := &t.slots[i]
	s.len = clamp(n, 0, s.len)
}

@(private)
runes_equal :: proc "contextless" (a, b: []rune) -> bool {
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

// input + data == target, without building the concatenation.
@(private)
typed_completes :: proc "contextless" (input: []rune, data: rune, target: []rune) -> bool {
	return len(input) + 1 == len(target) && runes_equal(input, target[:len(input)]) && target[len(input)] == data
}

@(private)
is_commit_char :: proc "contextless" (data: rune) -> bool {
	return is_space(data) || data == '\n'
}

@(private)
is_char_correct :: proc(t: ^Test, data: rune, input: []rune, target: []rune) -> bool {
	if t.cfg.mode == .Zen {
		return true
	}
	if len(input) >= len(target) {
		return false
	}
	return target[len(input)] == data
}

@(private)
should_go_to_next_word :: proc(t: ^Test, data: rune, input: []rune, target: []rune) -> bool {
	if !is_commit_char(data) {
		return false
	}
	if t.cfg.mode == .Zen {
		return true
	}
	if len(input) == 0 && (t.cfg.strict_space || t.cfg.difficulty != .Normal) {
		return false
	}
	correct := typed_completes(input, data, target)
	if t.cfg.stop_on_error != .Off && !correct {
		return false
	}
	return true
}

@(private)
words_have_newline :: proc(t: ^Test) -> bool {
	for r in t.target {
		if r == '\n' {
			return true
		}
	}
	return false
}

// onBeforeInsertText: false means the browser insertion must be prevented.
// The layout-dependent overflow check lives with the layout code.
test_before_insert :: proc(t: ^Test, data: rune) -> bool {
	if t.phase >= .Finishing {
		return false
	}
	if data == '\n' && t.cfg.mode != .Zen && !words_have_newline(t) {
		return false
	}
	input := word_input(t, t.active)
	target := target_word(t, t.active)
	d := normalize_data(data, input, target, t.cfg.language)
	allow_first_separator := t.cfg.strict_space || t.cfg.difficulty != .Normal
	if is_space(d) && len(input) == 0 && !allow_first_separator {
		return false
	}
	limit := len(target) + 20
	if t.cfg.mode == .Zen {
		limit = 30
	}
	if len(input) >= limit && !should_go_to_next_word(t, d, input, target) {
		return false
	}
	return true
}

@(private)
start :: proc(t: ^Test, ms: f64) {
	t.phase = .Active
	t.start_ms = ms
	append(&t.timers, Event{ms = ms, kind = .Timer_Start})
}

// onInsertText for one character (multi-character data is split by the caller,
// each piece passing test_before_insert first, like upstream's emulateInsertText).
test_insert :: proc(t: ^Test, ms: f64, data: rune) {
	if t.phase >= .Finishing {
		return
	}
	ensure_slot(t, t.active)
	wi := t.active
	input := word_input(t, wi)
	target := target_word(t, wi)
	d := normalize_data(data, input, target, t.cfg.language)

	if t.phase == .Ready {
		start(t, ms)
	}

	correct := is_char_correct(t, d, input, target)
	remove_last := t.cfg.stop_on_error == .Letter && !correct
	going := !remove_last && should_go_to_next_word(t, d, input, target)
	completes := typed_completes(input, d, target)
	len_before := i32(len(input))

	if !remove_last {
		input_append(t, wi, d)
	}

	ev := Event {
		ms         = ms,
		kind       = .Input,
		input_type = .Insert_Text,
		word_index = wi,
		char_index = len_before,
		input_len  = i32(len(word_input(t, wi))),
		data       = d,
	}
	if correct do ev.flags += {.Correct}
	if remove_last do ev.flags += {.Input_Stopped}
	if going do ev.flags += {.Commits_Word}
	if wi == word_count(t) - 1 do ev.flags += {.Last_Word}
	append(&t.inputs, ev)

	if going {
		go_to_next_word(t)
	}

	all_typed := wi >= word_count(t) - 1
	quick_end := t.cfg.quick_end && i32(len(target)) == len_before + 1 && t.cfg.stop_on_error == .Off
	if all_typed && t.all_generated && (completes || quick_end || going) {
		finish(t, ms)
	}
}

@(private)
go_to_next_word :: proc(t: ^Test) {
	if t.active < word_count(t) - 1 || t.cfg.mode == .Zen {
		t.active += 1
		ensure_slot(t, t.active)
		t.slots[t.active].len = 0
	}
}

// onBeforeDelete: false means the browser deletion must be prevented.
test_before_delete :: proc(t: ^Test) -> bool {
	if t.phase != .Active {
		return false
	}
	input_empty := len(word_input(t, t.active)) == 0
	if input_empty {
		if t.active == 0 {
			return false
		}
		if t.active - 1 < t.first_rendered_word {
			return false
		}
	}
	if t.cfg.freedom_mode {
		return true
	}
	prev_correct := t.active > 0 && runes_equal(word_input(t, t.active - 1), target_word(t, t.active - 1))
	if t.cfg.confidence == .On && input_empty && !prev_correct {
		return false
	}
	if t.cfg.confidence == .Max {
		return false
	}
	if input_empty && prev_correct {
		return false
	}
	return true
}

// onDelete. remaining: the word input length the browser left behind, or
// DELETE_INTO_PREVIOUS when it removed the sentinel of an empty word.
test_delete :: proc(t: ^Test, ms: f64, kind: Delete_Kind, remaining: i32) {
	if t.phase != .Active {
		return
	}
	input_type := Input_Type.Delete_Content_Backward if kind == .Char else .Delete_Word_Backward
	before := i32(len(word_input(t, t.active)))

	if remaining == DELETE_INTO_PREVIOUS {
		if t.active > 0 {
			t.active -= 1
			if kind == .Word {
				input_truncate(t, t.active, 0)
			} else {
				prev := word_input(t, t.active)
				if len(prev) > 0 && (prev[len(prev) - 1] == ' ' || prev[len(prev) - 1] == '\n') {
					input_truncate(t, t.active, i32(len(prev) - 1))
				}
			}
		} else {
			input_truncate(t, 0, 0)
		}
		after := i32(len(word_input(t, t.active)))
		ev := Event {
			ms         = ms,
			kind       = .Input,
			input_type = input_type,
			word_index = t.active,
			char_index = after,
			input_len  = after,
		}
		if before != 0 do ev.flags += {.Cleared_Next_Word}
		append(&t.inputs, ev)
		return
	}

	input_truncate(t, t.active, remaining)
	append(&t.inputs, Event {
		ms         = ms,
		kind       = .Input,
		input_type = input_type,
		word_index = t.active,
		char_index = before,
		input_len  = i32(len(word_input(t, t.active))),
	})
}

@(private)
pressed_index :: proc(t: ^Test, code: u16) -> int {
	for p, i in t.pressed {
		if p.code == code {
			return i
		}
	}
	return -1
}

test_key_down :: proc(t: ^Test, ms: f64, code: u16, repeat: bool) {
	if repeat || !key_is_tracked(code) {
		return
	}
	if i := pressed_index(t, code); i >= 0 {
		ordered_remove(&t.pressed, i)
		append(&t.keyups, Event{ms = ms, kind = .Key_Up, code = code})
	}
	if t.phase >= .Finishing {
		return
	}
	key := code
	if code == KEY_NO_CODE {
		key = KEY_NO_CODE_BASE + t.no_code_index
		t.no_code_index += 1
	}
	append(&t.pressed, Pressed{code = key, ms = ms})
	append(&t.keydowns, Event{ms = ms, kind = .Key_Down, code = key})
}

test_key_up :: proc(t: ^Test, ms: f64, code: u16) {
	key_up(t, ms, code, {})
}

@(private)
key_up :: proc(t: ^Test, ms: f64, code: u16, flags: Event_Flags) {
	if t.phase == .Finished {
		return
	}
	key := code
	if code < KEY_NO_CODE_BASE {
		if !key_is_tracked(code) {
			return
		}
		if code == KEY_NO_CODE {
			if t.no_code_index == 0 {
				return
			}
			key = KEY_NO_CODE_BASE + t.no_code_index - 1
			if pressed_index(t, key) < 0 {
				return
			}
			t.no_code_index -= 1
		}
	}
	i := pressed_index(t, key)
	if i < 0 {
		return
	}
	ordered_remove(&t.pressed, i)
	append(&t.keyups, Event{ms = ms, kind = .Key_Up, code = key, flags = flags})
}

// The time limit was reached (time mode), observed by the platform at ms.
test_time_up :: proc(t: ^Test, ms: f64) {
	if t.phase == .Active {
		finish(t, ms)
	}
}

@(private)
finish :: proc(t: ^Test, ms: f64) {
	t.phase = .Finishing
	t.end_ms = ms
	append(&t.timers, Event{ms = ms, kind = .Timer_End})
}

// Closes a finished test: estimates keyups for keys still held, drops what
// came too early or too late, and builds the sorted log stats read from.
test_finalize :: proc(t: ^Test) {
	if t.phase != .Finishing {
		return
	}
	force_release_all_keys(t)
	cleanup(t)
	finalize_log(t)
	t.phase = .Finished
}

// Keys still held when the test ends get an estimated keyup at
// keydown + the average key duration (upstream forceReleaseAllKeys, including
// its pairing of each code's first keyup with that code's last keydown).
@(private)
force_release_all_keys :: proc(t: ^Test) {
	durations := make([dynamic]f64, 0, len(t.keyups), context.temp_allocator)
	last_down := make(map[u16]f64, 64, context.temp_allocator)
	for down in t.keydowns {
		last_down[down.code] = down.ms
	}
	for up in t.keyups {
		down, found := last_down[up.code]
		if !found {
			continue
		}
		delete_key(&last_down, up.code)
		if d := up.ms - down; d > 0 {
			append(&durations, d)
		}
	}
	avg := 80.0 if len(durations) == 0 else round_to_2(mean(durations[:]))

	held := make([]Pressed, len(t.pressed), context.temp_allocator)
	copy(held, t.pressed[:])
	for p in held {
		key_up(t, p.ms + avg, p.code, {.Estimated})
	}
}

// cleanupData: keep only the last pre-start keydown, drop pre-start keyups and
// everything typed after the end.
@(private)
cleanup :: proc(t: ^Test) {
	last_pre := -1
	for e, i in t.keydowns {
		if e.ms < t.start_ms {
			last_pre = i
		} else {
			break
		}
	}
	n := 0
	for e, i in t.keydowns {
		if e.ms >= t.start_ms || i == last_pre {
			t.keydowns[n] = e
			n += 1
		}
	}
	resize(&t.keydowns, n)

	n = 0
	for e in t.keyups {
		if e.ms >= t.start_ms {
			t.keyups[n] = e
			n += 1
		}
	}
	resize(&t.keyups, n)

	end := t.end_ms
	n = 0
	for e in t.inputs {
		if e.ms <= end {
			t.inputs[n] = e
			n += 1
		}
	}
	resize(&t.inputs, n)

	post_end := make([dynamic]u16, 0, 8, context.temp_allocator)
	for e in t.keydowns {
		if e.ms > end {
			append(&post_end, e.code)
		}
	}
	n = 0
	for e in t.keydowns {
		if e.ms <= end {
			t.keydowns[n] = e
			n += 1
		}
	}
	resize(&t.keydowns, n)

	n = 0
	for e in t.keyups {
		keep := e.ms <= end
		if !keep {
			keep = true
			for c in post_end {
				if c == e.code {
					keep = false
					break
				}
			}
		}
		if keep {
			t.keyups[n] = e
			n += 1
		}
	}
	resize(&t.keyups, n)
}

@(private)
sort_rank :: proc "contextless" (k: Event_Kind) -> int {
	#partial switch k {
	case .Key_Up:
		return 0
	case .Key_Down:
		return 1
	case .Timer_Start, .Timer_End:
		return 3
	}
	return 2
}

// getAllTestEvents: merge in upstream's array order, stable sort by time with
// its tie ranks, and express times relative to the timer start.
@(private)
finalize_log :: proc(t: ^Test) {
	clear(&t.log)
	append(&t.log, ..t.keydowns[:])
	append(&t.log, ..t.keyups[:])
	append(&t.log, ..t.timers[:])
	append(&t.log, ..t.inputs[:])
	slice.stable_sort_by(t.log[:], proc(a, b: Event) -> bool {
		if a.ms != b.ms {
			return a.ms < b.ms
		}
		return sort_rank(a.kind) < sort_rank(b.kind)
	})
	for &e in t.log {
		e.t = round_to_2(e.ms - t.start_ms)
	}
}
