package server

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import engine "../engine"

// All quote collections, loaded once. A browser's quote queue is a seeded
// shuffle of the selected length groups, dealt in windows: the server keeps no
// state, the queue never repeats until its pool is used up (as upstream), and
// the next quotes are already on the page when Tab restarts.

Quote_Collection :: struct {
	pack:   engine.Quote_Pack,
	counts: [engine.QUOTE_GROUPS]int,
}

g_quotes: map[string]^Quote_Collection
g_quote_languages: []string

QUOTE_ALL :: u32(0b1111)
QUOTE_DEFAULT :: u32(0b0010) // medium, upstream's default
DEAL :: 20

load_quotes :: proc() -> bool {
	path := strings.concatenate({g_packs, "/quotes.tsv"})
	index, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("serve: %s: %v (run ./build.sh pack)", path, err)
		return false
	}
	alloc := runtime.heap_allocator()
	g_quotes = make(map[string]^Quote_Collection, 128, alloc)
	names := make([dynamic]string, alloc)
	for line in strings.split_lines(string(index)) {
		fields := strings.split(line, "\t")
		if len(fields) != 6 {
			continue
		}
		name := strings.clone(fields[0], alloc)
		bytes, rerr := os.read_entire_file(strings.concatenate({g_packs, "/quotes/", name, ".bin"}), alloc)
		if rerr != nil {
			fmt.eprintfln("serve: quotes %s: %v", name, rerr)
			return false
		}
		c := new(Quote_Collection, alloc)
		ok: bool
		c.pack, ok = engine.quote_pack_view(bytes)
		if !ok {
			fmt.eprintfln("serve: quotes %s: bad pack", name)
			return false
		}
		for g in 0 ..< engine.QUOTE_GROUPS {
			c.counts[g], _ = strconv.parse_int(fields[2 + g])
		}
		g_quotes[name] = c
		append(&names, name)
	}
	g_quote_languages = names[:]
	return true
}

quote_collection :: proc(language: string) -> ^Quote_Collection {
	return g_quotes[engine.quote_language(language)]
}

// Indices of the quotes in the selected groups, in id order.
@(private)
quote_pool :: proc(c: ^Quote_Collection, groups: u32, allocator := context.temp_allocator) -> []u32 {
	n := 0
	for g in 0 ..< engine.QUOTE_GROUPS {
		if groups & (1 << u32(g)) != 0 {
			n += c.counts[g]
		}
	}
	pool := make([dynamic]u32, 0, n, allocator)
	for r, i in c.pack.records {
		if groups & (1 << r.group) != 0 {
			append(&pool, u32(i))
		}
	}
	return pool[:]
}

// Quotes at queue positions [from, from + n): each pass over the pool is its
// own shuffle, so the queue continues forever without early repeats.
deal_quotes :: proc(c: ^Quote_Collection, groups: u32, seed: u64, from, n: int, allocator := context.allocator) -> []engine.Quote {
	pool := quote_pool(c, groups)
	if len(pool) == 0 {
		return nil
	}
	out := make([]engine.Quote, n, allocator)
	pass := -1
	order := make([]u32, len(pool), context.temp_allocator)
	for k in 0 ..< n {
		pos := from + k
		if p := pos / len(pool); p != pass {
			pass = p
			copy(order, pool)
			rng: engine.Rng
			engine.rng_seed(&rng, seed + u64(pass) * 0x9E3779B97F4A7C15)
			for i := len(order) - 1; i > 0; i -= 1 {
				j := engine.rng_int(&rng, 0, i)
				order[i], order[j] = order[j], order[i]
			}
		}
		out[k] = engine.quote_at(&c.pack, int(order[pos % len(pool)]))
	}
	return out
}

write_quotes_json :: proc(b: ^strings.Builder, quotes: []engine.Quote) {
	strings.write_byte(b, '[')
	for q, i in quotes {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"id":`)
		strings.write_int(b, int(q.id))
		strings.write_string(b, `,"group":`)
		strings.write_int(b, int(q.group))
		strings.write_string(b, `,"text":`)
		engine.json_string(b, q.text)
		strings.write_string(b, `,"source":`)
		engine.json_string(b, q.source)
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

QUEUE_COOKIE :: "typer_queue"

// The browser's queue position: "<seed hex>.<position>".
parse_queue :: proc(v: string) -> (seed: u64, pos: int, ok: bool) {
	dot := strings.index_byte(v, '.')
	if dot <= 0 {
		return
	}
	s, sok := strconv.parse_u64(v[:dot], 16)
	p, pok := strconv.parse_int(v[dot + 1:], 10)
	if !sok || !pok || p < 0 {
		return
	}
	return s, p, true
}
