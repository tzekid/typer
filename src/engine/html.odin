package engine

import "core:strings"

// Minimal HTML escaping for renderers shared by the server and the island.

html_text :: proc(b: ^strings.Builder, s: string) {
	for r in s {
		switch r {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case:
			strings.write_rune(b, r)
		}
	}
}

// Attribute values are always written double-quoted by the callers.
html_attr :: proc(b: ^strings.Builder, s: string) {
	for r in s {
		switch r {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\'':
			strings.write_string(b, "&#39;")
		case:
			strings.write_rune(b, r)
		}
	}
}

// JSON string literal safe to place inside a <script> element.
json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '<':
			strings.write_string(b, "\\u003c")
		case '>':
			strings.write_string(b, "\\u003e")
		case '&':
			strings.write_string(b, "\\u0026")
		case 0x2028:
			strings.write_string(b, "\\u2028")
		case 0x2029:
			strings.write_string(b, "\\u2029")
		case:
			if r < 0x20 {
				strings.write_string(b, "\\u00")
				hex := "0123456789abcdef"
				strings.write_byte(b, hex[r >> 4])
				strings.write_byte(b, hex[r & 0xF])
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}

write_fixed :: proc(b: ^strings.Builder, v: f64, decimals: int) {
	strings.write_float(b, v, 'f', decimals, 64)
}
