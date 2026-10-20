package pack

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

import engine "../../src/engine"

// Converts upstream Monkeytype language lists into zero-parse binary packs
// (format in src/engine/pack.odin) plus an index for the server.
//
//   pack <upstream frontend/static dir> <out dir>

// Licensed by Dansk Sprog- og Litteraturselskab for use only with their permission.
EXCLUDED :: [?]string{"danish_1k", "danish_10k"}

main :: proc() {
	args := os.args
	if len(args) != 3 {
		fmt.eprintln("usage: pack <upstream frontend/static dir> <out dir>")
		os.exit(2)
	}
	src := strings.concatenate({args[1], "/languages"})
	out := args[2]
	if err := os.make_directory_all(strings.concatenate({out, "/lang"})); err != nil && err != .Exist {
		fmt.eprintfln("pack: create %s/lang: %v", out, err)
		os.exit(1)
	}

	files, err := os.read_all_directory_by_path(src, context.allocator)
	if err != nil {
		fmt.eprintfln("pack: read %s: %v", src, err)
		os.exit(1)
	}
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	keep := context.allocator
	index := strings.builder_make()
	packed := 0
	files_loop: for fi in files {
		if !strings.has_suffix(fi.name, ".json") {
			continue
		}
		name := fi.name[:len(fi.name) - 5]
		for x in EXCLUDED {
			if name == x {
				continue files_loop
			}
		}

		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)

		line, ok := pack_language(fi.fullpath, name, out, keep)
		if !ok {
			os.exit(1)
		}
		strings.write_string(&index, line)
		packed += 1
	}
	index_path := strings.concatenate({out, "/languages.tsv"})
	if werr := os.write_entire_file(index_path, strings.to_string(index)); werr != nil {
		fmt.eprintfln("pack: write %s: %v", index_path, werr)
		os.exit(1)
	}
	fmt.printfln("pack: %d languages -> %s", packed, out)
	pack_quotes(args[1], out, keep)
}

// Quote collections: one pack per language plus quotes.tsv with the number of
// quotes per length group.
pack_quotes :: proc(static_dir, out: string, keep: runtime.Allocator) {
	src := strings.concatenate({static_dir, "/quotes"})
	if err := os.make_directory_all(strings.concatenate({out, "/quotes"})); err != nil && err != .Exist {
		fmt.eprintfln("pack: create %s/quotes: %v", out, err)
		os.exit(1)
	}
	files, err := os.read_all_directory_by_path(src, context.allocator)
	if err != nil {
		fmt.eprintfln("pack: read %s: %v", src, err)
		os.exit(1)
	}
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	index := strings.builder_make(keep)
	total := 0
	for fi in files {
		if !strings.has_suffix(fi.name, ".json") {
			continue
		}
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		context.temp_allocator = context.allocator

		name := fi.name[:len(fi.name) - 5]
		data, rerr := os.read_entire_file(fi.fullpath, context.allocator)
		if rerr != nil {
			fmt.eprintfln("pack: read %s: %v", fi.fullpath, rerr)
			os.exit(1)
		}
		root, perr := json.parse(data)
		o, is_obj := root.(json.Object)
		list, is_arr := o["quotes"].(json.Array)
		if perr != .None || !is_obj || !is_arr {
			fmt.eprintfln("pack: %s: not a quote collection", fi.fullpath)
			os.exit(1)
		}
		groups: [engine.QUOTE_GROUPS][2]u32
		if gs, ok := o["groups"].(json.Array); ok && len(gs) == engine.QUOTE_GROUPS {
			for g, i in gs {
				pair, _ := g.(json.Array)
				if len(pair) != 2 {
					fmt.eprintfln("pack: %s: bad groups", fi.fullpath)
					os.exit(1)
				}
				groups[i] = {u32(number(pair[0])), u32(number(pair[1]))}
			}
		} else {
			fmt.eprintfln("pack: %s: no groups", fi.fullpath)
			os.exit(1)
		}
		quotes := make([dynamic]engine.Quote, 0, len(list))
		counts: [engine.QUOTE_GROUPS]int
		for q in list {
			qo, _ := q.(json.Object)
			text, _ := qo["text"].(json.String)
			source, _ := qo["source"].(json.String)
			group := engine.quote_group(groups, u32(number(qo["length"])))
			counts[group] += 1
			append(&quotes, engine.Quote{id = u32(number(qo["id"])), group = group, text = engine.quote_normalize(string(text)), source = string(source)})
		}
		slice.sort_by(quotes[:], proc(a, b: engine.Quote) -> bool {return a.id < b.id})
		bytes := engine.quote_pack_encode(name, groups, quotes[:])
		bin := fmt.tprintf("%s/quotes/%s.bin", out, name)
		if werr := os.write_entire_file(bin, bytes); werr != nil {
			fmt.eprintfln("pack: write %s: %v", bin, werr)
			os.exit(1)
		}
		fmt.sbprintf(&index, "%s\t%d\t%d\t%d\t%d\t%d\n", name, len(quotes), counts[0], counts[1], counts[2], counts[3])
		total += len(quotes)
	}
	index_path := strings.concatenate({out, "/quotes.tsv"}, context.temp_allocator)
	if werr := os.write_entire_file(index_path, strings.to_string(index)); werr != nil {
		fmt.eprintfln("pack: write %s: %v", index_path, werr)
		os.exit(1)
	}
	fmt.printfln("pack: %d quotes -> %s/quotes", total, out)
}

number :: proc(v: json.Value) -> f64 {
	#partial switch x in v {
	case json.Float:
		return f64(x)
	case json.Integer:
		return f64(x)
	}
	return 0
}

// Returns the index line "name\tword_count\tflags\n".
pack_language :: proc(path, name, out: string, keep: runtime.Allocator) -> (string, bool) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("pack: read %s: %v", path, rerr)
		return "", false
	}
	root, perr := json.parse(data)
	if perr != .None {
		fmt.eprintfln("pack: parse %s: %v", path, perr)
		return "", false
	}
	o, is_obj := root.(json.Object)
	words, is_arr := o["words"].(json.Array)
	if !is_obj || !is_arr {
		fmt.eprintfln("pack: %s: no words array", path)
		return "", false
	}
	flag :: proc(o: json.Object, key: string) -> bool {
		b, _ := o[key].(json.Boolean)
		return bool(b)
	}
	flags: engine.Pack_Flags
	if flag(o, "rightToLeft") do flags += {.Right_To_Left}
	if flag(o, "orderedByFrequency") do flags += {.Ordered_By_Frequency}
	if flag(o, "noLazyMode") do flags += {.No_Lazy_Mode}
	if flag(o, "joiningScript") do flags += {.Joining_Script}

	list := make([]string, len(words))
	for w, i in words {
		s, _ := w.(json.String)
		list[i] = string(s)
	}
	bytes := engine.pack_encode(name, flags, list)
	bin := fmt.tprintf("%s/lang/%s.bin", out, name)
	if werr := os.write_entire_file(bin, bytes); werr != nil {
		fmt.eprintfln("pack: write %s: %v", bin, werr)
		return "", false
	}
	return fmt.aprintf("%s\t%d\t%d\n", name, len(list), transmute(u32)flags, allocator = keep), true
}
