package server

import "base:runtime"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:mem/virtual"
import "core:strings"
import "core:sync"

import engine "../engine"

// One SQLite connection behind one mutex. Leaderboards are cached in memory
// and rebuilt only after a write, by this process or another (typer claim).

Db :: struct {
	conn:         ^Sqlite,
	lock:         sync.Mutex,
	generation:   u64, // bumped by every write that can change a leaderboard
	data_version: i64, // SQLite's; it changes when another connection commits
	boards:       map[string]Cached_Board,
}

@(private)
Cached_Board :: struct {
	generation: u64,
	arena:      virtual.Arena,
	rows:       []Stored,
}

SCHEMA :: `
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS results (
	id          INTEGER PRIMARY KEY,
	created_at  INTEGER NOT NULL,
	mode        INTEGER NOT NULL,
	mode2       INTEGER NOT NULL,
	language    TEXT    NOT NULL,
	punctuation INTEGER NOT NULL,
	numbers     INTEGER NOT NULL,
	wpm         REAL    NOT NULL,
	raw         REAL    NOT NULL,
	acc         REAL    NOT NULL,
	consistency REAL    NOT NULL,
	duration    REAL    NOT NULL,
	valid       INTEGER NOT NULL,
	record_sha  TEXT    NOT NULL UNIQUE,
	record      BLOB    NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS results_by_mode ON results (mode, mode2, language, punctuation, numbers, valid, wpm);
CREATE INDEX IF NOT EXISTS results_by_time ON results (created_at);
`

// Each step runs once, in order, tracked by PRAGMA user_version.
MIGRATIONS := [?]string {
	// 1: typists and quote length groups
	`
	CREATE TABLE users (
		id         INTEGER PRIMARY KEY,
		token_sha  TEXT    NOT NULL UNIQUE,
		name       TEXT    NOT NULL UNIQUE COLLATE NOCASE,
		created_at INTEGER NOT NULL
	) STRICT;
	ALTER TABLE results ADD COLUMN user_id INTEGER REFERENCES users (id);
	ALTER TABLE results ADD COLUMN qgroup INTEGER NOT NULL DEFAULT -1;
	CREATE INDEX results_board ON results (mode, mode2, qgroup, language, punctuation, numbers, valid, user_id, wpm);
	CREATE INDEX results_by_user ON results (user_id, id);
	`,
}

db_open :: proc(db: ^Db, path: string) -> (err: string, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if open_v2(cpath, &db.conn, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
		return sql_error(db.conn), false
	}
	busy_timeout(db.conn, 5000)
	msg: cstring
	if exec(db.conn, SCHEMA, nil, nil, &msg) != SQLITE_OK {
		return string(msg), false
	}
	version := 0
	if st, pok := sql_prepare(db.conn, "PRAGMA user_version"); pok {
		if step(st) == SQLITE_ROW {
			version = int(column_int64(st, 0))
		}
		finalize(st)
	}
	for i in version ..< len(MIGRATIONS) {
		script := strings.concatenate({"BEGIN;", MIGRATIONS[i], "PRAGMA user_version = ", itoa(i + 1), "; COMMIT;"}, context.temp_allocator)
		if exec(db.conn, strings.clone_to_cstring(script, context.temp_allocator), nil, nil, &msg) != SQLITE_OK {
			exec(db.conn, "ROLLBACK", nil, nil, nil)
			return string(msg), false
		}
	}
	db.boards = make(map[string]Cached_Board, 16, runtime.heap_allocator())
	return "", true
}

@(private)
itoa :: proc(n: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_int(&b, n)
	return strings.to_string(b)
}

db_close :: proc(db: ^Db) {
	close_v2(db.conn)
}

// "ok" when SQLite's quick check passes.
db_check :: proc(db: ^Db) -> string {
	sync.guard(&db.lock)
	st, ok := sql_prepare(db.conn, "PRAGMA quick_check")
	if !ok {
		return sql_error(db.conn)
	}
	defer finalize(st)
	if step(st) != SQLITE_ROW {
		return sql_error(db.conn)
	}
	return sql_text(st, 0, context.temp_allocator)
}

record_sha :: proc(record: []u8, allocator := context.temp_allocator) -> string {
	c: sha2.Context_256
	sha2.init_256(&c)
	sha2.update(&c, record)
	digest: [32]u8
	sha2.final(&c, digest[:])
	return string(hex.encode(digest[:], allocator))
}

Stored :: struct {
	id:         i64,
	created_at: i64,
	setup:      engine.Setup,
	qgroup:     i32,
	wpm, raw:   f64,
	acc, cons:  f64,
	duration:   f64,
	valid:      bool,
	user_id:    i64,
	user_name:  string,
}

// ------ users

db_user_by_token :: proc(db: ^Db, sha: string, allocator := context.allocator) -> (User, bool) {
	sync.guard(&db.lock)
	st, ok := sql_prepare(db.conn, "SELECT id, name FROM users WHERE token_sha = ?", sha)
	if !ok {
		return {}, false
	}
	defer finalize(st)
	if step(st) != SQLITE_ROW {
		return {}, false
	}
	return User{id = column_int64(st, 0), name = sql_text(st, 1, allocator)}, true
}

// A new typist with a generated name (retried on the rare collision).
db_create_user :: proc(db: ^Db, sha: string, created_at: i64) -> (User, bool) {
	sync.guard(&db.lock)
	for _ in 0 ..< 8 {
		name := generated_name()
		rc := sql_exec(db.conn, "INSERT INTO users (token_sha, name, created_at) VALUES (?, ?, ?)", sha, name, created_at)
		if rc == SQLITE_DONE {
			return User{id = last_insert_rowid(db.conn), name = name}, true
		}
		if rc != SQLITE_CONSTRAINT {
			break
		}
	}
	return {}, false
}

Rename_Result :: enum {
	Renamed,
	Taken,
	Failed,
}

db_rename_user :: proc(db: ^Db, id: i64, name: string) -> Rename_Result {
	sync.guard(&db.lock)
	rc := sql_exec(db.conn, "UPDATE users SET name = ? WHERE id = ?", name, id)
	switch rc {
	case SQLITE_DONE:
		db.generation += 1
		return .Renamed
	case SQLITE_CONSTRAINT:
		return .Taken
	}
	return .Failed
}

// Gives every unclaimed result (saved before typists existed) to a new typist
// called `name`. Returns the new typist's token.
db_claim :: proc(db: ^Db, name: string, created_at: i64) -> (token: string, claimed: i64, ok: bool) {
	sync.guard(&db.lock)
	token = new_token()
	if sql_exec(db.conn, "INSERT INTO users (token_sha, name, created_at) VALUES (?, ?, ?)", token_sha(token), name, created_at) != SQLITE_DONE {
		return "", 0, false
	}
	id := last_insert_rowid(db.conn)
	if sql_exec(db.conn, "UPDATE results SET user_id = ? WHERE user_id IS NULL", id) != SQLITE_DONE {
		return "", 0, false
	}
	st, pok := sql_prepare(db.conn, "SELECT count(*) FROM results WHERE user_id = ?", id)
	if pok {
		if step(st) == SQLITE_ROW {
			claimed = column_int64(st, 0)
		}
		finalize(st)
	}
	db.generation += 1
	return token, claimed, true
}

// ------ results

// Inserts a result, or returns the existing id when the same record was
// already stored (an outbox retry after a lost response).
db_insert_result :: proc(db: ^Db, s: Stored, record: []u8) -> (id: i64, created: bool, ok: bool) {
	sync.guard(&db.lock)
	sha := record_sha(record)
	rc := sql_exec(
		db.conn,
		`INSERT INTO results (created_at, mode, mode2, language, punctuation, numbers, wpm, raw, acc, consistency, duration, valid, record_sha, record, user_id, qgroup)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		s.created_at,
		i64(s.setup.mode),
		i64(s.setup.mode2),
		s.setup.language,
		i64(1 if .Punctuation in s.setup.flags else 0),
		i64(1 if .Numbers in s.setup.flags else 0),
		s.wpm,
		s.raw,
		s.acc,
		s.cons,
		s.duration,
		i64(1 if s.valid else 0),
		sha,
		record,
		s.user_id,
		i64(s.qgroup),
	)
	if rc == SQLITE_DONE {
		db.generation += 1
		return last_insert_rowid(db.conn), true, true
	}
	if rc != SQLITE_CONSTRAINT {
		return 0, false, false
	}
	st, pok := sql_prepare(db.conn, "SELECT id FROM results WHERE record_sha = ?", sha)
	if !pok {
		return 0, false, false
	}
	defer finalize(st)
	if step(st) != SQLITE_ROW {
		return 0, false, false
	}
	return column_int64(st, 0), false, true
}

db_get_record :: proc(db: ^Db, id: i64, allocator := context.allocator) -> (record: []u8, s: Stored, ok: bool) {
	sync.guard(&db.lock)
	st, pok := sql_prepare(db.conn, "SELECT " + COLUMNS + ", r.record FROM results r LEFT JOIN users u ON u.id = r.user_id WHERE r.id = ?", id)
	if !pok {
		return nil, {}, false
	}
	defer finalize(st)
	if step(st) != SQLITE_ROW {
		return nil, {}, false
	}
	return sql_blob(st, 16, allocator), row_stored(st, allocator), true
}

COLUMNS :: "r.id, r.created_at, r.mode, r.mode2, r.language, r.punctuation, r.numbers, r.wpm, r.raw, r.acc, r.consistency, r.duration, r.valid, r.qgroup, r.user_id, u.name"

@(private)
row_stored :: proc(st: ^Stmt, allocator := context.allocator) -> Stored {
	s: Stored
	s.id = column_int64(st, 0)
	s.created_at = column_int64(st, 1)
	s.setup.mode = engine.Mode(column_int64(st, 2))
	s.setup.mode2 = i32(column_int64(st, 3))
	s.setup.language = sql_text(st, 4, allocator)
	if column_int64(st, 5) != 0 do s.setup.flags += {.Punctuation}
	if column_int64(st, 6) != 0 do s.setup.flags += {.Numbers}
	s.wpm = column_double(st, 7)
	s.raw = column_double(st, 8)
	s.acc = column_double(st, 9)
	s.cons = column_double(st, 10)
	s.duration = column_double(st, 11)
	s.valid = column_int64(st, 12) != 0
	s.qgroup = i32(column_int64(st, 13))
	s.user_id = column_int64(st, 14)
	s.user_name = sql_text(st, 15, allocator)
	return s
}

@(private)
collect :: proc(st: ^Stmt, allocator := context.allocator) -> []Stored {
	out := make([dynamic]Stored, allocator)
	for step(st) == SQLITE_ROW {
		append(&out, row_stored(st, allocator))
	}
	finalize(st)
	return out[:]
}

db_user_recent :: proc(db: ^Db, user_id: i64, limit: i64, allocator := context.allocator) -> []Stored {
	sync.guard(&db.lock)
	st, ok := sql_prepare(db.conn, "SELECT " + COLUMNS + " FROM results r LEFT JOIN users u ON u.id = r.user_id WHERE r.user_id = ? ORDER BY r.id DESC LIMIT ?", user_id, limit)
	return collect(st, allocator) if ok else nil
}

// A typist's best valid result for every test setup they have typed.
db_user_bests :: proc(db: ^Db, user_id: i64, allocator := context.allocator) -> []Stored {
	sync.guard(&db.lock)
	st, ok := sql_prepare(
		db.conn,
		`SELECT ` + COLUMNS + ` FROM (
		   SELECT r.*, ROW_NUMBER() OVER (
		     PARTITION BY r.mode, CASE WHEN r.mode = 2 THEN r.qgroup ELSE r.mode2 END, r.language, r.punctuation, r.numbers
		     ORDER BY r.wpm DESC, r.acc DESC, r.id ASC) AS rk
		   FROM results r WHERE r.user_id = ? AND r.valid = 1) r
		 LEFT JOIN users u ON u.id = r.user_id
		 WHERE rk = 1 ORDER BY r.mode, r.mode2, r.qgroup, r.language, r.punctuation, r.numbers`,
		user_id,
	)
	return collect(st, allocator) if ok else nil
}

// This typist's attempts at one quote, newest first.
db_quote_attempts :: proc(db: ^Db, user_id: i64, language: string, quote_id: i32, allocator := context.allocator) -> []Stored {
	sync.guard(&db.lock)
	st, ok := sql_prepare(
		db.conn,
		"SELECT " + COLUMNS + " FROM results r LEFT JOIN users u ON u.id = r.user_id WHERE r.user_id = ? AND r.mode = 2 AND r.language = ? AND r.mode2 = ? ORDER BY r.id DESC LIMIT 20",
		user_id,
		language,
		i64(quote_id),
	)
	return collect(st, allocator) if ok else nil
}

// ------ leaderboards

Board :: struct {
	mode:     engine.Mode, // .Time, .Words or .Quote
	mode2:    i32, // seconds or words
	qgroup:   i32, // quote length group
	language: string,
}

BOARD_SIZE :: 50

@(private)
board_key :: proc(b: Board, allocator := context.temp_allocator) -> string {
	k := strings.builder_make(allocator)
	strings.write_int(&k, int(b.mode))
	strings.write_byte(&k, '/')
	strings.write_int(&k, int(b.mode2 if b.mode != .Quote else b.qgroup))
	strings.write_byte(&k, '/')
	strings.write_string(&k, b.language)
	return strings.to_string(k)
}

// Each typist's best valid result for the board, fastest first. Plain tests
// only: no punctuation, no numbers. Served from the cache until a write.
db_board :: proc(db: ^Db, b: Board, allocator := context.allocator) -> []Stored {
	sync.guard(&db.lock)
	if st, ok := sql_prepare(db.conn, "PRAGMA data_version"); ok {
		if step(st) == SQLITE_ROW {
			if v := column_int64(st, 0); v != db.data_version {
				db.data_version = v
				db.generation += 1
			}
		}
		finalize(st)
	}
	key := board_key(b)
	if cached, ok := db.boards[key]; ok && cached.generation == db.generation {
		return copy_rows(cached.rows, allocator)
	}
	entry: Cached_Board
	if old, ok := db.boards[key]; ok {
		entry = old
		virtual.arena_destroy(&entry.arena)
		entry.arena = {}
	} else {
		key = strings.clone(key, runtime.heap_allocator())
	}
	_ = virtual.arena_init_growing(&entry.arena)
	alloc := virtual.arena_allocator(&entry.arena)
	where_clause := "r.mode = ? AND r.qgroup = ?" if b.mode == .Quote else "r.mode = ? AND r.mode2 = ?"
	second := i64(b.qgroup) if b.mode == .Quote else i64(b.mode2)
	st, ok := sql_prepare(
		db.conn,
		strings.concatenate(
			{
				`SELECT `,
				COLUMNS,
				` FROM (
				   SELECT r.*, ROW_NUMBER() OVER (PARTITION BY r.user_id ORDER BY r.wpm DESC, r.acc DESC, r.id ASC) AS rk
				   FROM results r
				   WHERE r.valid = 1 AND r.user_id IS NOT NULL AND r.punctuation = 0 AND r.numbers = 0 AND r.language = ? AND `,
				where_clause,
				`) r JOIN users u ON u.id = r.user_id
				 WHERE rk = 1 ORDER BY r.wpm DESC, r.acc DESC, r.id ASC LIMIT ?`,
			},
			context.temp_allocator,
		),
		b.language,
		i64(b.mode),
		second,
		i64(BOARD_SIZE),
	)
	entry.rows = collect(st, alloc) if ok else nil
	entry.generation = db.generation
	db.boards[key] = entry
	return copy_rows(entry.rows, allocator)
}

// Rows handed out of the cache are copies: another loop may rebuild it.
@(private)
copy_rows :: proc(rows: []Stored, allocator := context.allocator) -> []Stored {
	out := make([]Stored, len(rows), allocator)
	for r, i in rows {
		out[i] = r
		out[i].setup.language = strings.clone(r.setup.language, allocator)
		out[i].user_name = strings.clone(r.user_name, allocator)
	}
	return out
}
