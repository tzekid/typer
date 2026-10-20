package server

import "core:strings"

// The handful of SQLite C functions typer uses, from the system library.

foreign import sqlite "system:sqlite3"

Sqlite :: struct {}
Stmt :: struct {}

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
SQLITE_CONSTRAINT :: 19
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE :: 0x00000004
SQLITE_TRANSIENT :: ~uintptr(0)

@(default_calling_convention = "c", link_prefix = "sqlite3_")
foreign sqlite {
	open_v2 :: proc(filename: cstring, db: ^^Sqlite, flags: i32, vfs: cstring) -> i32 ---
	close_v2 :: proc(db: ^Sqlite) -> i32 ---
	exec :: proc(db: ^Sqlite, sql: cstring, cb: rawptr, arg: rawptr, errmsg: ^cstring) -> i32 ---
	errmsg :: proc(db: ^Sqlite) -> cstring ---
	busy_timeout :: proc(db: ^Sqlite, ms: i32) -> i32 ---
	prepare_v2 :: proc(db: ^Sqlite, sql: [^]u8, n: i32, stmt: ^^Stmt, tail: ^[^]u8) -> i32 ---
	bind_int64 :: proc(s: ^Stmt, i: i32, v: i64) -> i32 ---
	bind_double :: proc(s: ^Stmt, i: i32, v: f64) -> i32 ---
	bind_text :: proc(s: ^Stmt, i: i32, v: [^]u8, n: i32, destructor: uintptr) -> i32 ---
	bind_blob :: proc(s: ^Stmt, i: i32, v: rawptr, n: i32, destructor: uintptr) -> i32 ---
	step :: proc(s: ^Stmt) -> i32 ---
	finalize :: proc(s: ^Stmt) -> i32 ---
	column_int64 :: proc(s: ^Stmt, i: i32) -> i64 ---
	column_double :: proc(s: ^Stmt, i: i32) -> f64 ---
	column_text :: proc(s: ^Stmt, i: i32) -> [^]u8 ---
	column_blob :: proc(s: ^Stmt, i: i32) -> rawptr ---
	column_bytes :: proc(s: ^Stmt, i: i32) -> i32 ---
	last_insert_rowid :: proc(db: ^Sqlite) -> i64 ---
}

Sql_Value :: union {
	i64,
	f64,
	string,
	[]u8,
}

// Prepared statement with its parameters bound in order (1-based).
sql_prepare :: proc(db: ^Sqlite, sql: string, args: ..Sql_Value) -> (^Stmt, bool) {
	st: ^Stmt
	if prepare_v2(db, raw_data(sql), i32(len(sql)), &st, nil) != SQLITE_OK {
		return nil, false
	}
	for a, i in args {
		idx := i32(i + 1)
		rc: i32
		switch v in a {
		case i64:
			rc = bind_int64(st, idx, v)
		case f64:
			rc = bind_double(st, idx, v)
		case string:
			rc = bind_text(st, idx, raw_data(v), i32(len(v)), SQLITE_TRANSIENT)
		case []u8:
			rc = bind_blob(st, idx, raw_data(v), i32(len(v)), SQLITE_TRANSIENT)
		}
		if rc != SQLITE_OK {
			finalize(st)
			return nil, false
		}
	}
	return st, true
}

// Runs a statement that returns no rows; the result code is returned.
sql_exec :: proc(db: ^Sqlite, sql: string, args: ..Sql_Value) -> i32 {
	st, ok := sql_prepare(db, sql, ..args)
	if !ok {
		return -1
	}
	defer finalize(st)
	return step(st)
}

sql_text :: proc(st: ^Stmt, col: i32, allocator := context.allocator) -> string {
	p := column_text(st, col)
	n := column_bytes(st, col)
	if p == nil || n <= 0 {
		return ""
	}
	return strings.clone(string(p[:n]), allocator)
}

sql_blob :: proc(st: ^Stmt, col: i32, allocator := context.allocator) -> []u8 {
	p := ([^]u8)(column_blob(st, col))
	n := column_bytes(st, col)
	if p == nil || n <= 0 {
		return nil
	}
	out := make([]u8, int(n), allocator)
	copy(out, p[:n])
	return out
}

sql_error :: proc(db: ^Sqlite) -> string {
	return string(errmsg(db))
}
