package engine

import "core:math"

// Statistics derived from a finalized test log. Each procedure mirrors the
// upstream function of the same purpose in frontend/src/ts/test/events/stats.ts
// (named in the comment), including its edge cases, so results match exactly.

Char_Counts :: struct {
	all_correct:  i32,
	correct_word: i32,
	incorrect:    i32,
	extra:        i32,
	missed:       i32,
}

Result :: struct {
	wpm:                f64,
	raw_wpm:            f64,
	acc:                f64,
	char_stats:         [4]i32, // correct word chars, incorrect, extra, missed
	char_total:         i32,
	test_duration:      f64, // seconds
	last_key_to_end:    f64,
	start_to_first_key: f64,
	afk_duration:       i32,
	consistency:        f64,
	wpm_consistency:    f64,
	key_consistency:    f64,
	key_overlap:        f64,
	chart_wpm:          []f64,
	chart_burst:        []f64,
	chart_err:          []f64,
	key_spacing:        []f64,
	key_duration:       []f64,
}

// isTimedTest
is_timed_test :: proc(t: ^Test) -> bool {
	return t.cfg.mode == .Time || (t.cfg.mode == .Words && t.cfg.mode2 == 0)
}

@(private)
trims_trailing_afk :: proc(t: ^Test) -> bool {
	return t.cfg.mode == .Zen || t.bailed_out
}

// getTimerBoundaries: an ideal 1 s grid up to the end, plus a fractional tail
// for non-timed tests whose remainder rounds to >= .5 s.
timer_boundaries :: proc(t: ^Test, allocator := context.temp_allocator) -> []f64 {
	end_ms: f64
	have_end := false
	for e in t.log {
		if e.kind == .Timer_End {
			end_ms = e.t
			have_end = true
		}
	}
	if !have_end {
		return nil
	}
	tick_count := math.floor(end_ms / 1000)
	if trims_trailing_afk(t) {
		lkte := raw_last_keypress_to_end_ms(t)
		if lkte < 7000 {
			end_ms -= lkte
			tick_count = min(tick_count, math.floor(end_ms / 1000))
		}
	}
	out := make([dynamic]f64, 0, int(tick_count) + 1, allocator)
	for i := 1.0; i <= tick_count; i += 1 {
		append(&out, i * 1000)
	}
	if !is_timed_test(t) && js_round(math.mod(round_to_2(end_ms / 1000), 1)) >= 0.5 {
		append(&out, end_ms)
	}
	return out[:]
}

// getStartToFirstKeypressMs
start_to_first_keypress_ms :: proc(t: ^Test) -> f64 {
	if t.cfg.mode == .Zen {
		return 0
	}
	first, start: f64
	have_first, have_start := false, false
	for e in t.log {
		if have_first && have_start {
			break
		}
		if !have_first && e.kind == .Key_Down {
			first = e.t
			have_first = true
		}
		if !have_start && e.kind == .Timer_Start {
			start = e.t
			have_start = true
		}
	}
	if !have_first || !have_start {
		return 0
	}
	calc := first - start
	return 0 if calc < 0 else round_to_2(calc)
}

// getRawLastKeypressToEndMs
raw_last_keypress_to_end_ms :: proc(t: ^Test) -> f64 {
	last, end: f64
	have_last, have_end := false, false
	#reverse for e in t.log {
		if have_last && have_end {
			break
		}
		if !have_last && e.kind == .Key_Down {
			last = e.t
			have_last = true
		}
		if !have_end && e.kind == .Timer_End {
			end = e.t
			have_end = true
		}
	}
	if !have_last || !have_end {
		return 0
	}
	calc := end - last
	return 0 if calc < 0 else round_to_2(calc)
}

// getLastKeypressToEndMs
last_keypress_to_end_ms :: proc(t: ^Test) -> f64 {
	if t.cfg.mode == .Zen {
		return 0
	}
	return raw_last_keypress_to_end_ms(t)
}

@(private)
Interval_Predicate :: enum u8 {
	Insert_Text,
	Insert_Text_Incorrect,
	Keydown_Or_Input,
}

@(private)
matches :: proc "contextless" (e: Event, p: Interval_Predicate) -> bool {
	switch p {
	case .Insert_Text:
		return e.kind == .Input && e.input_type == .Insert_Text
	case .Insert_Text_Incorrect:
		return e.kind == .Input && e.input_type == .Insert_Text && .Correct not_in e.flags
	case .Keydown_Or_Input:
		return e.kind == .Key_Down || e.kind == .Input
	}
	return false
}

// countPerInterval
@(private)
count_per_interval :: proc(t: ^Test, boundaries: []f64, p: Interval_Predicate, allocator := context.temp_allocator) -> []f64 {
	counts := make([]f64, len(boundaries), allocator)
	ei := 0
	for b, bi in boundaries {
		count := 0
		for ei < len(t.log) {
			e := t.log[ei]
			if e.t > b {
				break
			}
			if matches(e, p) {
				count += 1
			}
			ei += 1
		}
		counts[bi] = f64(count)
	}
	return counts
}

// getBurstHistory
burst_history :: proc(t: ^Test, boundaries: []f64, allocator := context.temp_allocator) -> []f64 {
	counts := count_per_interval(t, boundaries, .Insert_Text, allocator)
	prev := 0.0
	for b, i in boundaries {
		seconds := (b - prev) / 1000
		prev = b
		counts[i] = js_round(calc_wpm(counts[i], seconds))
	}
	return counts
}

// getErrorCountHistory
error_count_history :: proc(t: ^Test, boundaries: []f64, allocator := context.temp_allocator) -> []f64 {
	return count_per_interval(t, boundaries, .Insert_Text_Incorrect, allocator)
}

// getAfkDuration
afk_duration :: proc(t: ^Test, boundaries: []f64) -> i32 {
	counts := count_per_interval(t, boundaries, .Keydown_Or_Input)
	n: i32
	for c in counts {
		if c == 0 {
			n += 1
		}
	}
	return n
}

// getTestDurationMs
test_duration_ms :: proc(t: ^Test) -> f64 {
	end: f64
	have_end := false
	#reverse for e in t.log {
		if e.kind == .Timer_End {
			end = e.t
			have_end = true
			break
		}
	}
	if !have_end {
		return 0
	}
	if trims_trailing_afk(t) {
		lkte := raw_last_keypress_to_end_ms(t)
		if lkte < 7000 {
			end -= lkte
		}
	}
	if t.cfg.mode != .Custom {
		end = round_to_2(end / 1000) * 1000
	}
	return end
}

// getAccuracy: every inserted character counts, including ones fixed later.
accuracy :: proc(t: ^Test) -> f64 {
	correct, incorrect := 0, 0
	for e in t.log {
		if e.kind != .Input || e.input_type == .Delete_Content_Backward || e.input_type == .Delete_Word_Backward {
			continue
		}
		if .Correct in e.flags {
			correct += 1
		} else {
			incorrect += 1
		}
	}
	total := correct + incorrect
	return 0 if total == 0 else f64(correct) / f64(total) * 100
}

// getKeypressSpacing
key_spacing :: proc(t: ^Test, allocator := context.temp_allocator) -> []f64 {
	out := make([dynamic]f64, 0, len(t.log), allocator)
	last: f64
	have_last := false
	for e in t.log {
		if e.kind != .Key_Down {
			continue
		}
		if have_last {
			append(&out, e.t - last)
		}
		last = max(0, e.t)
		have_last = true
	}
	return out[:]
}

// getKeypressOverlap
key_overlap :: proc(t: ^Test) -> f64 {
	down := make([dynamic]u16, 0, 16, context.temp_allocator)
	overlap := 0.0
	last_start: f64
	have_start := false
	for e in t.log {
		#partial switch e.kind {
		case .Key_Down:
			found := false
			for c in down {
				if c == e.code {
					found = true
					break
				}
			}
			if !found {
				append(&down, e.code)
			}
			if !have_start && len(down) > 1 {
				last_start = e.t
				have_start = true
			}
		case .Key_Up:
			for c, i in down {
				if c == e.code {
					unordered_remove(&down, i)
					break
				}
			}
			if have_start && len(down) == 1 {
				overlap += e.t - last_start
				have_start = false
			}
		}
	}
	return round_to_2(overlap)
}

// getKeypressDurations: one slot per keydown, 0 when no keyup followed.
key_durations :: proc(t: ^Test, allocator := context.temp_allocator) -> []f64 {
	Down :: struct {
		code:  u16,
		t:     f64,
		index: int,
	}
	open := make([dynamic]Down, 0, 16, context.temp_allocator)
	out := make([dynamic]f64, 0, len(t.log), allocator)
	for e in t.log {
		#partial switch e.kind {
		case .Key_Down:
			replaced := false
			for &d in open {
				if d.code == e.code {
					d = Down{e.code, e.t, len(out)}
					replaced = true
					break
				}
			}
			if !replaced {
				append(&open, Down{e.code, e.t, len(out)})
			}
			append(&out, 0)
		case .Key_Up:
			for d, i in open {
				if d.code == e.code {
					out[d.index] = e.t - d.t
					ordered_remove(&open, i)
					break
				}
			}
		}
	}
	return out[:]
}

// countChars from utils/strings.ts, over code points.
count_chars :: proc(input: []rune, target: []rune, credit_partial: bool) -> Char_Counts {
	c: Char_Counts
	word_correct := runes_equal(input, target)
	partially_correct := len(input) <= len(target) && runes_equal(input, target[:len(input)])
	input_has_space := false
	for r in input {
		if r == ' ' {
			input_has_space = true
			break
		}
	}
	n := max(len(input), len(target))
	for i in 0 ..< n {
		have_in, have_tg := i < len(input), i < len(target)
		ic := input[i] if have_in else 0
		tc := target[i] if have_tg else 0
		if have_in == have_tg && ic == tc {
			if tc == ' ' && !word_correct {
				c.extra += 1
			} else {
				c.all_correct += 1
			}
			if word_correct || (credit_partial && partially_correct) {
				c.correct_word += 1
			}
		} else if !have_in {
			if !credit_partial {
				c.missed += 1
			}
		} else if !have_tg || (tc == ' ' && ic != ' ' && !input_has_space) {
			c.extra += 1
		} else {
			c.incorrect += 1
		}
	}
	return c
}

// Per-word replay of the log (upstream groups events by word index in order of
// first appearance and reads each word's input from its last snapshot).
@(private)
Word_Replay :: struct {
	order:       [dynamic]i32,
	seen:        [dynamic]bool,
	input_off:   [dynamic]i32,
	input_len:   [dynamic]i32,
	pool:        [dynamic]rune,
	last_is_sp:  [dynamic]bool, // last event of the word is an insertText of " "
	dirty:       [dynamic]bool,
}

@(private)
replay_init :: proc(r: ^Word_Replay, t: ^Test) {
	n := int(word_count(t))
	for e in t.log {
		if e.kind == .Input {
			n = max(n, int(e.word_index) + 1)
		}
	}
	a := context.temp_allocator
	r.order = make([dynamic]i32, 0, n, a)
	r.seen = make([dynamic]bool, n, a)
	r.input_off = make([dynamic]i32, n, a)
	r.input_len = make([dynamic]i32, n, a)
	r.last_is_sp = make([dynamic]bool, n, a)
	r.dirty = make([dynamic]bool, n, a)
	r.pool = make([dynamic]rune, 0, 64, a)
	for i in 0 ..< n {
		cap := len(target_word(t, i32(i))) + 64
		r.input_off[i] = i32(len(r.pool))
		resize(&r.pool, len(r.pool) + cap)
	}
}

// applyInputEvent
@(private)
replay_apply :: proc(r: ^Word_Replay, e: Event) {
	if e.kind != .Input {
		return
	}
	w := e.word_index
	if !r.seen[w] {
		r.seen[w] = true
		append(&r.order, w)
	}
	r.dirty[w] = true
	r.last_is_sp[w] = e.input_type == .Insert_Text && e.data == ' '
	switch e.input_type {
	case .Insert_Text:
		if .Input_Stopped in e.flags {
			return
		}
		if e.data == ' ' && .Last_Word in e.flags && .Commits_Word in e.flags && .Correct not_in e.flags {
			return
		}
		r.pool[r.input_off[w] + r.input_len[w]] = e.data
		r.input_len[w] += 1
	case .Insert_Composition_Text:
		if .Input_Stopped in e.flags {
			return
		}
		r.pool[r.input_off[w] + r.input_len[w]] = e.data
		r.input_len[w] += 1
	case .Delete_Content_Backward, .Delete_Word_Backward:
		r.input_len[w] = clamp(e.input_len, 0, r.input_len[w])
	case .None:
	}
}

@(private)
replay_input :: proc(r: ^Word_Replay, w: i32) -> []rune {
	return r.pool[r.input_off[w]:r.input_off[w] + r.input_len[w]]
}

// inferActiveWordIndex
@(private)
replay_active_word :: proc(r: ^Word_Replay) -> i32 {
	max_w := i32(-1)
	for w in r.order {
		if r.input_len[w] > 0 && w > max_w {
			max_w = w
		}
	}
	if max_w < 0 {
		return 0
	}
	if r.last_is_sp[max_w] {
		return max_w + 1
	}
	return max_w
}

// countCharsForWordIndex
@(private)
count_word :: proc(t: ^Test, r: ^Word_Replay, w: i32, last_word, count_partial: bool) -> Char_Counts {
	input := replay_input(r, w)
	norm := make([]rune, len(input), context.temp_allocator)
	for c, i in input {
		norm[i] = ' ' if is_space(c) else c
	}
	target := target_word(t, w)
	if target == nil {
		target = norm
	}
	return count_chars(norm, target, last_word && count_partial)
}

// getChars
chars :: proc(t: ^Test, count_partial_last_word := false) -> Char_Counts {
	r: Word_Replay
	replay_init(&r, t)
	for e in t.log {
		replay_apply(&r, e)
	}
	last := replay_active_word(&r)
	count_partial := is_timed_test(t) || t.bailed_out || count_partial_last_word
	acc: Char_Counts
	for w in r.order {
		is_last := w == last
		c := count_word(t, &r, w, is_last, count_partial)
		acc.all_correct += c.all_correct
		acc.correct_word += c.correct_word
		acc.incorrect += c.incorrect
		acc.extra += c.extra
		acc.missed += c.missed
		if is_last {
			break
		}
	}
	return acc
}

@(private)
History_Kind :: enum u8 {
	Wpm,
	Raw,
}

// getWpmHistory / getRawHistory: cumulative speed at each boundary, counting
// the active word with partial credit.
history :: proc(t: ^Test, boundaries: []f64, kind: History_Kind, allocator := context.temp_allocator) -> []f64 {
	out := make([]f64, len(boundaries), allocator)
	if len(boundaries) == 0 {
		return out
	}
	r: Word_Replay
	replay_init(&r, t)
	n := len(r.seen)
	if_last := make([]i32, n, context.temp_allocator)
	if_not_last := make([]i32, n, context.temp_allocator)
	ei := 0
	for b, bi in boundaries {
		for ei < len(t.log) {
			e := t.log[ei]
			if e.t > b {
				break
			}
			replay_apply(&r, e)
			ei += 1
		}
		for w in r.order {
			if !r.dirty[w] {
				continue
			}
			r.dirty[w] = false
			nl := count_word(t, &r, w, false, true)
			l := count_word(t, &r, w, true, true)
			if kind == .Wpm {
				if_not_last[w] = nl.correct_word
				if_last[w] = l.correct_word
			} else {
				if_not_last[w] = nl.all_correct + nl.extra + nl.incorrect
				if_last[w] = l.all_correct + l.extra + l.incorrect
			}
		}
		last := replay_active_word(&r)
		sum: i32
		for w in r.order {
			if w == last {
				sum += if_last[w]
				break
			}
			sum += if_not_last[w]
		}
		out[bi] = js_round(calc_wpm(f64(sum), b / 1000))
	}
	return out
}

// buildCompletedEvent (the statistics part).
build_result :: proc(t: ^Test, allocator := context.allocator) -> Result {
	res: Result
	c := chars(t)
	duration := test_duration_ms(t) / 1000
	boundaries := timer_boundaries(t)

	burst := burst_history(t, boundaries, allocator)
	res.consistency = consistency_of(burst)

	spacing := key_spacing(t, allocator)
	key_cons := spacing
	if len(spacing) > 0 {
		key_cons = spacing[:len(spacing) - 1]
	}
	res.key_consistency = consistency_of(key_cons)

	wpm_hist := history(t, boundaries, .Wpm, allocator)
	wc := round_to_2(kogasa(std_dev(wpm_hist) / mean(wpm_hist)))
	res.wpm_consistency = 0 if is_nan(wc) else wc

	res.chart_wpm = wpm_hist
	res.chart_burst = burst
	res.chart_err = error_count_history(t, boundaries, allocator)
	res.key_spacing = spacing
	res.key_duration = key_durations(t, allocator)
	res.key_overlap = key_overlap(t)

	res.wpm = round_to_2(calc_wpm(f64(c.correct_word), duration))
	res.raw_wpm = round_to_2(calc_wpm(f64(c.all_correct + c.incorrect + c.extra), duration))
	res.char_stats = {c.correct_word, c.incorrect, c.extra, c.missed}
	res.char_total = c.all_correct + c.incorrect + c.extra
	res.acc = round_to_2(accuracy(t))
	res.test_duration = duration
	res.last_key_to_end = last_keypress_to_end_ms(t)
	res.start_to_first_key = start_to_first_keypress_ms(t)
	res.afk_duration = afk_duration(t, boundaries)
	return res
}
