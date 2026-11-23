#+test
package engine

import "core:strings"
import "core:testing"

@(test)
generated_sections :: proc(t: ^testing.T) {
	bytes := pack_encode("french", {}, {"  est  venu  "})
	pack, ok := pack_view(bytes)
	testing.expect(t, ok)
	g: Generator
	generator_init(&g, pack.list, 123, false, false)
	for i in 0 ..< 8 {
		expected := "est" if i % 2 == 0 else "venu"
		testing.expect_value(t, generator_next(&g, i, 8), string(expected))
	}
}

@(test)
cross_word_erase :: proc(t: ^testing.T) {
	test: Test
	test_reset(&test, {mode = .Time, mode2 = 30})
	test_add_word(&test, "red", ' ')
	test_add_word(&test, "sky", ' ')
	for ch, i in "red sk" do test_insert(&test, f64(i + 1) * 100, ch)
	test_delete(&test, 800, .Char, DELETE_INTO_PREVIOUS)
	testing.expect_value(t, test.active, i32(0))
	testing.expect_value(t, len(word_input(&test, 1)), 0)
	test_time_up(&test, 30100)
	test_finalize(&test)
	r := build_result(&test)
	testing.expect_value(t, r.char_stats[0], i32(3))
	testing.expect_value(t, r.char_stats[1], i32(0))
}

@(test)
chart_budget :: proc(t: ^testing.T) {
	test: Test
	test_reset(&test, {mode = .Time, mode2 = 600})
	test_add_word(&test, "hello", ' ')
	test_insert(&test, 100, 'h')
	test_time_up(&test, 600100)
	test_finalize(&test)
	r := build_result(&test)
	testing.expect_value(t, len(r.chart_seconds), 300)
	testing.expect_value(t, r.chart_seconds[299], f64(600))
	b := strings.builder_make()
	render_chart(&b, r)
	testing.expect(t, strings.builder_len(b) < 48 * 1024)
}
