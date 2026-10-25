package server

import "core:fmt"
import "core:mem/virtual"
import "core:time"

// Startup owns the connection. An ascending cursor visits each old row once;
// completed batches survive a restart. No listener exists during this work.
history_backfill :: proc(conn: ^Sqlite) -> bool {
	started := time.tick_now()
	cursor := i64(0)
	count, failed := 0, 0
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	// The foreign key makes summaries a subset of results. Equal row counts
	// therefore prove completion without probing every completed id again.
	complete := false
	if st, ok := sql_prepare(conn, `SELECT
		(SELECT count(*) FROM results INDEXED BY results_analytics_order) =
		(SELECT count(*) FROM result_analytics)`); ok {
		if step(st) == SQLITE_ROW do complete = column_int64(st, 0) != 0
		finalize(st)
	}
	for !complete {
		virtual.arena_free_all(&arena)
		st, ok := sql_prepare(conn, `SELECT r.id FROM results r INDEXED BY results_analytics_order
			WHERE r.id > ? AND NOT EXISTS (SELECT 1 FROM result_analytics a WHERE a.result_id = r.id)
			ORDER BY r.id LIMIT 100`, cursor)
		if !ok do return false
		ids: [100]i64
		n := 0
		for step(st) == SQLITE_ROW {
			ids[n] = column_int64(st, 0)
			n += 1
		}
		finalize(st)
		if n == 0 do break
		if sql_exec(conn, "BEGIN IMMEDIATE") != SQLITE_DONE do return false
		for id in ids[:n] {
			virtual.arena_free_all(&arena)
			if !history_backfill_store(conn, id) {
				_ = sql_exec(conn, "ROLLBACK")
				fmt.eprintfln("history: backfill result %d: %s", id, sql_error(conn))
				return false
			}
			count += 1
			cursor = id
		}
		if sql_exec(conn, "COMMIT") != SQLITE_DONE {
			_ = sql_exec(conn, "ROLLBACK")
			return false
		}
		if count % 1000 == 0 do fmt.printfln("event=history_backfill_progress results=%d last_id=%d", count, cursor)
	}
	if st, ok := sql_prepare(conn, "SELECT count(*) FROM result_analytics WHERE version = 0"); ok {
		if step(st) == SQLITE_ROW do failed = int(column_int64(st, 0))
		finalize(st)
	}
	fmt.printfln("event=history_backfill results=%d unavailable=%d elapsed_ms=%.3f", count, failed, time.duration_seconds(time.tick_since(started)) * 1000)
	return true
}

history_backfill_store :: proc(conn: ^Sqlite, id: i64) -> bool {
	st, ok := sql_prepare(conn, `SELECT ` + COLUMNS + `, r.record FROM results r
		LEFT JOIN users u ON u.id = r.user_id WHERE r.id = ?`, id)
	if !ok do return false
	if step(st) != SQLITE_ROW {
		finalize(st)
		return false
	}
	s, record := row_stored(st), sql_blob(st, 16)
	finalize(st)
	data: []u8
	version := i64(ANALYTICS_VERSION)
	if r, replayed := replay(record); replayed {
		data = analysis_encode(analyse_test(&r.test))
	} else {
		data, version = []u8{0}, 0
		fmt.eprintfln("history: result %d could not replay", id)
	}
	if sql_exec(conn, "INSERT INTO result_analytics VALUES (?, ?, ?)", id, version, data) != SQLITE_DONE do return false
	if version == ANALYTICS_VERSION do db_history_add(conn, s, data)
	return true
}
