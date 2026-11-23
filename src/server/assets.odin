package server

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:strings"
import "core:strconv"

// Assets compiled into the binary, served under content-hashed URLs so they
// are cached forever. Text assets carry brotli and gzip variants made at build
// time, so nothing is compressed per request. build.sh hashes the fonts the
// same way and writes their URLs into the stylesheet before compressing it.

Asset :: struct {
	name: string,
	type: string,
	raw:  []u8,
	br:   []u8,
	gz:   []u8,
	url:  string,
}

assets := [?]Asset {
	{name = "island.js", type = "text/javascript; charset=utf-8", raw = #load("../../build/web/island.js"), br = #load("../../build/web/island.js.br"), gz = #load("../../build/web/island.js.gz")},
	{name = "app.js", type = "text/javascript; charset=utf-8", raw = #load("../../build/web/app.js"), br = #load("../../build/web/app.js.br"), gz = #load("../../build/web/app.js.gz")},
	{name = "app.css", type = "text/css; charset=utf-8", raw = #load("../../build/web/app.css"), br = #load("../../build/web/app.css.br"), gz = #load("../../build/web/app.css.gz")},
	{name = "core.wasm", type = "application/wasm", raw = #load("../../build/web/core.wasm"), br = #load("../../build/web/core.wasm.br"), gz = #load("../../build/web/core.wasm.gz")},
	{name = "DMMono-latin.woff2", type = "font/woff2", raw = #load("../../web/fonts/DMMono-latin.woff2")},
	{name = "DMMono-latin-ext.woff2", type = "font/woff2", raw = #load("../../web/fonts/DMMono-latin-ext.woff2")},
	{name = "Quando-latin.woff2", type = "font/woff2", raw = #load("../../web/fonts/Quando-latin.woff2")},
}

@(private)
hashed_url :: proc(name: string, data: []u8) -> string {
	c: sha2.Context_256
	sha2.init_256(&c)
	sha2.update(&c, data)
	digest: [32]u8
	sha2.final(&c, digest[:])
	dot := strings.index_byte(name, '.')
	return strings.concatenate({"/assets/", name[:dot], ".", string(hex.encode(digest[:5])), name[dot:]})
}

assets_init :: proc() {
	for &a in assets {
		a.url = hashed_url(a.name, a.raw)
	}
}

asset_url :: proc(name: string) -> string {
	for a in assets {
		if a.name == name {
			return a.url
		}
	}
	return ""
}

encoding_quality :: proc(value, encoding: string) -> f64 {
	wildcard := 0.0
	for part in strings.split(value, ",") {
		fields := strings.split(part, ";")
		name := strings.trim_space(fields[0])
		q := 1.0
		for field in fields[1:] {
			param := strings.trim_space(field)
			eq := strings.index_byte(param, '=')
			if eq > 0 && strings.equal_fold(param[:eq], "q") {
				num, ok := strconv.parse_f64(param[eq+1:])
				q = num if ok && num >= 0 && num <= 1 else 0
			}
		}
		if strings.equal_fold(name, encoding) do return q
		if name == "*" do wildcard = q
	}
	return wildcard
}

serve_asset :: proc(req: ^Request, res: ^Response) -> bool {
	for a in assets {
		if a.url != req.path {
			continue
		}
		accept := header(req, "accept-encoding")
		res.shared_body = true
		res.type = a.type
		res.cache = "public, max-age=31536000, immutable"
		br, gz := encoding_quality(accept, "br"), encoding_quality(accept, "gzip")
		if a.br != nil || a.gz != nil do set_header(res, "vary", "accept-encoding")
		switch {
		case a.br != nil && br > 0 && (a.gz == nil || br >= gz):
			res.body = a.br
			res.encoding = "br"
		case a.gz != nil && gz > 0:
			res.body = a.gz
			res.encoding = "gzip"
		case:
			res.body = a.raw
		}
		return true
	}
	return false
}
