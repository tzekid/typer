package engine

// A test as stored and uploaded: the setup, the target words and the platform
// events the engine applied, in order. Replaying it through test_apply
// reproduces the exact log, so every number is re-derived, never trusted.
//
// Binary layout, little endian:
//   "TYR1" | u32 version | u8 mode | u8 flags | u16 reserved | i32 mode2
//   u64 seed | u32 language length | language bytes
//   u32 word count | per word: u32 byte length, u32 commit rune, bytes
//   u32 event count | per event: f64 ms, u8 kind, u8 pad, u16 code, i32 arg

RECORD_MAGIC :: "TYR1"
RECORD_VERSION :: u32(1)
RECORD_MAX_WORDS :: 100_000
RECORD_MAX_EVENTS :: 1_000_000
RECORD_MAX_MS :: 1e12 // event times are page clock milliseconds
RECORD_MAX_TEST_MS :: 3 * 60 * 60 * 1000

Raw_Kind :: enum u8 {
	Key_Down,
	Key_Down_Repeat,
	Key_Up,
	Insert,
	Delete_Char,
	Delete_Word,
	Time_Up,
	Finalize,
}

Raw_Event :: struct {
	ms:   f64,
	kind: Raw_Kind,
	code: u16,
	arg:  i32, // inserted rune, or remaining length for deletes
}

Record_Flag :: enum u8 {
	Punctuation,
	Numbers,
	Repeated, // the same words again after a restart
}
Record_Flags :: bit_set[Record_Flag;u8]

Setup :: struct {
	mode:     Mode,
	mode2:    i32,
	flags:    Record_Flags,
	seed:     u64,
	language: string,
}

test_apply :: proc(t: ^Test, e: Raw_Event) {
	switch e.kind {
	case .Key_Down:
		test_key_down(t, e.ms, e.code, false)
	case .Key_Down_Repeat:
		test_key_down(t, e.ms, e.code, true)
	case .Key_Up:
		test_key_up(t, e.ms, e.code)
	case .Insert:
		test_insert(t, e.ms, rune(e.arg))
	case .Delete_Char:
		test_delete(t, e.ms, .Char, e.arg)
	case .Delete_Word:
		test_delete(t, e.ms, .Word, e.arg)
	case .Time_Up:
		test_time_up(t, e.ms)
	case .Finalize:
		test_finalize(t)
	}
}

record_encode :: proc(setup: Setup, t: ^Test, events: []Raw_Event, allocator := context.allocator) -> []u8 {
	b := make([dynamic]u8, 0, 64 + len(t.target) * 2 + len(events) * 16, allocator)
	append(&b, RECORD_MAGIC)
	put_u32(&b, RECORD_VERSION)
	append(&b, u8(setup.mode), transmute(u8)setup.flags, 0, 0)
	put_u32(&b, u32(setup.mode2))
	put_u32(&b, u32(setup.seed))
	put_u32(&b, u32(setup.seed >> 32))
	put_u32(&b, u32(len(setup.language)))
	append(&b, setup.language)

	n := word_count(t)
	put_u32(&b, u32(n))
	buf: [4]u8
	for i in 0 ..< n {
		w := target_word(t, i)
		commit: rune
		body := w
		if len(w) > 0 && (w[len(w) - 1] == ' ' || w[len(w) - 1] == '\n') {
			commit = w[len(w) - 1]
			body = w[:len(w) - 1]
		}
		size := 0
		for r in body {
			size += encode_rune(buf[:], r)
		}
		put_u32(&b, u32(size))
		put_u32(&b, u32(commit))
		for r in body {
			k := encode_rune(buf[:], r)
			append(&b, ..buf[:k])
		}
	}

	put_u32(&b, u32(len(events)))
	for e in events {
		bits := transmute(u64)e.ms
		put_u32(&b, u32(bits))
		put_u32(&b, u32(bits >> 32))
		append(&b, u8(e.kind), 0, u8(e.code), u8(e.code >> 8))
		put_u32(&b, u32(e.arg))
	}
	return b[:]
}

@(private)
Reader :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

@(private)
read_u32 :: proc(r: ^Reader) -> u32 {
	if !r.ok || r.at + 4 > len(r.data) {
		r.ok = false
		return 0
	}
	v := get_u32(r.data, r.at)
	r.at += 4
	return v
}

@(private)
read_bytes :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || r.at + n > len(r.data) {
		r.ok = false
		return nil
	}
	s := r.data[r.at:r.at + n]
	r.at += n
	return s
}

// Decodes a record into a fresh test (words added, nothing applied yet) and
// returns its setup and events. Strings and events alias `data` / `allocator`.
record_decode :: proc(data: []u8, t: ^Test, allocator := context.allocator) -> (setup: Setup, events: []Raw_Event, ok: bool) {
	r := Reader{data = data, ok = true}
	if string(read_bytes(&r, 4)) != RECORD_MAGIC || read_u32(&r) != RECORD_VERSION {
		return {}, nil, false
	}
	head := read_bytes(&r, 4)
	if !r.ok || head[0] > u8(max(Mode)) {
		return {}, nil, false
	}
	setup.mode = Mode(head[0])
	setup.flags = transmute(Record_Flags)head[1]
	setup.mode2 = i32(read_u32(&r))
	lo := read_u32(&r)
	hi := read_u32(&r)
	setup.seed = u64(lo) | u64(hi) << 32
	setup.language = string(read_bytes(&r, int(read_u32(&r))))

	cfg := Config {
		mode        = setup.mode,
		mode2       = setup.mode2,
		punctuation = .Punctuation in setup.flags,
		numbers     = .Numbers in setup.flags,
	}
	test_reset(t, cfg)
	n := int(read_u32(&r))
	if !r.ok || n > RECORD_MAX_WORDS {
		return {}, nil, false
	}
	for _ in 0 ..< n {
		size := int(read_u32(&r))
		commit := rune(read_u32(&r))
		body := read_bytes(&r, size)
		if !r.ok || (commit != 0 && commit != ' ' && commit != '\n') {
			return {}, nil, false
		}
		test_add_word(t, string(body), commit)
	}
	t.all_generated = (setup.mode == .Words && setup.mode2 > 0 && i32(n) >= setup.mode2) || setup.mode == .Quote

	count := int(read_u32(&r))
	if !r.ok || count > RECORD_MAX_EVENTS || r.at + count * 16 > len(r.data) {
		return {}, nil, false
	}
	events = make([]Raw_Event, count, allocator)
	for &e in events {
		lo_ms := read_u32(&r)
		hi_ms := read_u32(&r)
		e.ms = transmute(f64)(u64(lo_ms) | u64(hi_ms) << 32)
		k := read_bytes(&r, 4)
		if !r.ok || k[0] > u8(max(Raw_Kind)) {
			return {}, nil, false
		}
		e.kind = Raw_Kind(k[0])
		e.code = u16(k[2]) | u16(k[3]) << 8
		e.arg = i32(read_u32(&r))
		if !(abs(e.ms) <= RECORD_MAX_MS) || (e.kind == .Insert && !is_scalar(e.arg)) {
			return {}, nil, false
		}
	}
	return setup, events, r.ok && r.at == len(r.data)
}

// Applies a decoded record's events, refusing any insert or delete the island
// would not have let through, and any finish outside the test's time span.
record_replay :: proc(t: ^Test, events: []Raw_Event) -> bool {
	for e in events {
		#partial switch e.kind {
		case .Insert:
			if !test_before_insert(t, rune(e.arg)) {
				return false
			}
		case .Delete_Char, .Delete_Word:
			if !test_before_delete(t) {
				return false
			}
		}
		test_apply(t, e)
	}
	duration := t.end_ms - t.start_ms
	return t.phase == .Finished && duration >= 0 && duration <= RECORD_MAX_TEST_MS
}

@(private)
is_scalar :: proc "contextless" (c: i32) -> bool {
	return c > 0 && c <= 0x10FFFF && (c < 0xD800 || c > 0xDFFF)
}

@(private)
encode_rune :: proc "contextless" (buf: []u8, r: rune) -> int {
	c := u32(r)
	switch {
	case c < 0x80:
		buf[0] = u8(c)
		return 1
	case c < 0x800:
		buf[0] = u8(0xC0 | (c >> 6))
		buf[1] = u8(0x80 | (c & 0x3F))
		return 2
	case c < 0x10000:
		buf[0] = u8(0xE0 | (c >> 12))
		buf[1] = u8(0x80 | ((c >> 6) & 0x3F))
		buf[2] = u8(0x80 | (c & 0x3F))
		return 3
	}
	buf[0] = u8(0xF0 | (c >> 18))
	buf[1] = u8(0x80 | ((c >> 12) & 0x3F))
	buf[2] = u8(0x80 | ((c >> 6) & 0x3F))
	buf[3] = u8(0x80 | (c & 0x3F))
	return 4
}
