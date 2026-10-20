package server

import "base:runtime"
import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

// Typists without accounts: a browser gets an unguessable token in a cookie
// the first time it saves a result. Only the token's hash is stored. The same
// token, opened as a key link, carries the identity to another device.

ID_COOKIE :: "typer_id"
ID_COOKIE_MAX_AGE :: "63072000" // two years

User :: struct {
	id:   i64,
	name: string,
}

new_token :: proc(allocator := context.allocator) -> string {
	raw: [32]u8
	crypto.rand_bytes(raw[:])
	return string(hex.encode(raw[:], allocator))
}

token_sha :: proc(token: string, allocator := context.temp_allocator) -> string {
	c: sha2.Context_256
	sha2.init_256(&c)
	sha2.update(&c, transmute([]u8)token)
	digest: [32]u8
	sha2.final(&c, digest[:])
	return string(hex.encode(digest[:], allocator))
}

valid_token :: proc(token: string) -> bool {
	if len(token) != 64 {
		return false
	}
	for c in transmute([]u8)token {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// The user behind this request's cookie, if any.
current_user :: proc(req: ^Request) -> (User, string, bool) {
	token := cookie(req, ID_COOKIE)
	if !valid_token(token) {
		return {}, "", false
	}
	u, ok := db_user_by_token(&g_db, token_sha(token))
	return u, token, ok
}

id_cookie :: proc(token: string) -> string {
	secure := "; Secure" if strings.has_prefix(g_origin, "https://") else ""
	return strings.concatenate({ID_COOKIE, "=", token, "; Path=/; Max-Age=", ID_COOKIE_MAX_AGE, "; HttpOnly; SameSite=Lax", secure})
}

clear_id_cookie :: proc() -> string {
	return strings.concatenate({ID_COOKIE, "=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"})
}

key_link :: proc(token: string) -> string {
	return strings.concatenate({g_origin, "/key/", token})
}

NAME_MIN :: 2
NAME_MAX :: 24

// Names are what others see on the leaderboard: letters, digits, spaces and
// . - _ , collapsed and trimmed.
clean_name :: proc(raw: string, allocator := context.allocator) -> (string, bool) {
	b := strings.builder_make(0, len(raw), allocator)
	n := 0
	space := false
	for r in strings.trim_space(raw) {
		switch {
		case r == ' ' || r == '\t':
			space = true
			continue
		case unicode.is_letter(r) || unicode.is_digit(r) || r == '.' || r == '-' || r == '_':
		case:
			return "", false
		}
		if space && n > 0 {
			strings.write_byte(&b, ' ')
			n += 1
		}
		space = false
		strings.write_rune(&b, r)
		n += 1
	}
	name := strings.to_string(b)
	count := utf8.rune_count_in_string(name)
	return name, count >= NAME_MIN && count <= NAME_MAX
}

generated_name :: proc(allocator := context.allocator) -> string {
	alphabet := "abcdefghjkmnpqrstuvwxyz23456789"
	raw: [4]u8
	crypto.rand_bytes(raw[:])
	b := strings.builder_make(0, 12, allocator)
	strings.write_string(&b, "typist-")
	for x in raw {
		strings.write_byte(&b, alphabet[int(x) % len(alphabet)])
	}
	return strings.to_string(b)
}

// ------ rate limiting

// A token bucket per client address for the endpoints that write.
LIMIT_BURST :: 30.0
LIMIT_PER_SECOND :: 0.2 // a sustained 12 writes a minute

@(private)
Bucket :: struct {
	tokens: f64,
	last:   time.Tick,
}

@(private)
limiter: struct {
	lock:    sync.Mutex,
	buckets: map[string]Bucket,
	pruned:  time.Tick,
}

client_address :: proc(req: ^Request) -> string {
	xff := header(req, "x-forwarded-for")
	if xff == "" {
		return "local"
	}
	if c := strings.index_byte(xff, ','); c >= 0 {
		return strings.trim_space(xff[:c])
	}
	return strings.trim_space(xff)
}

allow_write :: proc(req: ^Request) -> bool {
	sync.guard(&limiter.lock)
	now := time.tick_now()
	if limiter.buckets == nil {
		limiter.buckets = make(map[string]Bucket, 64, runtime.heap_allocator())
		limiter.pruned = now
	}
	if time.tick_diff(limiter.pruned, now) > time.Hour {
		for k, v in limiter.buckets {
			if time.tick_diff(v.last, now) > time.Hour {
				delete_key(&limiter.buckets, k)
				delete(k, runtime.heap_allocator())
			}
		}
		limiter.pruned = now
	}
	addr := client_address(req)
	b, ok := limiter.buckets[addr]
	if !ok {
		b = Bucket{tokens = LIMIT_BURST, last = now}
		addr = strings.clone(addr, runtime.heap_allocator())
	}
	b.tokens = min(LIMIT_BURST, b.tokens + time.duration_seconds(time.tick_diff(b.last, now)) * LIMIT_PER_SECOND)
	b.last = now
	allowed := b.tokens >= 1
	if allowed {
		b.tokens -= 1
	}
	limiter.buckets[addr] = b
	return allowed
}
