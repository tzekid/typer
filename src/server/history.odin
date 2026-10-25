package server

import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"


HISTORY_CACHE_LIMIT :: 16
DAY_MS :: i64(86_400_000)

History_Group :: struct {
	setup: Stored,
	all: [dynamic]Stored,
	valid: [dynamic]Stored,
	wpm, acc, cons: f64,
	best: Stored,
	analysed, unavailable: int,
	inserts, deletes, pauses: u64,
	pace_tests: int,
	pace_seconds: f64,
	thirds, errors: [3]u64,
	keys: map[rune]Key_Analysis,
	pairs: map[u64]Pair_Analysis,
	words: map[string]Word_Analysis,
	substitutions: map[u64]Substitution_Analysis,
	missed: [dynamic]Word_Analysis,
	mistyped: [dynamic]Substitution_Analysis,
	records: [dynamic]Stored,
	slow: [dynamic]Pair_Analysis,
}

History_Day :: struct {
	day: i64,
	count: int,
	seconds: f64,
}

History :: struct {
	groups: [dynamic]History_Group,
	days: [dynamic]History_Day,
	tests, active_days: int,
	seconds: f64,
	first: i64,
}

Cached_History :: struct {
	arena: virtual.Arena,
	data: History,
	used: i64,
}

histories_clear :: proc(db: ^Db) {
	for _, entry in db.histories {
		cached := entry
		virtual.arena_destroy(&cached.arena)
	}
	clear(&db.histories)
}

history_invalidate :: proc(db: ^Db, user_id: i64) {
	if cached, ok := db.histories[user_id]; ok {
		virtual.arena_destroy(&cached.arena)
		delete_key(&db.histories, user_id)
	}
}

// A setup includes punctuation and numbers. Quote ids vary within a length
// group, so that group's tests can be compared without mixing languages.
history_setup_key :: proc(s: Stored) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, int(s.setup.mode))
	w(&b, "/")
	strings.write_int(&b, int(s.qgroup if s.setup.mode == .Quote else s.setup.mode2))
	w(&b, "/")
	w(&b, s.setup.language)
	if .Punctuation in s.setup.flags do w(&b, "/p")
	if .Numbers in s.setup.flags do w(&b, "/n")
	return strings.to_string(b)
}

history_add_summary :: proc(g: ^History_Group, data: []u8, seconds: f64) -> bool {
	a, nk, np, nw, ns, ok := analysis_header(data)
	if !ok do return false
	g.analysed += 1
	g.inserts += u64(a.inserts)
	g.deletes += u64(a.deletes)
	g.pauses += u64(a.pauses)
	r := Analysis_Reader{data = data, at = ANALYTICS_HEADER}
	for _ in 0 ..< nk {
		key := rune(analysis_read(&r))
		v := g.keys[key]
		v.key = key
		v.attempts += u32(analysis_read(&r))
		v.errors += u32(analysis_read(&r))
		v.timed += u32(analysis_read(&r))
		v.interval += analysis_read(&r, 8)
		g.keys[key] = v
	}
	for _ in 0 ..< np {
		first, second := rune(analysis_read(&r)), rune(analysis_read(&r))
		key := u64(u32(first)) << 32 | u64(u32(second))
		v := g.pairs[key]
		v.first, v.second = first, second
		v.count += u32(analysis_read(&r))
		v.interval += analysis_read(&r, 8)
		g.pairs[key] = v
	}
	for _ in 0 ..< nw {
		size := int(analysis_read(&r))
		attempts, misses := u32(analysis_read(&r)), u32(analysis_read(&r))
		tests, missed_tests := u32(analysis_read(&r)), u32(analysis_read(&r))
		word := string(data[r.at:r.at + size])
		r.at += size
		v, found := g.words[word]
		if !found { v.word = strings.clone(word) }
		v.attempts += attempts
		v.misses += misses
		v.tests += tests
		v.missed_tests += missed_tests
		g.words[v.word] = v
	}
	for _ in 0 ..< ns {
		expected, typed := rune(analysis_read(&r)), rune(analysis_read(&r))
		code := u64(u32(expected)) << 32 | u64(u32(typed))
		v := g.substitutions[code]
		v.expected, v.typed = expected, typed
		v.count += u32(analysis_read(&r))
		v.tests += u32(analysis_read(&r))
		g.substitutions[code] = v
	}
	if seconds >= 30 && min(a.thirds[0], a.thirds[1], a.thirds[2]) >= 30 {
		g.pace_tests += 1
		g.pace_seconds += seconds
		for n, i in a.thirds {
			g.thirds[i] += u64(n)
			g.errors[i] += u64(a.errors[i])
		}
	}
	return true
}

// A bounded per-typist cache holds metadata and aggregate counts, never raw
// records. Uploads invalidate only that typist. External commits, including
// `claim`, invalidate all cached histories.
db_history :: proc(db: ^Db, user_id: i64) -> ^History {
	sync.guard(&db.lock)
	if st, ok := sql_prepare(db.conn, "PRAGMA data_version"); ok {
		if step(st) == SQLITE_ROW {
			v := column_int64(st, 0)
			if v != db.data_version {
				db.data_version = v
				db.generation += 1
				histories_clear(db)
			}
		}
		finalize(st)
	}
	if cached, found := &db.histories[user_id]; found {
		cached.used = now_ms()
		return &cached.data
	}
	if len(db.histories) >= HISTORY_CACHE_LIMIT {
		old_id, oldest := i64(0), i64(0x7fff_ffff_ffff_ffff)
		for id, cached in db.histories {
			if cached.used < oldest do old_id, oldest = id, cached.used
		}
		history_invalidate(db, old_id)
	}
	entry := Cached_History{used = now_ms()}
	_ = virtual.arena_init_growing(&entry.arena)
	context.allocator = virtual.arena_allocator(&entry.arena)
	h := &entry.data
	h.groups = make([dynamic]History_Group)
	h.days = make([dynamic]History_Day)
	groups := make(map[string]int, context.temp_allocator)
	days := make(map[i64]int, context.temp_allocator)
	st, ok := sql_prepare(db.conn, `SELECT ` + COLUMNS + `
		FROM results r LEFT JOIN users u ON u.id = r.user_id
		WHERE r.user_id = ? ORDER BY r.created_at, r.id`, user_id)
	if ok {
		defer finalize(st)
		for step(st) == SQLITE_ROW {
			s := row_stored(st)
			if h.tests == 0 do h.first = s.created_at
			h.tests += 1
			h.seconds += s.duration
			day := s.created_at / DAY_MS
			di, seen := days[day]
			if !seen {
				di = len(h.days)
				days[day] = di
				append(&h.days, History_Day{day = day})
			}
			h.days[di].count += 1
			h.days[di].seconds += s.duration
			key := history_setup_key(s)
			gi, found := groups[key]
			if !found {
				gi = len(h.groups)
				groups[strings.clone(key)] = gi
				append(&h.groups, history_group(s))
			}
			g := &h.groups[gi]
			append(&g.all, s)
			if !s.valid do continue
			append(&g.valid, s)
			if len(g.records) == 0 || s.wpm > g.records[len(g.records) - 1].wpm do append(&g.records, s)
			g.wpm += s.wpm
			g.acc += s.acc
			g.cons += s.cons
			if g.best.id == 0 || s.wpm > g.best.wpm || s.wpm == g.best.wpm && (s.acc > g.best.acc || s.acc == g.best.acc && s.id < g.best.id) do g.best = s
		}
	}
	// A missing or damaged derived total is repaired from the per-result counts.
	// No decoded value reaches the cache until every invariant has passed.
	repair := false
	for &g in h.groups {
		if !db_history_load(db.conn, &g, user_id) do repair = true
	}
	if repair {
		if db_history_repair(db.conn, user_id) {
			for &g in h.groups { _ = db_history_load(db.conn, &g, user_id) }
		}
	}
	h.active_days = len(h.days)
	for &g in h.groups {
		g.unavailable = max(0, len(g.valid) - g.analysed)
		if n := f64(len(g.valid)); n > 0 {
			g.wpm /= n
			g.acc /= n
			g.cons /= n
		}
		for _, v in g.words {
			if v.attempts >= 5 && v.missed_tests >= 3 do append(&g.missed, v)
		}
		slice.sort_by(g.missed[:], proc(a, b: Word_Analysis) -> bool {
			if a.misses != b.misses do return a.misses > b.misses
			if a.attempts != b.attempts do return a.attempts > b.attempts
			return a.word < b.word
		})
		for _, v in g.substitutions {
			if v.count >= 3 && v.tests >= 3 && g.keys[v.expected].attempts >= 20 do append(&g.mistyped, v)
		}
		slice.sort_by(g.mistyped[:], proc(a, b: Substitution_Analysis) -> bool {
			if a.count != b.count do return a.count > b.count
			if a.expected != b.expected do return a.expected < b.expected
			return a.typed < b.typed
		})
		for _, p in g.pairs {
			if p.count >= 20 do append(&g.slow, p)
		}
		slice.sort_by(g.slow[:], proc(a, b: Pair_Analysis) -> bool {
			x, y := f64(a.interval) / f64(a.count), f64(b.interval) / f64(b.count)
			if x != y do return x > y
			if a.first != b.first do return a.first < b.first
			return a.second < b.second
		})
	}
	slice.stable_sort_by(h.groups[:], proc(a, b: History_Group) -> bool {
		return len(a.all) > len(b.all)
	})
	db.histories[user_id] = entry
	cached := &db.histories[user_id]
	return &cached.data
}

history_selected :: proc(h: ^History, query: string) -> int {
	key := query_value(query, "setup")
	for g, i in h.groups {
		if history_setup_key(g.setup) == key do return i
	}
	return 0
}

history_mean :: proc(rows: []Stored) -> f64 {
	if len(rows) == 0 do return 0
	sum := 0.0
	for s in rows do sum += s.wpm
	return sum / f64(len(rows))
}

history_group :: proc(s: Stored = {}) -> History_Group {
	return History_Group{setup = s, keys = make(map[rune]Key_Analysis), pairs = make(map[u64]Pair_Analysis), words = make(map[string]Word_Analysis), substitutions = make(map[u64]Substitution_Analysis)}
}
