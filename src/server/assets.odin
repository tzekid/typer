package server

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:strings"

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
	{name = "theme.js", type = "text/javascript; charset=utf-8", raw = #load("../../build/web/theme.js"), br = #load("../../build/web/theme.js.br"), gz = #load("../../build/web/theme.js.gz")},
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

serve_asset :: proc(req: ^Request, res: ^Response) -> bool {
	for a in assets {
		if a.url != req.path {
			continue
		}
		accept := header(req, "accept-encoding")
		res.type = a.type
		res.cache = "public, max-age=31536000, immutable"
		switch {
		case a.br != nil && strings.contains(accept, "br"):
			res.body = a.br
			res.encoding = "br"
		case a.gz != nil && strings.contains(accept, "gzip"):
			res.body = a.gz
			res.encoding = "gzip"
		case:
			res.body = a.raw
		}
		return true
	}
	return false
}
