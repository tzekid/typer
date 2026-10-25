package server

import "core:fmt"
import "core:math"

// Totals are disposable. Per-result summaries are the source for a repair.
// A repair within an upload includes the new result, already in its transaction.
HISTORY_TOTALS_VERSION :: 2
HISTORY_TOTALS_HEADER :: 72

history_totals_encode :: proc(g: ^History_Group) -> []u8 {
	a := Test_Analysis{inserts = u32(g.inserts), deletes = u32(g.deletes), pauses = u32(g.pauses)}
	for _, key in g.keys do append(&a.keys, key)
	for _, pair in g.pairs do append(&a.pairs, pair)
	for _, word in g.words do append(&a.words, word)
	for _, substitution in g.substitutions do append(&a.substitutions, substitution)
	b := make([dynamic]u8)
	analysis_put(&b, HISTORY_TOTALS_VERSION)
	analysis_put(&b, u64(g.analysed))
	analysis_put(&b, u64(g.pace_tests))
	analysis_put(&b, 0)
	analysis_put(&b, u64(math.round(g.pace_seconds * 1000)), 8)
	for n in g.thirds do analysis_put(&b, n, 8)
	for n in g.errors do analysis_put(&b, n, 8)
	append(&b, ..analysis_encode(a))
	return b[:]
}

history_totals_decode :: proc(g: ^History_Group, data: []u8) -> bool {
	if len(data) < HISTORY_TOTALS_HEADER + ANALYTICS_HEADER do return false
	r := Analysis_Reader{data = data}
	if analysis_read(&r) != HISTORY_TOTALS_VERSION do return false
	analysed, pace_tests := int(analysis_read(&r)), int(analysis_read(&r))
	if analysis_read(&r) != 0 do return false
	milliseconds := analysis_read(&r, 8)
	thirds, errors: [3]u64
	for &n in thirds do n = analysis_read(&r, 8)
	for &n in errors do n = analysis_read(&r, 8)
	decoded := history_group()
	if !history_add_summary(&decoded, data[HISTORY_TOTALS_HEADER:], 0) do return false
	if pace_tests > analysed || u64(analysed) > decoded.inserts do return false
	if analysed == 0 && (decoded.inserts != 0 || decoded.deletes != 0 || decoded.pauses != 0) do return false
	if pace_tests == 0 {
		if milliseconds != 0 || thirds != ([3]u64{}) || errors != ([3]u64{}) do return false
	} else {
		if milliseconds < u64(pace_tests) * 30_000 || milliseconds > u64(analysed) * 86_400_000 do return false
		// Each eligible test has thirty attempts in every third. Eligible
		// insertions and errors are subsets of all analysed insertions.
		for n, i in thirds {
			if n < u64(pace_tests) * 30 || n > decoded.inserts || errors[i] > n do return false
		}
		if thirds[0] + thirds[1] + thirds[2] > decoded.inserts do return false
	}
	for _, v in decoded.words do if int(v.tests) > analysed || int(v.missed_tests) > analysed do return false
	for _, v in decoded.substitutions do if int(v.tests) > analysed do return false
	g.analysed, g.pace_tests = analysed, pace_tests
	g.pace_seconds = f64(milliseconds) / 1000
	g.thirds, g.errors = thirds, errors
	g.inserts, g.deletes, g.pauses = decoded.inserts, decoded.deletes, decoded.pauses
	g.keys, g.pairs = decoded.keys, decoded.pairs
	g.words, g.substitutions = decoded.words, decoded.substitutions
	return true
}

history_totals_store :: proc(conn: ^Sqlite, user_id: i64, key: string, g: ^History_Group) -> bool {
	return sql_exec(conn, `INSERT INTO history_totals(user_id, setup, data) VALUES (?, ?, ?)
		ON CONFLICT(user_id, setup) DO UPDATE SET data = excluded.data`, user_id, key, history_totals_encode(g)) == SQLITE_DONE
}

// Caller owns the result transaction. Aggregate failure cannot reject a result.
db_history_add :: proc(conn: ^Sqlite, s: Stored, data: []u8) {
	if !s.valid || s.user_id == 0 do return
	key := history_setup_key(s)
	g := history_group()
	st, ok := sql_prepare(conn, "SELECT data FROM history_totals WHERE user_id = ? AND setup = ?", s.user_id, key)
	decoded := false
	if ok {
		if step(st) == SQLITE_ROW {
			blob := ([^]u8)(column_blob(st, 0))[:int(column_bytes(st, 0))]
			decoded = history_totals_decode(&g, blob)
		}
		finalize(st)
	}
	if decoded {
		if history_add_summary(&g, data, s.duration) && history_totals_store(conn, s.user_id, key, &g) do return
	} else if db_history_rebuild(conn, s.user_id) {
		return
	}
	// Leave no stale totals for a later reader. The saved record and its
	// summary remain intact; the next history read retries the repair.
	_ = sql_exec(conn, "DELETE FROM history_totals WHERE user_id = ?", s.user_id)
	fmt.eprintfln("history: totals unavailable for typist %d: %s", s.user_id, sql_error(conn))
}

// The caller supplies a transaction, whether startup, upload, claim or repair.
db_history_rebuild :: proc(conn: ^Sqlite, user_id: i64) -> bool {
	fmt.printfln("event=history_totals_rebuild user=%d", user_id)
	groups := make(map[string]History_Group)
	st, ok := sql_prepare(conn, `SELECT ` + COLUMNS + `, a.version, a.data FROM results r
		LEFT JOIN users u ON u.id = r.user_id LEFT JOIN result_analytics a ON a.result_id = r.id
		WHERE r.user_id = ? AND r.valid = 1 ORDER BY r.id`, user_id)
	if !ok do return false
	for step(st) == SQLITE_ROW {
		s := row_stored(st)
		key := history_setup_key(s)
		if _, found := groups[key]; !found do groups[key] = history_group(s)
		g := &groups[key]
		if column_int64(st, 16) != ANALYTICS_VERSION do continue
		blob := ([^]u8)(column_blob(st, 17))[:int(column_bytes(st, 17))]
		if !history_add_summary(g, blob, s.duration) {
			fmt.eprintfln("history: result %d has unreadable analytics", s.id)
		}
	}
	finalize(st)
	if sql_exec(conn, "DELETE FROM history_totals WHERE user_id = ?", user_id) != SQLITE_DONE do return false
	for key, &g in groups do if !history_totals_store(conn, user_id, key, &g) do return false
	return true
}

// Read into the page's group only after checking the complete blob.
db_history_load :: proc(conn: ^Sqlite, g: ^History_Group, user_id: i64) -> bool {
	if len(g.valid) == 0 do return true
	st, ok := sql_prepare(conn, "SELECT data FROM history_totals WHERE user_id = ? AND setup = ?", user_id, history_setup_key(g.setup))
	if !ok do return false
	defer finalize(st)
	if step(st) != SQLITE_ROW do return false
	blob := ([^]u8)(column_blob(st, 0))[:int(column_bytes(st, 0))]
	decoded := history_group()
	if !history_totals_decode(&decoded, blob) || decoded.analysed > len(g.valid) do return false
	g.analysed, g.pace_tests = decoded.analysed, decoded.pace_tests
	g.pace_seconds, g.thirds, g.errors = decoded.pace_seconds, decoded.thirds, decoded.errors
	g.inserts, g.deletes, g.pauses = decoded.inserts, decoded.deletes, decoded.pauses
	g.keys, g.pairs, g.words, g.substitutions = decoded.keys, decoded.pairs, decoded.words, decoded.substitutions
	return true
}

db_history_repair :: proc(conn: ^Sqlite, user_id: i64) -> bool {
	if sql_exec(conn, "BEGIN IMMEDIATE") != SQLITE_DONE do return false
	committed := false
	defer if !committed do sql_exec(conn, "ROLLBACK")
	if !db_history_rebuild(conn, user_id) || sql_exec(conn, "COMMIT") != SQLITE_DONE do return false
	committed = true
	return true
}

db_history_claim :: proc(conn: ^Sqlite, user_id: i64) -> bool {
	return db_history_rebuild(conn, user_id)
}
