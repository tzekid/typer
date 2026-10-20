package engine

// Language pack: built once by tools/pack, read by a bounds-checked view into
// the bytes (no parsing, no copying). Little endian.
//
//   0   "TYL1"
//   4   u32 flags (Pack_Flags)
//   8   u32 word count N
//   12  u32 name length L, then the name, zero-padded to 4 bytes
//   ..  u32 offsets[N + 1] into the blob
//   ..  UTF-8 blob

PACK_MAGIC :: "TYL1"

Pack_Flag :: enum u32 {
	Right_To_Left,
	Ordered_By_Frequency,
	No_Lazy_Mode,
	Joining_Script,
}
Pack_Flags :: bit_set[Pack_Flag;u32]

@(private)
put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
get_u32 :: proc "contextless" (b: []u8, at: int) -> u32 {
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

pack_encode :: proc(name: string, flags: Pack_Flags, words: []string, allocator := context.allocator) -> []u8 {
	b := make([dynamic]u8, 0, 64, allocator)
	append(&b, PACK_MAGIC)
	put_u32(&b, transmute(u32)flags)
	put_u32(&b, u32(len(words)))
	put_u32(&b, u32(len(name)))
	append(&b, name)
	for len(b) % 4 != 0 {
		append(&b, 0)
	}
	off: u32
	put_u32(&b, 0)
	for w in words {
		off += u32(len(w))
		put_u32(&b, off)
	}
	for w in words {
		append(&b, w)
	}
	return b[:]
}

Pack :: struct {
	list:  Word_List,
	flags: Pack_Flags,
}

// Validates the header and offsets, then views the bytes in place. The bytes
// must be 4-byte aligned (heap and wasm allocations are).
pack_view :: proc(data: []u8) -> (p: Pack, ok: bool) {
	if len(data) < 16 || string(data[:4]) != PACK_MAGIC {
		return {}, false
	}
	p.flags = transmute(Pack_Flags)get_u32(data, 4)
	n := int(get_u32(data, 8))
	name_len := int(get_u32(data, 12))
	at := 16 + name_len
	if at > len(data) {
		return {}, false
	}
	name := string(data[16:at])
	for at % 4 != 0 {
		at += 1
	}
	offsets_end := at + (n + 1) * 4
	if n < 0 || offsets_end > len(data) || uintptr(raw_data(data)) % 4 != 0 {
		return {}, false
	}
	offsets := ([^]u32)(raw_data(data[at:]))[:n + 1]
	blob := data[offsets_end:]
	prev: u32
	for o in offsets {
		if o < prev || int(o) > len(blob) {
			return {}, false
		}
		prev = o
	}
	p.list = Word_List {
		name                 = name,
		offsets              = offsets,
		blob                 = blob,
		rtl                  = .Right_To_Left in p.flags,
		ordered_by_frequency = .Ordered_By_Frequency in p.flags,
	}
	return p, true
}
