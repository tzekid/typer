package engine

import "core:math"
import "core:strings"

// The result panel and its chart. The island renders it the moment a test
// ends; the server renders the same HTML for /results/:id from the stored
// record, so there is one implementation of what a result looks like.

Result_View :: struct {
	result:       Result,
	setup:        Setup,
	invalid:      string, // why the test does not count, empty if valid
	id:           i64, // server-side id, 0 in the island
	finished_at:  string, // server-side, ISO date
	typist:       string, // server-side, display name
	quote_group:  i32, // quote mode
	quote_source: string,
}

mode_label :: proc(b: ^strings.Builder, s: Setup) {
	switch s.mode {
	case .Time:
		strings.write_string(b, "time ")
		strings.write_int(b, int(s.mode2))
	case .Words:
		strings.write_string(b, "words ")
		strings.write_int(b, int(s.mode2))
	case .Quote:
		strings.write_string(b, "quote")
	case .Zen:
		strings.write_string(b, "zen")
	case .Custom:
		strings.write_string(b, "custom")
	}
}

@(private)
// tip: the exact value, shown on hover (styled in app.css, no script).
stat :: proc(b: ^strings.Builder, label: string, value: string, tip: string = "") {
	strings.write_string(b, `<div class="stat"><div class="label">`)
	html_text(b, label)
	strings.write_string(b, `</div><div class="value"`)
	if tip != "" {
		strings.write_string(b, ` data-tip="`)
		html_attr(b, tip)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, '>')
	html_text(b, value)
	strings.write_string(b, `</div></div>`)
}

@(private)
fixed :: proc(v: f64, decimals: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, 16, allocator)
	write_fixed(&b, v, decimals)
	return strings.to_string(b)
}

render_result :: proc(b: ^strings.Builder, v: Result_View) {
	r := v.result
	strings.write_string(b, `<section class="result"><div class="big">`)
	t := context.temp_allocator
	stat(b, "wpm", fixed(js_round(r.wpm), 0), strings.concatenate({fixed(r.wpm, 2), " wpm"}, t))
	stat(b, "acc", strings.concatenate({fixed(js_round(r.acc), 0), "%"}, t), strings.concatenate({fixed(r.acc, 2), "% accuracy"}, t))
	strings.write_string(b, `</div>`)
	render_chart(b, r)

	strings.write_string(b, `<div class="more">`)
	test_type := strings.builder_make(context.temp_allocator)
	mode_label(&test_type, v.setup)
	if v.setup.mode == .Quote && v.quote_group >= 0 && v.quote_group < QUOTE_GROUPS {
		strings.write_byte(&test_type, ' ')
		strings.write_string(&test_type, QUOTE_GROUP_NAMES[v.quote_group])
	}
	strings.write_byte(&test_type, ' ')
	strings.write_string(&test_type, v.setup.language)
	if .Punctuation in v.setup.flags do strings.write_string(&test_type, " punctuation")
	if .Numbers in v.setup.flags do strings.write_string(&test_type, " numbers")
	stat(b, "test type", strings.to_string(test_type))
	stat(b, "raw", fixed(js_round(r.raw_wpm), 0), strings.concatenate({fixed(r.raw_wpm, 2), " wpm, errors included"}, t))

	cs := strings.builder_make(context.temp_allocator)
	for x, i in r.char_stats {
		if i > 0 do strings.write_byte(&cs, '/')
		strings.write_int(&cs, int(x))
	}
	stat(b, "characters", strings.to_string(cs), "correct / incorrect / extra / missed")
	stat(b, "consistency", strings.concatenate({fixed(js_round(r.consistency), 0), "%"}, t), strings.concatenate({fixed(r.consistency, 2), "% · keys ", fixed(r.key_consistency, 2), "%"}, t))
	stat(b, "time", strings.concatenate({fixed(js_round(r.test_duration), 0), "s"}, t), strings.concatenate({fixed(r.test_duration, 2), "s"}, t))
	if r.afk_duration > 0 {
		stat(b, "afk", strings.concatenate({fixed(f64(r.afk_duration), 0), "s"}, t))
	}
	strings.write_string(b, `</div>`)
	if v.setup.mode == .Quote && v.quote_source != "" {
		strings.write_string(b, `<p class="source"><span class="label">source</span> `)
		html_text(b, v.quote_source)
		strings.write_string(b, `</p>`)
	}
	if v.invalid != "" {
		strings.write_string(b, `<p class="invalid">`)
		html_text(b, v.invalid)
		strings.write_string(b, `</p>`)
	}
	if v.finished_at != "" {
		strings.write_string(b, `<p class="when">`)
		if v.typist != "" {
			html_text(b, v.typist)
			strings.write_string(b, ` · `)
		}
		html_text(b, v.finished_at)
		strings.write_string(b, `</p>`)
	}
	strings.write_string(b, `</section>`)
}

@(private)
slice_has_positive :: proc(vals: []f64) -> bool {
	for v in vals {
		if v > 0 do return true
	}
	return false
}

// Top of the axis: four equal steps of 1, 2, 2.5 or 5 times a power of ten.
@(private)
nice_ceiling :: proc(v: f64) -> f64 {
	if v <= 20 {
		return 20
	}
	raw := v / 4
	mag := math.pow(10, math.floor(math.log10(raw)))
	for m in ([?]f64{1, 2, 2.5, 5, 10}) {
		if m * mag >= raw {
			return m * mag * 4
		}
	}
	return 10 * mag * 4
}

CHART_W :: 640.0
CHART_H :: 200.0
CHART_PAD_L :: 36.0
CHART_PAD_R :: 28.0
CHART_PAD_T :: 10.0
CHART_PAD_B :: 22.0

// Speed per second (wpm, raw, burst) against the left axis, errors as crosses
// against the right one; geometry in a fixed viewBox, colours from CSS. The
// series ride along as data attributes for app.js's hover readout.
render_chart :: proc(b: ^strings.Builder, r: Result) {
	n := len(r.chart_wpm)
	if n == 0 {
		return
	}
	top := 0.0
	for v in r.chart_wpm do top = max(top, v)
	for v in r.chart_raw do top = max(top, v)
	for v in r.chart_burst do top = max(top, v)
	top = nice_ceiling(top)
	err_top := 1.0
	for v in r.chart_err do err_top = max(err_top, v)

	plot_h := CHART_H - CHART_PAD_T - CHART_PAD_B
	base := CHART_PAD_T + plot_h
	x_of :: proc(i, n: int) -> f64 {
		plot_w := CHART_W - CHART_PAD_L - CHART_PAD_R
		if n == 1 {
			return CHART_PAD_L + plot_w / 2
		}
		return CHART_PAD_L + f64(i) / f64(n - 1) * plot_w
	}
	y_of :: proc(v, top: f64) -> f64 {
		plot_h := CHART_H - CHART_PAD_T - CHART_PAD_B
		return CHART_PAD_T + plot_h - plot_h * min(v, top) / top
	}
	series :: proc(b: ^strings.Builder, name: string, vals: []f64) {
		strings.write_string(b, ` data-`)
		strings.write_string(b, name)
		strings.write_string(b, `="`)
		for v, i in vals {
			if i > 0 do strings.write_byte(b, ',')
			write_fixed(b, v, 0)
		}
		strings.write_byte(b, '"')
	}

	strings.write_string(b, `<figure class="chart-box" data-top="`)
	write_fixed(b, top, 0)
	strings.write_string(b, `" data-err-top="`)
	write_fixed(b, err_top, 0)
	strings.write_byte(b, '"')
	series(b, "wpm", r.chart_wpm)
	series(b, "raw", r.chart_raw)
	series(b, "burst", r.chart_burst)
	series(b, "err", r.chart_err)
	strings.write_string(b, `><svg class="chart" viewBox="0 0 640 200" role="img" aria-label="speed per second">`)
	// horizontal grid + left labels
	for k in 0 ..= 4 {
		v := top * f64(k) / 4
		y := base - plot_h * f64(k) / 4
		strings.write_string(b, `<line class="grid" x1="`)
		write_fixed(b, CHART_PAD_L, 1)
		strings.write_string(b, `" x2="`)
		write_fixed(b, CHART_W - CHART_PAD_R, 1)
		strings.write_string(b, `" y1="`)
		write_fixed(b, y, 1)
		strings.write_string(b, `" y2="`)
		write_fixed(b, y, 1)
		strings.write_string(b, `"/><text class="axis" x="`)
		write_fixed(b, CHART_PAD_L - 6, 1)
		strings.write_string(b, `" y="`)
		write_fixed(b, y + 4, 1)
		strings.write_string(b, `" text-anchor="end">`)
		strings.write_int(b, int(v))
		strings.write_string(b, `</text>`)
	}
	// right axis: errors per second, when there were any
	if err_top > 1 || slice_has_positive(r.chart_err) {
		for k in ([?]f64{0, 1}) {
			strings.write_string(b, `<text class="axis err-axis" x="`)
			write_fixed(b, CHART_W - CHART_PAD_R + 6, 1)
			strings.write_string(b, `" y="`)
			write_fixed(b, base - plot_h * k + 4, 1)
			strings.write_string(b, `">`)
			strings.write_int(b, int(err_top * k))
			strings.write_string(b, `</text>`)
		}
	}
	// x labels
	every := 1 if n <= 15 else 5 if n <= 60 else 10
	for i in 0 ..< n {
		if (i + 1) % every != 0 && i != 0 {
			continue
		}
		strings.write_string(b, `<text class="axis" x="`)
		write_fixed(b, x_of(i, n), 1)
		strings.write_string(b, `" y="`)
		write_fixed(b, CHART_H - 6, 1)
		strings.write_string(b, `" text-anchor="middle">`)
		strings.write_int(b, i + 1)
		strings.write_string(b, `</text>`)
	}
	points :: proc(b: ^strings.Builder, vals: []f64, top: f64, n: int) {
		for v, i in vals {
			if i > 0 do strings.write_byte(b, ' ')
			write_fixed(b, x_of(i, n), 1)
			strings.write_byte(b, ',')
			write_fixed(b, y_of(v, top), 1)
		}
	}
	// burst: a soft area under its line, drawn first so the rest sits on top
	if len(r.chart_burst) > 0 {
		strings.write_string(b, `<polygon class="burst-area" points="`)
		write_fixed(b, x_of(0, n), 1)
		strings.write_byte(b, ',')
		write_fixed(b, base, 1)
		strings.write_byte(b, ' ')
		points(b, r.chart_burst, top, n)
		strings.write_byte(b, ' ')
		write_fixed(b, x_of(len(r.chart_burst) - 1, n), 1)
		strings.write_byte(b, ',')
		write_fixed(b, base, 1)
		strings.write_string(b, `"/>`)
	}
	for line in ([?]struct {
			class: string,
			vals:  []f64,
		}{{"burst", r.chart_burst}, {"raw", r.chart_raw}, {"wpm", r.chart_wpm}}) {
		strings.write_string(b, `<polyline class="`)
		strings.write_string(b, line.class)
		strings.write_string(b, `" points="`)
		points(b, line.vals, top, n)
		strings.write_string(b, `"/>`)
	}
	for v, i in r.chart_err {
		if v <= 0 {
			continue
		}
		x := x_of(i, n)
		y := base - plot_h * v / err_top
		strings.write_string(b, `<path class="err" d="M`)
		write_fixed(b, x - 3, 1)
		strings.write_byte(b, ' ')
		write_fixed(b, y - 3, 1)
		strings.write_string(b, `l6 6m0 -6l-6 6"/>`)
	}
	// hover readout, positioned by app.js
	strings.write_string(b, `<g class="hover"><line class="guide" y1="`)
	write_fixed(b, CHART_PAD_T, 1)
	strings.write_string(b, `" y2="`)
	write_fixed(b, base, 1)
	strings.write_string(b, `"/><circle class="dot burst" r="3"/><circle class="dot raw" r="3"/><circle class="dot wpm" r="3.5"/></g></svg>`)
	strings.write_string(b, `<div class="tip" aria-hidden="true"></div><div class="legend">`)
	for item in ([?][2]string{{"raw", "raw"}, {"burst", "burst"}, {"err", "errors"}}) {
		strings.write_string(b, `<button type="button" data-series="`)
		strings.write_string(b, item[0])
		strings.write_string(b, `"><i class="swatch `)
		strings.write_string(b, item[0])
		strings.write_string(b, `"></i>`)
		strings.write_string(b, item[1])
		strings.write_string(b, `</button>`)
	}
	strings.write_string(b, `</div></figure>`)
}
