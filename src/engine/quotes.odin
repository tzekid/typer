package engine

import "core:strings"
import "core:unicode/utf8"

// Quotes: coherent passages from upstream's quote collections, in four length
// groups (short, medium, long, thicc), typed as one test each.
//
// Quote pack, little endian, built by tools/pack and viewed in place:
//   0    "TYQ1"
//   4    u32 quote count N
//   8    u32 groups[4][2]  inclusive [lo, hi] over upstream's `length` field
//   40   u32 name length L, then the name, zero-padded to 4 bytes
//   ..   N records of 6 u32: id, group, text offset, text length,
//        source offset, source length (sorted by id)
//   ..   UTF-8 blob

QUOTE_MAGIC :: "TYQ1"
QUOTE_GROUPS :: 4

@(rodata)
QUOTE_GROUP_NAMES := [QUOTE_GROUPS]string{"short", "medium", "long", "thicc"}

Quote_Record :: struct {
	id:         u32,
	group:      u32,
	text_off:   u32,
	text_len:   u32,
	source_off: u32,
	source_len: u32,
}

Quote_Pack :: struct {
	language: string,
	groups:   [QUOTE_GROUPS][2]u32,
	records:  []Quote_Record,
	blob:     []u8,
}

Quote :: struct {
	id:     u32,
	group:  u32,
	text:   string,
	source: string,
}

quote_pack_encode :: proc(language: string, groups: [QUOTE_GROUPS][2]u32, quotes: []Quote, allocator := context.allocator) -> []u8 {
	b := make([dynamic]u8, 0, 1024, allocator)
	append(&b, QUOTE_MAGIC)
	put_u32(&b, u32(len(quotes)))
	for g in groups {
		put_u32(&b, g[0])
		put_u32(&b, g[1])
	}
	put_u32(&b, u32(len(language)))
	append(&b, language)
	for len(b) % 4 != 0 {
		append(&b, 0)
	}
	off: u32
	for q in quotes {
		put_u32(&b, q.id)
		put_u32(&b, q.group)
		put_u32(&b, off)
		put_u32(&b, u32(len(q.text)))
		off += u32(len(q.text))
		put_u32(&b, off)
		put_u32(&b, u32(len(q.source)))
		off += u32(len(q.source))
	}
	for q in quotes {
		append(&b, q.text)
		append(&b, q.source)
	}
	return b[:]
}

quote_pack_view :: proc(data: []u8) -> (p: Quote_Pack, ok: bool) {
	if len(data) < 44 || string(data[:4]) != QUOTE_MAGIC || uintptr(raw_data(data)) % 4 != 0 {
		return {}, false
	}
	n := int(get_u32(data, 4))
	for g in 0 ..< QUOTE_GROUPS {
		p.groups[g] = {get_u32(data, 8 + g * 8), get_u32(data, 12 + g * 8)}
	}
	name_len := int(get_u32(data, 40))
	at := 44 + name_len
	if at > len(data) {
		return {}, false
	}
	p.language = string(data[44:at])
	for at % 4 != 0 {
		at += 1
	}
	records_end := at + n * size_of(Quote_Record)
	if n < 0 || records_end > len(data) {
		return {}, false
	}
	p.records = ([^]Quote_Record)(raw_data(data[at:]))[:n]
	p.blob = data[records_end:]
	prev: u32
	for r in p.records {
		if r.id <= prev && prev != 0 || r.group >= QUOTE_GROUPS || int(r.text_off) + int(r.text_len) > len(p.blob) || int(r.source_off) + int(r.source_len) > len(p.blob) {
			return {}, false
		}
		prev = r.id
	}
	return p, true
}

quote_at :: proc(p: ^Quote_Pack, i: int) -> Quote {
	r := p.records[i]
	return Quote {
		id = r.id,
		group = r.group,
		text = string(p.blob[r.text_off:r.text_off + r.text_len]),
		source = string(p.blob[r.source_off:r.source_off + r.source_len]),
	}
}

quote_by_id :: proc(p: ^Quote_Pack, id: u32) -> (Quote, bool) {
	lo, hi := 0, len(p.records)
	for lo < hi {
		mid := (lo + hi) / 2
		if p.records[mid].id < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(p.records) && p.records[lo].id == id {
		return quote_at(p, lo), true
	}
	return {}, false
}

// The group an upstream `length` falls into (upstream defaults to 0).
quote_group :: proc(groups: [QUOTE_GROUPS][2]u32, length: u32) -> u32 {
	for g, i in groups {
		if length >= g[0] && length <= g[1] {
			return u32(i)
		}
	}
	return 0
}

// The quote collection a word-list language draws from: sizes are stripped
// (english_10k -> english) and swiss german uses german quotes.
quote_language :: proc(language: string) -> string {
	if strings.has_prefix(language, "swiss_german") {
		return "german"
	}
	if i := strings.last_index_byte(language, '_'); i >= 0 {
		tail := language[i + 1:]
		if len(tail) > 1 && tail[len(tail) - 1] == 'k' {
			digits := true
			for c in tail[:len(tail) - 1] {
				digits &&= c >= '0' && c <= '9'
			}
			if digits {
				return language[:i]
			}
		}
	}
	return language
}

@(private)
is_js_whitespace :: proc "contextless" (c: rune) -> bool {
	switch c {
	case '\t', '\n', 0x0B, 0x0C, '\r', ' ', 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	}
	return false
}

// Upstream's quote normalization: collapse runs of spaces, glue each line
// break (with the spaces around it) to the previous word as "\n ", spell out
// the ellipsis, trim.
quote_normalize :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(text), allocator)
	rs := utf8.string_to_runes(text, context.temp_allocator)
	i := 0
	for i < len(rs) {
		c := rs[i]
		if c == ' ' || c == '\n' || c == '\r' {
			// a run of spaces, possibly containing line breaks
			j := i
			breaks := 0
			for j < len(rs) && (rs[j] == ' ' || rs[j] == '\n' || rs[j] == '\r') {
				if rs[j] == '\n' || (rs[j] == '\r' && (j + 1 >= len(rs) || rs[j + 1] != '\n')) {
					breaks += 1
				}
				j += 1
			}
			if breaks == 0 {
				strings.write_byte(&b, ' ')
			} else {
				for _ in 0 ..< breaks {
					strings.write_string(&b, "\n ")
				}
			}
			i = j
			continue
		}
		if c == 0x2026 {
			strings.write_string(&b, "...")
		} else {
			strings.write_rune(&b, c)
		}
		i += 1
	}
	out := strings.to_string(b)
	// JS trim()
	lo, hi := 0, len(out)
	for lo < hi {
		r, n := utf8.decode_rune_in_string(out[lo:])
		if !is_js_whitespace(r) do break
		lo += n
	}
	for hi > lo {
		r, n := utf8.decode_last_rune_in_string(out[lo:hi])
		if !is_js_whitespace(r) do break
		hi -= n
	}
	return out[lo:hi]
}

// Adds a normalized quote's words: split on spaces; a token ending in "\n" is
// committed with Enter, the rest with space, the last one with nothing.
test_add_quote :: proc(t: ^Test, text: string) {
	rest := text
	for {
		sp := strings.index_byte(rest, ' ')
		token := rest if sp < 0 else rest[:sp]
		last := sp < 0
		if strings.has_suffix(token, "\n") {
			test_add_word(t, token[:len(token) - 1], 0 if last else '\n')
		} else {
			test_add_word(t, token, 0 if last else ' ')
		}
		if last {
			break
		}
		rest = rest[sp + 1:]
	}
	t.all_generated = true
}

// True when the test's target words are exactly this quote's.
test_matches_quote :: proc(t: ^Test, text: string) -> bool {
	probe: Test
	defer test_destroy(&probe)
	test_reset(&probe, t.cfg)
	test_add_quote(&probe, text)
	return runes_equal(probe.target[:], t.target[:]) && len(probe.target_off) == len(t.target_off)
}
