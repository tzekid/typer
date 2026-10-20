package engine

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Random word generation, following upstream words-generator.ts getNextWord
// and punctuateWord (each `random() < p` is a fresh draw, as there).

Rng :: struct {
	s: [4]u64,
}

@(private)
splitmix :: proc "contextless" (x: ^u64) -> u64 {
	x^ += 0x9E3779B97F4A7C15
	z := x^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

rng_seed :: proc "contextless" (r: ^Rng, seed: u64) {
	x := seed
	for i in 0 ..< 4 {
		r.s[i] = splitmix(&x)
	}
}

@(private)
rotl :: proc "contextless" (x: u64, k: u64) -> u64 {
	return (x << k) | (x >> (64 - k))
}

// xoshiro256**
rng_u64 :: proc "contextless" (r: ^Rng) -> u64 {
	result := rotl(r.s[1] * 5, 7) * 9
	t := r.s[1] << 17
	r.s[2] ~= r.s[0]
	r.s[3] ~= r.s[1]
	r.s[1] ~= r.s[2]
	r.s[0] ~= r.s[3]
	r.s[2] ~= t
	r.s[3] = rotl(r.s[3], 45)
	return result
}

// Uniform in [0, 1), like Math.random().
rng_f64 :: proc "contextless" (r: ^Rng) -> f64 {
	return f64(rng_u64(r) >> 11) * (1.0 / 9007199254740992.0)
}

// randomIntFromRange (inclusive bounds).
rng_int :: proc "contextless" (r: ^Rng, lo, hi: int) -> int {
	return lo + int(rng_f64(r) * f64(hi - lo + 1))
}

// A word list: offsets into a UTF-8 blob, as stored in a language pack.
Word_List :: struct {
	name:                 string,
	offsets:              []u32,
	blob:                 []u8,
	rtl:                  bool,
	ordered_by_frequency: bool,
}

word_list_len :: proc "contextless" (w: Word_List) -> int {
	return max(len(w.offsets) - 1, 0)
}

word_list_get :: proc "contextless" (w: Word_List, i: int) -> string {
	return string(w.blob[w.offsets[i]:w.offsets[i + 1]])
}

Language_Group :: enum u8 {
	Other,
	English,
	Spanish,
	French,
	German,
	Swiss_German,
	Turkish,
	Kurdish,
	Nepali,
	Bangla,
	Hindi,
	Japanese,
	Chinese,
	Arabic,
	Persian,
	Urdu,
	Greek,
	Russian,
	Ukrainian,
	Slovak,
	Georgian,
	Code,
	Klingon,
}

language_group :: proc(name: string) -> Language_Group {
	if strings.has_prefix(name, "swiss_german") {
		return .Swiss_German
	}
	base := name
	if i := strings.index_byte(name, '_'); i >= 0 {
		base = name[:i]
	}
	switch base {
	case "english":
		return .English
	case "spanish":
		return .Spanish
	case "french":
		return .French
	case "german":
		return .German
	case "turkish":
		return .Turkish
	case "kurdish":
		return .Kurdish
	case "nepali":
		return .Nepali
	case "bangla":
		return .Bangla
	case "hindi":
		return .Hindi
	case "japanese":
		return .Japanese
	case "chinese":
		return .Chinese
	case "arabic":
		return .Arabic
	case "persian":
		return .Persian
	case "urdu":
		return .Urdu
	case "greek":
		return .Greek
	case "russian":
		return .Russian
	case "ukrainian":
		return .Ukrainian
	case "slovak":
		return .Slovak
	case "georgian":
		return .Georgian
	case "code":
		return .Code
	case "klingon":
		return .Klingon
	}
	return .Other
}

Generator :: struct {
	rng:              Rng,
	words:            Word_List,
	group:            Language_Group,
	punctuation:      bool,
	numbers:          bool,
	spanish_sentence: rune,
	prev:             [dynamic]u8, // previous generated word (raw, no commit)
	prev2:            [dynamic]u8,
}

generator_init :: proc(g: ^Generator, words: Word_List, seed: u64, punctuation, numbers: bool) {
	rng_seed(&g.rng, seed)
	g.words = words
	g.group = language_group(words.name)
	g.punctuation = punctuation
	g.numbers = numbers
	g.spanish_sentence = 0
	clear(&g.prev)
	clear(&g.prev2)
}

generator_destroy :: proc(g: ^Generator) {
	delete(g.prev)
	delete(g.prev2)
}

@(private)
strip_for_compare :: proc(s: string, strip_apostrophe: bool, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for r in s {
		switch r {
		case '.', '?', '!', '"', ':', '-', ',':
			continue
		case '\'':
			if strip_apostrophe {
				continue
			}
		}
		strings.write_rune(&b, r)
	}
	return strings.to_lower(strings.to_string(b), allocator)
}

@(private)
has_symbol :: proc(s: string) -> bool {
	for r in s {
		switch r {
		case '-', '=', '_', '+', '[', ']', '{', '}', ';', '\'', '\\', ':', '"', '|', ',', '.', '/', '<', '>', '?':
			return true
		}
	}
	return false
}

@(private)
has_digit :: proc(s: string) -> bool {
	for r in s {
		if r >= '0' && r <= '9' {
			return true
		}
	}
	return false
}

@(private)
has_ascii_upper :: proc(s: string) -> bool {
	for r in s {
		if r >= 'A' && r <= 'Z' {
			return true
		}
	}
	return false
}

@(private)
capitalize_first :: proc(s: string, allocator := context.temp_allocator) -> string {
	if len(s) == 0 {
		return s
	}
	r, n := utf8.decode_rune_in_string(s)
	return strings.concatenate({strings.to_upper(utf8.runes_to_string({r}, allocator), allocator), s[n:]}, allocator)
}

@(private)
last_rune :: proc(s: string) -> rune {
	if len(s) == 0 {
		return 0
	}
	r, _ := utf8.decode_last_rune_in_string(s)
	return r
}

// Next word for position `index` of a test bounded at `bound` words. The
// result (raw, without commit character) is valid until the next call.
generator_next :: proc(g: ^Generator, index, bound: int, allocator := context.temp_allocator) -> string {
	n := word_list_len(g.words)
	if n == 0 {
		return ""
	}
	prev := string(g.prev[:])
	prev2 := string(g.prev2[:])
	prev_raw := strip_for_compare(prev, false)
	prev2_raw := strip_for_compare(prev2, true)

	word := word_list_get(g.words, rng_int(&g.rng, 0, n - 1))
	first := strings.to_lower(word, context.temp_allocator)
	for tries := 0; tries < 100; tries += 1 {
		reroll :=
			prev_raw == first ||
			prev2_raw == first ||
			(!g.punctuation && word == "I") ||
			(!g.punctuation && g.group != .Code && has_symbol(word)) ||
			(!g.numbers && has_digit(word))
		if !reroll {
			break
		}
		word = word_list_get(g.words, rng_int(&g.rng, 0, n - 1))
		first = word
	}

	out := word
	if has_ascii_upper(out) && !g.punctuation {
		#partial switch g.group {
		case .German, .Swiss_German, .Code, .Klingon:
		case:
			out = strings.to_lower(out, allocator)
		}
	}
	if g.group == .Swiss_German {
		out, _ = strings.replace_all(out, "ß", "ss", allocator)
	}
	if g.punctuation {
		out = punctuate(g, prev, out, index, bound, allocator)
	}
	if g.numbers && rng_f64(&g.rng) < 0.1 {
		out = numbers_word(g, allocator)
	}

	clear(&g.prev2)
	append(&g.prev2, ..g.prev[:])
	clear(&g.prev)
	append(&g.prev, out)
	return out
}

@(private)
numbers_word :: proc(g: ^Generator, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, 4, allocator)
	length := rng_int(&g.rng, 1, 4)
	for i in 0 ..< length {
		d := rng_int(&g.rng, 1, 9) if i == 0 else rng_int(&g.rng, 0, 9)
		base: rune = '0'
		#partial switch g.group {
		case .Kurdish:
			base = 0x0660
		case .Nepali, .Hindi:
			base = 0x0966
		case .Bangla:
			base = 0x09E6
		}
		strings.write_rune(&b, base + rune(d))
	}
	return strings.to_string(b)
}

@(private)
should_capitalize :: proc "contextless" (c: rune) -> bool {
	return c == '?' || c == '!' || c == '.' || c == 0x061F
}

@(private)
cjk :: proc "contextless" (g: Language_Group) -> bool {
	return g == .Japanese || g == .Chinese
}

@(private)
punctuate :: proc(g: ^Generator, previous: string, current: string, index, maxindex: int, allocator := context.temp_allocator) -> string {
	word := current
	last := last_rune(previous)
	lang := g.group
	r := &g.rng

	if lang != .Code && lang != .Georgian && (index == 0 || should_capitalize(last)) {
		word = capitalize_first(word, allocator)
		if lang == .Turkish {
			word, _ = strings.replace_all(word, "I", "İ", allocator)
		}
		if lang == .Spanish {
			x := rng_f64(r)
			if x > 0.9 {
				word = strings.concatenate({"¿", word}, allocator)
				g.spanish_sentence = '?'
			} else if x > 0.8 {
				word = strings.concatenate({"¡", word}, allocator)
				g.spanish_sentence = '!'
			}
		}
	} else if (rng_f64(r) < 0.1 && last != '.' && last != ',' && index != maxindex - 2) || index == maxindex - 1 {
		if lang == .Spanish {
			if g.spanish_sentence != 0 {
				word = strings.concatenate({word, utf8.runes_to_string({g.spanish_sentence}, allocator)}, allocator)
				g.spanish_sentence = 0
			}
		} else {
			x := rng_f64(r)
			if x <= 0.8 {
				end := "."
				#partial switch lang {
				case .Nepali, .Bangla, .Hindi:
					end = "।"
				case .Japanese, .Chinese:
					end = "。"
				}
				word = strings.concatenate({word, end}, allocator)
			} else if x > 0.8 && x < 0.9 {
				#partial switch lang {
				case .French:
					word = "?"
				case .Arabic, .Persian, .Urdu, .Kurdish:
					word = strings.concatenate({word, "؟"}, allocator)
				case .Greek:
					word = strings.concatenate({word, ";"}, allocator)
				case .Japanese, .Chinese:
					word = strings.concatenate({word, "？"}, allocator)
				case:
					word = strings.concatenate({word, "?"}, allocator)
				}
			} else {
				#partial switch lang {
				case .French:
					word = "!"
				case .Japanese, .Chinese:
					word = strings.concatenate({word, "！"}, allocator)
				case:
					word = strings.concatenate({word, "!"}, allocator)
				}
			}
		}
	} else if rng_f64(r) < 0.01 && last != ',' && last != '.' && lang != .Russian {
		word = strings.concatenate({"\"", word, "\""}, allocator)
	} else if rng_f64(r) < 0.011 && last != ',' && last != '.' && lang != .Russian && lang != .Ukrainian && lang != .Slovak {
		word = strings.concatenate({"'", word, "'"}, allocator)
	} else if rng_f64(r) < 0.012 && last != ',' && last != '.' {
		if lang == .Code {
			brackets := [?]string{"()", "{}", "[]", "<>"}
			b := brackets[int(rng_f64(r) * f64(len(brackets)))]
			word = strings.concatenate({b[:1], word, b[1:]}, allocator)
		} else if cjk(lang) {
			word = strings.concatenate({"（", word, "）"}, allocator)
		} else {
			word = strings.concatenate({"(", word, ")"}, allocator)
		}
	} else if rng_f64(r) < 0.013 && last != ',' && last != '.' && last != ';' && last != 0x061B && last != ':' && last != 0xFF1B && last != 0xFF1A {
		#partial switch lang {
		case .French:
			word = ":"
		case .Chinese:
			word = strings.concatenate({word, "："}, allocator)
		case:
			word = strings.concatenate({word, ":"}, allocator)
		}
	} else if rng_f64(r) < 0.014 && last != ',' && last != '.' && previous != "-" {
		word = "-"
	} else if rng_f64(r) < 0.015 && last != ',' && last != '.' && last != ';' && last != 0x061B && last != 0xFF1B && last != 0xFF1A {
		#partial switch lang {
		case .French:
			word = ";"
		case .Greek:
			word = "."
		case .Arabic, .Kurdish:
			word = strings.concatenate({word, "؛"}, allocator)
		case .Chinese:
			word = strings.concatenate({word, "；"}, allocator)
		case:
			word = strings.concatenate({word, ";"}, allocator)
		}
	} else if rng_f64(r) < 0.2 && last != ',' {
		#partial switch lang {
		case .Arabic, .Urdu, .Persian, .Kurdish:
			word = strings.concatenate({word, "،"}, allocator)
		case .Japanese:
			word = strings.concatenate({word, "、"}, allocator)
		case .Chinese:
			word = strings.concatenate({word, "，"}, allocator)
		case:
			word = strings.concatenate({word, ","}, allocator)
		}
	} else if rng_f64(r) < 0.25 && lang == .Code {
		specials := [?]string{"{", "}", "[", "]", "(", ")", ";", "=", "+", "%", "/"}
		word = specials[rng_int(r, 0, len(specials) - 1)]
	} else if rng_f64(r) < 0.5 && lang == .English {
		word = english_contraction(r, word, allocator)
	}
	return word
}

@(private)
Contraction :: struct {
	base:    string,
	options: []string,
}

@(rodata, private)
CONTRACTIONS := [?]Contraction {
	{"are", {"aren't"}},
	{"can", {"can't"}},
	{"could", {"couldn't"}},
	{"did", {"didn't"}},
	{"does", {"doesn't"}},
	{"do", {"don't"}},
	{"had", {"hadn't"}},
	{"has", {"hasn't"}},
	{"have", {"haven't"}},
	{"is", {"isn't"}},
	{"it", {"it's", "it'll"}},
	{"i", {"i'm", "i'll", "i've", "i'd"}},
	{"you", {"you'll", "you're", "you've", "you'd"}},
	{"that", {"that's", "that'll", "that'd"}},
	{"must", {"mustn't", "must've"}},
	{"there", {"there's", "there'll", "there'd"}},
	{"he", {"he's", "he'll", "he'd"}},
	{"she", {"she's", "she'll", "she'd"}},
	{"we", {"we're", "we'll", "we'd"}},
	{"they", {"they're", "they'll", "they'd"}},
	{"should", {"shouldn't", "should've"}},
	{"was", {"wasn't"}},
	{"were", {"weren't"}},
	{"will", {"won't"}},
	{"would", {"wouldn't", "would've"}},
	{"going", {"goin'"}},
}

@(private)
is_word_char :: proc "contextless" (c: rune) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// english-punctuation.ts: replace a whole word (with optional non-word
// characters around it) by one of its contractions, keeping its casing.
@(private)
english_contraction :: proc(r: ^Rng, word: string, allocator := context.temp_allocator) -> string {
	// JS \w is ASCII-only, so every other character counts as \W.
	lo, hi := 0, len(word)
	for lo < hi {
		c, n := utf8.decode_rune_in_string(word[lo:hi])
		if is_word_char(c) {
			break
		}
		lo += n
	}
	for hi > lo {
		c, n := utf8.decode_last_rune_in_string(word[lo:hi])
		if is_word_char(c) {
			break
		}
		hi -= n
	}
	core := word[lo:hi]
	for c in CONTRACTIONS {
		if !strings.equal_fold(core, c.base) {
			continue
		}
		pick := c.options[rng_int(r, 0, len(c.options) - 1)]
		first, _ := utf8.decode_rune_in_string(core)
		replacement := pick
		if first == unicode.to_upper(first) {
			if core != "I" && core == strings.to_upper(core, context.temp_allocator) {
				replacement = strings.to_upper(pick, allocator)
			} else {
				replacement = capitalize_first(pick, allocator)
			}
		}
		return strings.concatenate({word[:lo], replacement, word[hi:]}, allocator)
	}
	return word
}
