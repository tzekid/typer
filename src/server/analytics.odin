package server

import "core:math"
import "core:encoding/endian"
import "core:strings"
import "core:unicode"

import engine "../engine"

// Versioned, sparse counts. Times are hundredths of a millisecond, matching
// the finalized engine log. Scoring and validity are never derived here.
ANALYTICS_VERSION :: 2
ANALYTICS_HEADER :: 56

Key_Analysis :: struct {
	key: rune,
	attempts, errors, timed: u32,
	interval: u64,
}

Pair_Analysis :: struct {
	first, second: rune,
	count: u32,
	interval: u64,
}

Word_Analysis :: struct {
	word: string,
	attempts, misses, tests, missed_tests: u32,
}

Substitution_Analysis :: struct {
	expected, typed: rune,
	count, tests: u32,
}

Test_Analysis :: struct {
	inserts, deletes, pauses: u32,
	thirds, errors: [3]u32,
	keys: [dynamic]Key_Analysis,
	pairs: [dynamic]Pair_Analysis,
	words: [dynamic]Word_Analysis,
	substitutions: [dynamic]Substitution_Analysis,
}

analyse_test :: proc(t: ^engine.Test) -> Test_Analysis {
	a: Test_Analysis
	a.keys = make([dynamic]Key_Analysis, 0, 40)
	a.pairs = make([dynamic]Pair_Analysis, 0, 100)
	keys := make(map[rune]int, 40)
	pairs := make(map[u64]int, 100)
	last: engine.Event
	have_last, adjacent := false, false
	duration := t.end_ms - t.start_ms
	for e in t.log {
		if e.kind != .Input do continue
		if e.input_type == .Delete_Content_Backward || e.input_type == .Delete_Word_Backward {
			a.deletes += 1
			adjacent = false
			continue
		}
		if e.input_type != .Insert_Text && e.input_type != .Insert_Composition_Text do continue
		a.inserts += 1
		third := clamp(int(e.t * 3 / max(1, duration)), 0, 2)
		a.thirds[third] += 1
		if .Correct not_in e.flags do a.errors[third] += 1
		gap := e.t - last.t
		if have_last && gap >= 1000 do a.pauses += 1
		target := engine.target_word(t, e.word_index)
		if e.char_index >= 0 && int(e.char_index) < len(target) {
			key := unicode.to_lower(target[e.char_index])
			if !unicode.is_space(key) {
				i, found := keys[key]
				if !found {
					i = len(a.keys)
					keys[key] = i
					append(&a.keys, Key_Analysis{key = key})
				}
				k := &a.keys[i]
				k.attempts += 1
				if .Correct not_in e.flags do k.errors += 1
				if adjacent && .Correct in e.flags && gap > 0 && gap <= 2000 {
					k.timed += 1
					k.interval += u64(math.round(gap * 100))
					if last.word_index == e.word_index && last.char_index + 1 == e.char_index && !unicode.is_space(last.data) {
						first := unicode.to_lower(last.data)
						code := u64(u32(first)) << 32 | u64(u32(key))
						pi, exists := pairs[code]
						if !exists {
							pi = len(a.pairs)
							pairs[code] = pi
							append(&a.pairs, Pair_Analysis{first = first, second = key})
						}
						a.pairs[pi].count += 1
						a.pairs[pi].interval += u64(math.round(gap * 100))
					}
				}
			}
		}
		last = e
		have_last = true
		adjacent = .Correct in e.flags && .Input_Stopped not_in e.flags
	}
	analysis_mistakes(t, &a)
	return a
}

// Each completed target position is one observation, even when revisited.
// Errors corrected later still count. A timed cutoff's unfinished word does not.
analysis_mistakes :: proc(t: ^engine.Test, a: ^Test_Analysis) {
	Word_State :: struct { complete, missed: bool }
	positions := make(map[i32]Word_State)
	subs := make(map[u64]int)
	for e in t.log {
		if e.kind != .Input do continue
		if e.input_type == .Delete_Content_Backward || e.input_type == .Delete_Word_Backward {
			if v, found := positions[e.word_index]; found {
				v.complete = false
				positions[e.word_index] = v
			}
			continue
		}
		if e.input_type != .Insert_Text && e.input_type != .Insert_Composition_Text do continue
		target := engine.target_word(t, e.word_index)
		if len(target) == 0 do continue
		v := positions[e.word_index]
		if .Correct not_in e.flags do v.missed = true
		if .Commits_Word in e.flags && .Input_Stopped not_in e.flags {
			v.complete = true
			if int(e.input_len) < len(target) do v.missed = true
		}
		if .Last_Word in e.flags && int(e.input_len) >= len(target) && .Input_Stopped not_in e.flags do v.complete = true
		positions[e.word_index] = v
		if .Correct in e.flags || e.char_index < 0 || int(e.char_index) >= len(target) do continue
		expected, typed := unicode.to_lower(target[e.char_index]), unicode.to_lower(e.data)
		if expected == typed || unicode.is_space(expected) || unicode.is_space(typed) do continue
		code := u64(u32(expected)) << 32 | u64(u32(typed))
		i, found := subs[code]
		if !found {
			i = len(a.substitutions)
			subs[code] = i
			append(&a.substitutions, Substitution_Analysis{expected = expected, typed = typed, tests = 1})
		}
		a.substitutions[i].count += 1
	}
	words := make(map[string]int)
	for position, v in positions {
		if !v.complete do continue
		b := strings.builder_make()
		target := engine.target_word(t, position)
		end := len(target)
		for end > 0 && unicode.is_space(target[end - 1]) do end -= 1
		for c in target[:end] do strings.write_rune(&b, unicode.to_lower(c))
		word := strings.to_string(b)
		i, found := words[word]
		if !found {
			i = len(a.words)
			words[word] = i
			append(&a.words, Word_Analysis{word = word, tests = 1})
		}
		a.words[i].attempts += 1
		if v.missed {
			a.words[i].misses += 1
			a.words[i].missed_tests = 1
		}
	}
}

analysis_put :: proc(b: ^[dynamic]u8, n: u64, bytes: int = 4) {
	for i in 0 ..< bytes do append(b, u8(n >> uint(i * 8)))
}

analysis_encode :: proc(a: Test_Analysis) -> []u8 {
	b := make([dynamic]u8, 0, 64 + len(a.keys) * 24 + len(a.pairs) * 20)
	analysis_put(&b, ANALYTICS_VERSION)
	analysis_put(&b, u64(a.inserts))
	analysis_put(&b, u64(a.deletes))
	analysis_put(&b, u64(a.pauses))
	for n in a.thirds do analysis_put(&b, u64(n))
	for n in a.errors do analysis_put(&b, u64(n))
	analysis_put(&b, u64(len(a.keys)))
	analysis_put(&b, u64(len(a.pairs)))
	analysis_put(&b, u64(len(a.words)))
	analysis_put(&b, u64(len(a.substitutions)))
	for k in a.keys {
		analysis_put(&b, u64(u32(k.key)))
		analysis_put(&b, u64(k.attempts))
		analysis_put(&b, u64(k.errors))
		analysis_put(&b, u64(k.timed))
		analysis_put(&b, k.interval, 8)
	}
	for p in a.pairs {
		analysis_put(&b, u64(u32(p.first)))
		analysis_put(&b, u64(u32(p.second)))
		analysis_put(&b, u64(p.count))
		analysis_put(&b, p.interval, 8)
	}
	for v in a.words {
		analysis_put(&b, u64(len(v.word)))
		analysis_put(&b, u64(v.attempts))
		analysis_put(&b, u64(v.misses))
		analysis_put(&b, u64(v.tests))
		analysis_put(&b, u64(v.missed_tests))
		append(&b, ..transmute([]u8)v.word)
	}
	for v in a.substitutions {
		analysis_put(&b, u64(u32(v.expected)))
		analysis_put(&b, u64(u32(v.typed)))
		analysis_put(&b, u64(v.count))
		analysis_put(&b, u64(v.tests))
	}
	return b[:]
}

Analysis_Reader :: struct {
	data: []u8,
	at: int,
}

analysis_read :: #force_inline proc(r: ^Analysis_Reader, bytes: int = 4) -> u64 {
	n := u64(endian.unchecked_get_u32le(r.data[r.at:])) if bytes == 4 else endian.unchecked_get_u64le(r.data[r.at:])
	r.at += bytes
	return n
}

// Decode sizes and validate semantic invariants before mutating any totals.
analysis_header :: proc(data: []u8) -> (a: Test_Analysis, keys, pairs, words, substitutions: int, ok: bool) {
	if len(data) < ANALYTICS_HEADER do return
	r := Analysis_Reader{data = data}
	if analysis_read(&r) != ANALYTICS_VERSION do return
	a.inserts = u32(analysis_read(&r))
	a.deletes = u32(analysis_read(&r))
	a.pauses = u32(analysis_read(&r))
	for &n in a.thirds do n = u32(analysis_read(&r))
	for &n in a.errors do n = u32(analysis_read(&r))
	keys, pairs = int(analysis_read(&r)), int(analysis_read(&r))
	words, substitutions = int(analysis_read(&r)), int(analysis_read(&r))
	if keys > (len(data) - r.at) / 24 || pairs > (len(data) - r.at) / 20 || keys * 24 + pairs * 20 > len(data) - r.at do return
	if a.pauses > a.inserts do return
	thirds := u64(a.thirds[0]) + u64(a.thirds[1]) + u64(a.thirds[2])
	if thirds != 0 && thirds != u64(a.inserts) do return
	for n, i in a.thirds do if a.errors[i] > n do return
	key_attempts, timed_total, pair_total := u64(0), u64(0), u64(0)
	seen_keys := make(map[rune]bool, context.temp_allocator)
	seen_pairs := make(map[u64]bool, context.temp_allocator)
	error_counts := make(map[rune]u32, context.temp_allocator)
	timing_counts := make(map[rune]u64, context.temp_allocator)
	timing_intervals := make(map[rune]u64, context.temp_allocator)
	pair_counts := make(map[rune]u64, context.temp_allocator)
	pair_intervals := make(map[rune]u64, context.temp_allocator)
	for _ in 0 ..< keys {
		key := rune(analysis_read(&r))
		attempts, errors, timed := analysis_read(&r), analysis_read(&r), analysis_read(&r)
		interval := analysis_read(&r, 8)
		if !analysis_rune(key) || seen_keys[key] || errors > attempts || timed > attempts - errors || interval > timed * 200_000 do return
		seen_keys[key] = true
		error_counts[key] = u32(errors)
		timing_counts[key], timing_intervals[key] = timed, interval
		key_attempts += attempts
		timed_total += timed
	}
	if key_attempts > u64(a.inserts) do return
	for _ in 0 ..< pairs {
		first, second := rune(analysis_read(&r)), rune(analysis_read(&r))
		code := u64(u32(first)) << 32 | u64(u32(second))
		count, interval := analysis_read(&r), analysis_read(&r, 8)
		if !analysis_rune(first) || !analysis_rune(second) || seen_pairs[code] || count == 0 || interval > count * 200_000 do return
		seen_pairs[code] = true
		pair_total += count
		pair_counts[second] += count
		pair_intervals[second] += interval
	}
	if pair_total > timed_total || words > (len(data) - r.at) / 21 do return
	for key, count in pair_counts do if count > timing_counts[key] || pair_intervals[key] > timing_intervals[key] do return
	seen_words := make(map[string]bool, context.temp_allocator)
	word_attempts := u64(0)
	for _ in 0 ..< words {
		if len(data) - r.at < 20 do return
		size := int(analysis_read(&r))
		attempts, misses := analysis_read(&r), analysis_read(&r)
		tests, missed_tests := analysis_read(&r), analysis_read(&r)
		if size < 1 || size > len(data) - r.at || attempts == 0 || misses > attempts || tests == 0 || tests > attempts || missed_tests > tests || missed_tests > misses do return
		word := string(data[r.at:r.at + size])
		if seen_words[word] do return
		seen_words[word] = true
		r.at += size
		word_attempts += attempts
	}
	if word_attempts > u64(a.inserts) || substitutions > (len(data) - r.at) / 16 || r.at + substitutions * 16 != len(data) do return
	seen_subs := make(map[u64]bool, context.temp_allocator)
	sub_counts := make(map[rune]u64, context.temp_allocator)
	for _ in 0 ..< substitutions {
		expected, typed := rune(analysis_read(&r)), rune(analysis_read(&r))
		count, tests := analysis_read(&r), analysis_read(&r)
		code := u64(u32(expected)) << 32 | u64(u32(typed))
		if !analysis_rune(expected) || !analysis_rune(typed) || expected == typed || seen_subs[code] || count == 0 || tests == 0 || tests > count do return
		seen_subs[code] = true
		sub_counts[expected] += count
	}
	for key, count in sub_counts do if count > u64(error_counts[key]) do return
	ok = true
	return
}

analysis_rune :: proc(key: rune) -> bool {
	return key > 0 && key <= 0x10ffff && !(key >= 0xd800 && key <= 0xdfff) && !unicode.is_space(key)
}

analysis_key_text :: proc(key: rune) -> string {
	b := strings.builder_make()
	strings.write_rune(&b, key)
	return strings.to_string(b)
}
