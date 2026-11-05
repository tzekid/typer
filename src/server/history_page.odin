package server

import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

import engine "../engine"

history_href :: proc(b: ^strings.Builder, g: ^History_Group, page: int = 0) {
	w(b, "/history?setup=")
	engine.html_attr(b, url_encode(history_setup_key(g.setup)))
	if page > 0 {
		w(b, "&amp;page=")
		strings.write_int(b, page)
	}
}

history_number :: proc(b: ^strings.Builder, value: f64, decimals: int = 1) {
	engine.write_fixed(b, value, decimals)
}

history_stat :: proc(b: ^strings.Builder, label: string, value: f64, unit: string, metric: string) {
	w(b, `<div><dt>`)
	w(b, label)
	w(b, `</dt><dd data-metric="`)
	w(b, metric)
	w(b, `">`)
	history_number(b, value)
	w(b, `<small>`)
	w(b, unit)
	w(b, `</small></dd></div>`)
}

history_count :: proc(b: ^strings.Builder, n: int, singular, plural: string) {
	strings.write_int(b, n)
	w(b, " ")
	w(b, singular if n == 1 else plural)
}

history_weak_key :: proc(g: ^History_Group) -> (weak: Key_Analysis, measured: int) {
	for _, k in g.keys {
		if k.attempts < 20 do continue
		measured += 1
		if k.errors == 0 do continue
		if weak.attempts == 0 || f64(k.errors) / f64(k.attempts) > f64(weak.errors) / f64(weak.attempts) || f64(k.errors) / f64(k.attempts) == f64(weak.errors) / f64(weak.attempts) && k.key < weak.key do weak = k
	}
	return
}

history_pace_difference :: proc(g: ^History_Group) -> f64 {
	if g.pace_tests < 10 do return 0
	return 100 * f64(g.errors[2]) / f64(g.thirds[2]) - 100 * f64(g.errors[0]) / f64(g.thirds[0])
}

render_history_findings :: proc(b: ^strings.Builder, g: ^History_Group) {
	n := len(g.valid)
	weak, measured := history_weak_key(g)
	w(b, `<section class="history-discoveries" aria-label="What your tests show"><p class="history-lead" data-metric="speed-finding">`)
	if n >= 20 {
		first, last := history_mean(g.valid[:10]), history_mean(g.valid[n - 10:])
		delta := last - first
		if math.round(abs(delta) * 10) == 0 {
			w(b, `Your latest 10 tests average `)
			history_number(b, last)
			w(b, ` wpm. Your first 10 are within 0.1 wpm.`)
		} else {
			w(b, `Your latest 10 tests are `)
			history_number(b, abs(delta))
			w(b, ` wpm faster` if delta > 0 else ` wpm slower`)
			w(b, ` than your first 10.`)
		}
	} else if n == 1 {
		w(b, `Your first test is `)
		history_number(b, g.wpm)
		w(b, ` wpm at `)
		history_number(b, g.acc)
		w(b, `% accuracy.`)
	} else {
		w(b, `Your `)
		history_count(b, n, "test averages", "tests average")
		w(b, ` `)
		history_number(b, g.wpm)
		w(b, ` wpm at `)
		history_number(b, g.acc)
		w(b, `% accuracy.`)
	}
	w(b, `</p>`)
	if g.analysed >= 5 && weak.attempts > 0 {
		w(b, `<p class="history-observation">`)
		engine.html_text(b, analysis_key_text(weak.key))
		w(b, ` is your least accurate measured key, with `)
		history_number(b, 100 * f64(weak.errors) / f64(weak.attempts))
		w(b, `% missed in `)
		history_count(b, int(weak.attempts), "attempt", "attempts")
		w(b, `.</p>`)
	} else if g.analysed >= 5 && measured > 0 {
		w(b, `<p class="history-observation">No errors in the `)
		history_count(b, measured, "key", "keys")
		w(b, ` with at least 20 attempts.</p>`)
	}
	difference := history_pace_difference(g)
	if abs(difference) >= 1 {
		w(b, `<p class="history-observation">Accuracy `)
		w(b, "falls " if difference > 0 else "rises ")
		history_number(b, abs(difference))
		w(b, ` percentage points from the first to the last third, across `)
		history_count(b, g.pace_tests, "test", "tests")
		w(b, `.</p>`)
	}
	w(b, `</section>`)
}

render_history_page :: proc(b: ^strings.Builder, p: Page, h: ^History, selected: int, query: string) {
	page_start(b, p, "history · typer", "history", {"DMMono-latin.woff2"})
	w(b, `<div class="history-dashboard"><header class="history-heading"><h1>Your typing</h1>`)
	if h == nil || h.tests == 0 {
		w(b, `</header><section class="history-start"><div class="start-keys" aria-hidden="true"><span>t</span><span>y</span><span>p</span><span>e</span></div><h2>Start with a test.</h2><p>Finish a test to see your speed and accuracy here. As you type more, you'll find the keys and letter pairs that need practice.</p><a class="button" href="/">Start typing</a><p class="history-caption">Your history stays with this browser. The key link on your name's page brings it to another device.</p></section></div>`)
		page_end(b)
		return
	}
	w(b, `<p>Since `)
	write_day(b, h.first)
	w(b, `</p></header>`)
	g := &h.groups[selected]
	w(b, `<details class="history-filter"><summary><span>Showing</span><strong>`)
	setup_label(b, g.setup)
	w(b, `</strong><span class="history-filter-count">`)
	history_count(b, len(g.all), "test", "tests")
	w(b, `</span></summary><nav aria-label="History setup">`)
	for &group in h.groups {
		w(b, `<a href="`)
		history_href(b, &group)
		w(b, `"`)
		if history_setup_key(group.setup) == history_setup_key(g.setup) do w(b, ` aria-current="true"`)
		w(b, `><span>`)
		setup_label(b, group.setup)
		w(b, `</span><small>`)
		history_count(b, len(group.all), "test", "tests")
		w(b, `</small></a>`)
	}
	w(b, `</nav></details>`)
	n := len(g.valid)
	if n == 0 {
		w(b, `<section class="history-start compact"><h2>No valid results for this setup yet.</h2><p>Your tests are saved below. Finish a valid test to start comparing your speed.</p><a class="button" href="/">Start typing</a></section>`)
	} else {
		render_history_findings(b, g)
		w(b, `<section class="history-progress" aria-labelledby="progress-title"><div class="history-section-heading"><h2 id="progress-title">`)
		w(b, "Your first result" if n == 1 else "Speed over time")
		w(b, `</h2><p>`)
		history_count(b, n, "valid test", "valid tests")
		w(b, `</p></div>`)
		if n > 1 {
			render_history_progress(b, g)
		} else {
			w(b, `<p class="history-first">Your next tests will start a speed chart here.</p>`)
		}
		w(b, `<dl class="history-stats">`)
		history_stat(b, "Average speed", g.wpm, "wpm", "average-wpm")
		history_stat(b, "Accuracy", g.acc, "%", "average-accuracy")
		history_stat(b, "Consistency", g.cons, "%", "average-consistency")
		w(b, `<div><dt>Personal best</dt><dd><a data-metric="personal-best" href="/results/`)
		strings.write_i64(b, g.best.id)
		w(b, `">`)
		history_number(b, g.best.wpm)
		w(b, `<small>wpm</small></a></dd></div></dl>`)
		if n > 1 && n < 20 do w(b, `<p class="history-caption history-sample-note">After 20 valid tests in this setup, compare your first 10 with your latest 10.</p>`)
		w(b, `</section>`)
		if g.unavailable > 0 {
			w(b, `<p class="history-status" role="status">Key and pace details are available for `)
			strings.write_int(b, g.analysed)
			w(b, ` of `)
			history_count(b, n, "valid test", "valid tests")
			w(b, `. Details could not be read for `)
			history_count(b, g.unavailable, "test", "tests")
			w(b, `. Their scores are still shown.</p>`)
		}
		if g.analysed >= 5 {
			has_secondary := len(g.slow) + len(g.missed) + len(g.mistyped) > 0
			w(b, `<div class="history-diagnosis`)
			if !has_secondary do w(b, ` solo`)
			w(b, `">`)
			render_history_keys(b, g)
			if has_secondary {
				w(b, `<div class="history-secondary">`)
				render_history_mistakes(b, g)
				render_history_pairs(b, g)
				w(b, `</div>`)
			}
			render_history_pace(b, g)
			w(b, `</div>`)
		}
	}
	w(b, `<div class="history-rhythm solo">`)
	render_history_practice(b, h)
	w(b, `</div>`)
	render_history_recent(b, g, query)
	w(b, `<details class="history-definitions"><summary>How these numbers work</summary><div><p>Speed, accuracy, consistency and personal best use valid results in the selected setup. Averages give every test equal weight. Punctuation, numbers, language and test length each define a separate setup. Quotes are grouped by length.</p><p>The line averages the current test and up to nine preceding tests. The chart shows up to 240 evenly spaced results on desktop, 80 on a phone, and 160 line points. Diamonds also mark every test that exceeded all preceding speeds in this setup. The first test establishes the best. Dates and active days use UTC. A speed comparison needs 20 valid tests. Differences that round to zero get a neutral finding.</p><p>Key accuracy counts every attempt at the expected character, including errors you fix. Case shares a key. At least 20 attempts are needed to shade a key. Key speed is the mean gap before a correct insertion, following another correct insertion. Errors and deletes break this sequence. Only positive gaps of at most 2 seconds count. A speed needs 20 timed observations. Unsupported layouts show a character list.</p><p>Missed words count completed target positions with any incorrect insertion, including fixed errors, or omitted text at the word's end. Revisiting a position does not count it twice. An unfinished word at a timed cutoff is excluded. Case shares a word; punctuation stays. A word needs five completed occurrences and misses in at least three tests.</p><p>Substitutions count a non-space character typed instead of the expected character. Fixed errors count; case shares a character. A pair needs three occurrences across at least three tests, and its expected key needs 20 attempts. Key, word and substitution details need five analysed valid tests.</p><p>Pair timing is the mean gap between consecutive correct letters in the same word. Deletes, errors, gaps over 2 seconds and gaps of zero break the pair. A pair needs at least 20 observations.</p><p>Test pace uses tests of at least 30 seconds with at least 30 inserted characters in each third. Speed counts correct insertions, including corrected text, divided by elapsed time. It differs from scored wpm. Accuracy pools correct insertions divided by all insertions in that third. The chart needs five eligible tests; its finding needs ten and a difference of at least one percentage point.</p><p>Delete actions count backspace and word delete, divided by inserted characters, including spaces and corrected text. Practice totals and the calendar include every finished test, including invalid ones. Calendar intensity shows total minutes typed each UTC day. Recent tests belong to the selected setup.</p></div></details></div>`)
	page_end(b)
}

history_svg_num :: proc(b: ^strings.Builder, value: f64) {
	engine.write_fixed(b, value, 1)
}

render_history_progress :: proc(b: ^strings.Builder, g: ^History_Group) {
	w(b, `<figure class="history-trajectory">`)
	render_history_progress_plot(b, g, 960)
	render_history_progress_plot(b, g, 360)
	w(b, `<figcaption><span><i class="history-dot-key"></i>One test</span><span><i class="history-line-key"></i>Average of up to 10 tests</span><span><i class="history-best-key"></i>New personal best</span></figcaption></figure>`)
}

render_history_progress_plot :: proc(b: ^strings.Builder, g: ^History_Group, width: int) {
	rows := g.valid[:]
	n := len(rows)
	low, high := rows[0].wpm, rows[0].wpm
	for s in rows do low, high = min(low, s.wpm), max(high, s.wpm)
	raw_step := max(5, (high - low + 16) / 4)
	magnitude := math.pow(10, math.floor(math.log10(raw_step)))
	interval := 10 * magnitude
	for multiplier in ([?]f64{1, 2, 5, 10}) {
		if multiplier * magnitude >= raw_step {
			interval = multiplier * magnitude
			break
		}
	}
	bottom := max(0, math.floor((low - 4) / interval) * interval)
	top := max(bottom + interval * 2, math.ceil((high + 4) / interval) * interval)
	first, last := rows[0].created_at, rows[n - 1].created_at
	x_of :: proc(s: Stored, first, last: i64, width: int) -> f64 {
		return 42 + f64(width - 62) * f64(s.created_at - first) / f64(max(1, last - first))
	}
	y_of :: proc(value, bottom, top: f64) -> f64 {
		return 225 - 192 * (value - bottom) / (top - bottom)
	}
	w(b, `<svg class="`)
	w(b, "history-chart-desktop" if width == 960 else "history-chart-phone")
	w(b, `" viewBox="0 0 `)
	strings.write_int(b, width)
	w(b, ` 268" role="img" aria-label="Typing speed over time"><desc>`)

	strings.write_int(b, n)
	w(b, ` valid tests, from `)
	write_day(b, first)
	w(b, ` to `)
	write_day(b, last)
	w(b, `. Speed ranges from `)
	history_number(b, low)
	w(b, ` to `)
	history_number(b, high)
	w(b, ` wpm. The last ten or fewer tests average `)
	history_number(b, history_mean(rows[max(0, n - 10):]))
	w(b, ` wpm. Diamonds mark `)
	history_count(b, len(g.records), "best-setting test", "best-setting tests")
	w(b, `.</desc>`)
	for value := bottom; value <= top; value += interval {
		y := y_of(value, bottom, top)
		w(b, `<line class="history-grid" x1="42" x2="`)
		strings.write_int(b, width - 20)
		w(b, `" y1="`)
		history_svg_num(b, y)
		w(b, `" y2="`)
		history_svg_num(b, y)
		w(b, `"/><text x="32" y="`)
		history_svg_num(b, y + 4)
		w(b, `" text-anchor="end">`)
		history_number(b, value, 0)
		w(b, `</text>`)
	}
	w(b, `<text x="12" y="16">wpm</text><g class="history-dots">`)
	dots := min(240 if width == 960 else 80, n)
	for i in 0 ..< dots {
		idx := i * (n - 1) / max(1, dots - 1)
		s := rows[idx]
		w(b, `<circle cx="`)
		history_svg_num(b, x_of(s, first, last, width))
		w(b, `" cy="`)
		history_svg_num(b, y_of(s.wpm, bottom, top))
		w(b, `" r="3"><title>`)
		write_date(b, s.created_at)
		w(b, ` UTC, `)
		history_number(b, s.wpm, 2)
		w(b, ` wpm, `)
		history_number(b, s.acc, 2)
		w(b, `% accuracy</title></circle>`)
	}
	w(b, `</g><polyline class="history-trend" points="`)
	points := min(160, n)
	for i in 0 ..< points {
		idx := i * (n - 1) / max(1, points - 1)
		if i > 0 do w(b, " ")
		history_svg_num(b, x_of(rows[idx], first, last, width))
		w(b, ",")
		history_svg_num(b, y_of(history_mean(rows[max(0, idx - 9):idx + 1]), bottom, top))
	}
	w(b, `"/><g class="history-best-marks">`)
	for s in g.records {
		x, y := x_of(s, first, last, width), y_of(s.wpm, bottom, top)
		w(b, `<a href="/results/`)
		strings.write_i64(b, s.id)
		w(b, `" aria-label="New personal best, `)
		history_number(b, s.wpm)
		w(b, ` wpm on `)
		write_day(b, s.created_at)
		w(b, `"><path d="M`)
		history_svg_num(b, x)
		w(b, " ")
		history_svg_num(b, y - 5)
		w(b, `l5 5 -5 5 -5 -5Z"><title>New personal best: `)
		history_number(b, s.wpm)
		w(b, ` wpm, `)
		write_date(b, s.created_at)
		w(b, ` UTC</title></path></a>`)
	}
	w(b, `</g><text x="42" y="257">`)
	write_day(b, first)
	w(b, `</text><text x="`)
	strings.write_int(b, width - 20)
	w(b, `" y="257" text-anchor="end">`)
	write_day(b, last)
	w(b, `</text></svg>`)
}

history_key :: proc(b: ^strings.Builder, key: rune, g: ^History_Group) {
	k, found := g.keys[key]
	acc := 0.0
	if found && k.attempts > 0 do acc = 100 * (1 - f64(k.errors) / f64(k.attempts))
	level := 0
	if k.attempts >= 20 {
		level = 1
		if acc < 98 do level = 2
		if acc < 95 do level = 3
		if acc < 90 do level = 4
	}
	w(b, `<div class="history-key level-`)
	strings.write_int(b, level)
	w(b, ` speed-level-`)
	speed := f64(k.interval) / f64(max(1, k.timed)) / 100
	speed_level := 0
	if k.timed >= 20 {
		speed_level = 1 if speed < 150 else 2 if speed < 225 else 3 if speed < 300 else 4
	}
	strings.write_int(b, speed_level)
	w(b, `" tabindex="0"><span>`)
	engine.html_text(b, analysis_key_text(key))
	w(b, `</span><small class="history-key-speed">`)
	if k.timed >= 20 {
		history_number(b, speed, 0)
	} else {
		w(b, `?`)
	}
	w(b, `</small><span class="history-key-detail">`)
	if k.attempts >= 20 {
		history_number(b, acc)
		w(b, `% correct from `)
		strings.write_int(b, int(k.attempts))
		w(b, " attempt" if k.attempts == 1 else " attempts")
		if k.timed >= 20 {
			w(b, `, `)
			history_number(b, f64(k.interval) / f64(k.timed) / 100, 0)
			w(b, ` ms mean gap before this key from `)
			history_count(b, int(k.timed), "timed observation", "timed observations")
		}
	} else {
		strings.write_int(b, int(k.attempts))
		w(b, ` of 20 attempts needed`)
		if k.timed >= 20 {
			w(b, `, `)
			history_number(b, speed, 0)
			w(b, ` ms mean gap`)
		}
	}
	w(b, `</span></div>`)
}

render_history_keys :: proc(b: ^strings.Builder, g: ^History_Group) {
	w(b, `<section class="history-keys" aria-labelledby="keys-title"><div class="history-section-heading"><h2 id="keys-title">Your keys</h2><fieldset class="history-key-choice"><legend class="sr-only">Keyboard measure</legend><label><input type="radio" name="key-view" value="accuracy" checked>Accuracy</label><label><input id="history-speed" type="radio" name="key-view" value="speed">Speed</label></fieldset></div><p class="history-caption history-accuracy-caption">Accuracy for the key you meant to type. Errors count even when you fix them.</p><p class="history-caption history-speed-caption">Mean gap before each correct key, in milliseconds. A longer gap means a slower key.</p>`)
	language := g.setup.setup.language
	layout := ""
	rows: [3]string
	if strings.has_prefix(language, "english") {
		layout, rows = "QWERTY", {"qwertyuiop", "asdfghjkl", "zxcvbnm"}
	} else if strings.has_prefix(language, "german") {
		layout, rows = "QWERTZ", {"qwertzuiopü", "asdfghjklöä", "yxcvbnm"}
	} else if strings.has_prefix(language, "french") {
		layout, rows = "AZERTY", {"azertyuiop", "qsdfghjklm", "wxcvbn"}
	}
	if layout != "" {
		w(b, `<div class="history-keyboard" aria-label="`)
		w(b, layout)
		w(b, ` keyboard">`)
		for row in rows {
			w(b, `<div class="history-key-row">`)
			for key in row do history_key(b, key, g)
			w(b, `</div>`)
		}
		w(b, `</div><p class="history-key-legend"><span>`)
		w(b, layout)
		w(b, `</span><span class="history-accuracy-caption">More errors <i class="level-4"></i><i class="level-3"></i><i class="level-2"></i><i class="level-1"></i> Fewer</span><span class="history-speed-caption">Longer gap <i class="level-4"></i><i class="level-3"></i><i class="level-2"></i><i class="level-1"></i> Shorter</span></p>`)
		extra := make([dynamic]rune, context.temp_allocator)
		for key in g.keys {
			in_layout := false
			for row in rows {
				for c in row do if c == key do in_layout = true
			}
			if !in_layout do append(&extra, key)
		}
		if len(extra) > 0 {
			slice.sort(extra[:])
			w(b, `<details class="history-other-keys"><summary>Other characters</summary>`)
			history_character_list(b, g, extra[:])
			w(b, `</details>`)
		}
	} else {
		keys := make([dynamic]rune, context.temp_allocator)
		for key in g.keys do append(&keys, key)
		slice.sort(keys[:])
		history_character_list(b, g, keys[:])
	}
	weak, measured := history_weak_key(g)
	w(b, `<p class="history-key-finding" data-metric="weak-key">`)
	if weak.attempts > 0 {
		w(b, `Take care with <kbd>`)
		engine.html_text(b, analysis_key_text(weak.key))
		w(b, `</kbd>. `)
		history_count(b, int(weak.errors), "error", "errors")
		w(b, ` in `)
		history_count(b, int(weak.attempts), "attempt", "attempts")
		w(b, `, `)
		history_number(b, f64(weak.errors) / f64(weak.attempts) * 100)
		w(b, `% missed.`)
	} else if measured > 0 {
		w(b, `No errors in the measured keys. `)
		history_count(b, measured, "key has", "keys have")
		w(b, ` at least 20 attempts.`)
	} else {
		w(b, `Not enough samples yet. A key needs 20 attempts before we compare it.`)
	}
	if g.inserts > 0 {
		w(b, ` <span data-metric="deletes-per-100">`)
		history_number(b, f64(g.deletes) / f64(g.inserts) * 100)
		w(b, ` deletes per 100 typed characters.</span>`)
	}
	w(b, `</p><p class="history-caption history-key-help">Focus or hover a key for counts and timing. Speed needs 20 timed observations.</p>`)
	w(b, `</section>`)
}

history_character_list :: proc(b: ^strings.Builder, g: ^History_Group, keys: []rune) {
	w(b, `<ul class="history-character-list">`)
	for key in keys {
		k := g.keys[key]
		w(b, `<li><span>`)
		engine.html_text(b, analysis_key_text(key))
		w(b, `</span><span>`)
		if k.attempts >= 20 {
			history_number(b, 100 * (1 - f64(k.errors) / f64(k.attempts)))
			w(b, `% correct, `)
		}
		strings.write_int(b, int(k.attempts))
		w(b, " attempt" if k.attempts == 1 else " attempts")
		if k.timed >= 20 {
			w(b, `, `)
			history_number(b, f64(k.interval) / f64(k.timed) / 100, 0)
			w(b, ` ms`)
		}
		w(b, `</span></li>`)
	}
	w(b, `</ul>`)
}

render_history_pairs :: proc(b: ^strings.Builder, g: ^History_Group) {
	if len(g.slow) == 0 do return
	w(b, `<section class="history-pairs"><h2>Slow pairs</h2><p class="history-caption">Each pair has at least 20 correct repetitions.</p>`)
	w(b, `<ol>`)
	for p in g.slow[:min(3, len(g.slow))] {
		w(b, `<li><span class="history-pair-letters">`)
		engine.html_text(b, analysis_key_text(p.first))
		engine.html_text(b, analysis_key_text(p.second))
		w(b, `</span><span><strong>`)
		history_number(b, f64(p.interval) / f64(p.count) / 100, 0)
		w(b, ` ms</strong><small>`)
		strings.write_int(b, int(p.count))
		w(b, ` repetitions</small></span></li>`)
	}
	w(b, `</ol>`)
	w(b, `</section>`)
}

render_history_pace :: proc(b: ^strings.Builder, g: ^History_Group) {
	if g.pace_tests < 5 do return
	w(b, `<section class="history-pace"><h2>Through a test</h2><p class="history-caption">`)
	strings.write_int(b, g.pace_tests)
	w(b, ` tests of 30 seconds or longer.</p><figure><svg viewBox="0 0 330 122" role="img" aria-labelledby="pace-title" aria-describedby="pace-values"><title id="pace-title">Correct insertion speed and accuracy by third of a test</title>`)
	speeds: [3]f64
	top := 20.0
	for n, i in g.thirds {
		speeds[i] = f64(n - g.errors[i]) * 36 / g.pace_seconds
		top = max(top, speeds[i])
	}
	labels := [3]string{"Start", "Middle", "End"}
	w(b, `<desc id="pace-values">`)
	for speed, i in speeds {
		w(b, labels[i])
		w(b, `: `)
		history_number(b, speed)
		w(b, ` wpm, `)
		history_number(b, 100 * (1 - f64(g.errors[i]) / f64(g.thirds[i])))
		w(b, `% accuracy. `)
	}
	w(b, `</desc>`)
	for speed, i in speeds {
		x := f64(24 + i * 110)
		height := speed / top * 48
		w(b, `<rect class="history-pace-bar" x="`)
		history_svg_num(b, x)
		w(b, `" y="`)
		history_svg_num(b, 76 - height)
		w(b, `" width="62" height="`)
		history_svg_num(b, height)
		w(b, `" rx="3"/><text x="`)
		history_svg_num(b, x + 31)
		w(b, `" y="`)
		history_svg_num(b, 67 - height)
		w(b, `" text-anchor="middle">`)
		history_number(b, speed, 0)
		w(b, `</text><text x="`)
		history_svg_num(b, x + 31)
		w(b, `" y="97" text-anchor="middle">`)
		w(b, labels[i])
		w(b, `</text><text x="`)
		history_svg_num(b, x + 31)
		w(b, `" y="117" text-anchor="middle">`)
		history_number(b, 100 * (1 - f64(g.errors[i]) / f64(g.thirds[i])))
		w(b, `%</text>`)
	}
	w(b, `</svg><figcaption>Correct insertions in wpm, with accuracy below.</figcaption></figure>`)
	w(b, `</section>`)
}

render_history_mistakes :: proc(b: ^strings.Builder, g: ^History_Group) {
	if len(g.missed) > 0 {
		w(b, `<section class="history-mistakes history-words"><h2>Missed words</h2><p class="history-caption">Words with errors in at least three tests. Fixed errors count.</p><ul>`)
		for v in g.missed[:min(3, len(g.missed))] {
			w(b, `<li><span class="history-practice-word">`)
			engine.html_text(b, v.word)
			w(b, `</span><span><span>`)
			strings.write_int(b, int(v.misses))
			w(b, ` of `)
			history_count(b, int(v.attempts), "time", "times")
			w(b, `</span><small>Errors in `)
			history_count(b, int(v.missed_tests), "test", "tests")
			w(b, `</small></span></li>`)
		}
		w(b, `</ul></section>`)
	}
	if len(g.mistyped) > 0 {
		w(b, `<section class="history-mistakes history-substitutions"><h2>Recurring substitutions</h2><p class="history-caption">What you type instead of the expected key.</p><ul>`)
		for v in g.mistyped[:min(3, len(g.mistyped))] {
			w(b, `<li><span class="history-substitution">`)
			engine.html_text(b, analysis_key_text(v.typed))
			w(b, ` <small>for</small> `)
			engine.html_text(b, analysis_key_text(v.expected))
			w(b, `</span><span><span>`)
			history_count(b, int(v.count), "time", "times")
			w(b, `</span><small>Across `)
			history_count(b, int(v.tests), "test", "tests")
			w(b, `</small></span></li>`)
		}
		w(b, `</ul></section>`)
	}
}

render_history_practice :: proc(b: ^strings.Builder, h: ^History) {
	w(b, `<section class="history-calendar"><div class="history-section-heading"><h2>Practice time by day</h2><p>All setups</p></div><dl class="history-practice"><div><dt>Tests</dt><dd data-metric="total-tests">`)
	strings.write_int(b, h.tests)
	w(b, `</dd></div><div><dt>Time typed</dt><dd data-metric="total-time">`)
	if h.seconds < 60 {
		history_number(b, h.seconds, 0)
		w(b, `<small>s`)
	} else if h.seconds < 3600 {
		history_number(b, h.seconds / 60)
		w(b, `<small>min`)
	} else {
		history_number(b, h.seconds / 3600)
		w(b, `<small>h`)
	}
	w(b, `</small></dd></div><div><dt>Active days</dt><dd data-metric="active-days">`)
	strings.write_int(b, h.active_days)
	w(b, `</dd></div></dl>`)
	if h.active_days > 1 {
		today := now_ms() / DAY_MS
		first := today - 83
		seconds: [84]f64
		durations := make([dynamic]f64, context.temp_allocator)
		for day in h.days {
			if day.day < first || day.day > today do continue
			seconds[day.day - first] = day.seconds
			if day.seconds > 0 do append(&durations, day.seconds)
		}
		slice.sort(durations[:])
		bounds := [3]f64{300, 900, 1800}
		if len(durations) >= 4 {
			for &bound, i in bounds {
				bound = max(30, math.round(durations[(len(durations) - 1) * (i + 1) / 4] / 30) * 30)
				if i > 0 do bound = max(bound, bounds[i - 1] + 30)
			}
		}
		w(b, `<figure>`)
		render_history_calendar_plot(b, seconds, bounds, first, false)
		render_history_calendar_plot(b, seconds, bounds, first, true)
		w(b, `<figcaption class="history-calendar-legend"><span>Minutes per day</span><span><i class="practice-level-0"></i>0</span>`)
		for bound, i in bounds {
			w(b, `<span><i class="practice-level-`)
			strings.write_int(b, i + 1)
			w(b, `"></i>≤ `)
			history_number(b, bound / 60, 1 if math.mod(bound, 60) != 0 else 0)
			w(b, `</span>`)
		}
		w(b, `<span><i class="practice-level-4"></i>&gt; `)
		history_number(b, bounds[2] / 60, 1 if math.mod(bounds[2], 60) != 0 else 0)
		w(b, `</span></figcaption></figure><p class="history-caption">Past 12 weeks. More intense squares mean more time.`)
		if len(durations) >= 4 do w(b, ` Bands follow your active days, rounded to half a minute.`)
		w(b, `</p>`)
	}
	w(b, `</section>`)
}

render_history_calendar_plot :: proc(b: ^strings.Builder, seconds: [84]f64, bounds: [3]f64, first: i64, phone: bool) {
	w(b, `<svg class="`)
	w(b, "history-chart-phone" if phone else "history-chart-desktop")
	w(b, `" viewBox="0 0 `)
	w(b, "350 90" if phone else "960 70")
	w(b, `" role="img" aria-label="Time typed per day in the past 84 days"><desc>Each square is a UTC day, read left to right. More intense squares mean more time. `)
	for duration, i in seconds {
		if duration == 0 do continue
		write_day(b, (first + i64(i)) * DAY_MS)
		w(b, `: `)
		history_number(b, duration / 60)
		w(b, ` minutes. `)
	}
	w(b, `</desc>`)
	for duration, i in seconds {
		x := f64(i % 28) * 12.5 if phone else f64(i) * 11.42
		y := 3 + f64(i / 28) * 18 if phone else 3.0
		w(b, `<rect x="`)
		history_svg_num(b, x)
		w(b, `" y="`)
		history_svg_num(b, y)
		w(b, `" width="`)
		w(b, "9.5" if phone else "8.4")
		w(b, `" height="14" rx="2" class="practice-level-`)
		level := 0 if duration == 0 else 1 if duration <= bounds[0] else 2 if duration <= bounds[1] else 3 if duration <= bounds[2] else 4
		strings.write_int(b, level)
		w(b, `" data-seconds="`)
		history_number(b, duration, 2)
		w(b, `"><title>`)
		write_day(b, (first + i64(i)) * DAY_MS)
		w(b, `, `)
		history_number(b, duration / 60)
		w(b, ` minutes typed</title></rect>`)
	}
	w(b, `<text x="0" y="`)
	w(b, "82" if phone else "49")
	w(b, `">`)
	write_day(b, first * DAY_MS)
	w(b, `</text><text x="`)
	w(b, "347" if phone else "957")
	w(b, `" y="`)
	w(b, "82" if phone else "49")
	w(b, `" text-anchor="end">Today</text></svg>`)
}

render_history_recent :: proc(b: ^strings.Builder, g: ^History_Group, query: string) {
	count := len(g.all)
	pages := (count + 9) / 10
	page, _ := strconv.parse_int(query_value(query, "page"), 10)
	page = clamp(page, 0, max(0, pages - 1))
	end := max(0, count - page * 10)
	start := max(0, end - 10)
	w(b, `<section class="history-recent" id="recent"><div class="history-section-heading"><h2>Recent tests</h2><p>`)
	strings.write_int(b, count)
	w(b, ` in this setup</p></div><table><caption class="sr-only">Recent tests for the selected setup. Dates are UTC. Open a date for the complete result.</caption><thead><tr><th scope="col">Date, UTC</th><th scope="col" class="num">wpm</th><th scope="col" class="num">Accuracy</th><th scope="col" class="num history-extra">Raw</th><th scope="col" class="num history-extra">Consistency</th></tr></thead><tbody>`)
	#reverse for s in g.all[start:end] {
		w(b, `<tr`)
		if !s.valid {
			w(b, ` class="invalid"`)
		} else if s.id == g.best.id {
			w(b, ` class="history-personal-best"`)
		}
		w(b, `><td><a href="/results/`)
		strings.write_i64(b, s.id)
		w(b, `">`)
		write_date(b, s.created_at)
		w(b, `</a>`)
		if !s.valid do w(b, `<span class="history-invalid">Invalid</span>`)
		if s.id == g.best.id do w(b, `<span class="history-best-label">Personal best</span>`)
		w(b, `</td><td class="num">`)
		history_number(b, s.wpm, 2)
		w(b, `</td><td class="num">`)
		history_number(b, s.acc, 2)
		w(b, `%</td><td class="num history-extra">`)
		history_number(b, s.raw, 2)
		w(b, `</td><td class="num history-extra">`)
		history_number(b, s.cons, 2)
		w(b, `%</td></tr>`)
	}
	w(b, `</tbody></table>`)
	if pages > 1 {
		w(b, `<nav class="history-pagination" aria-label="Recent tests pages">`)
		if page > 0 {
			w(b, `<a href="`)
			history_href(b, g, page - 1)
			w(b, `#recent">Newer tests</a>`)
		}
		w(b, `<span>Page `)
		strings.write_int(b, page + 1)
		w(b, ` of `)
		strings.write_int(b, pages)
		w(b, `</span>`)
		if page + 1 < pages {
			w(b, `<a href="`)
			history_href(b, g, page + 1)
			w(b, `#recent">Older tests</a>`)
		}
		w(b, `</nav>`)
	}
	w(b, `</section>`)
}
