package engine

import "core:math"

// Numeric helpers that reproduce JavaScript semantics exactly, so results
// match upstream Monkeytype bit for bit after its own rounding.

JS_EPSILON :: 2.220446049250313e-16

// Math.round: nearest integer, ties toward +Infinity.
js_round :: proc "contextless" (x: f64) -> f64 {
	r := math.floor(x)
	if x - r >= 0.5 {
		return r + 1
	}
	return r
}

// roundTo2 from @monkeytype/util/numbers.
round_to_2 :: proc "contextless" (x: f64) -> f64 {
	return js_round((x + JS_EPSILON) * 100) / 100
}

calc_wpm :: proc "contextless" (chars: f64, seconds: f64) -> f64 {
	if seconds <= 0 {
		return 0
	}
	return chars / 5 / (seconds / 60)
}

// mean/stdDev mirror upstream's reduce() without an initial value: an empty
// array throws there and the catch returns 0.
mean :: proc "contextless" (values: []f64) -> f64 {
	if len(values) == 0 {
		return 0
	}
	sum := values[0]
	for v in values[1:] {
		sum = v + sum
	}
	return sum / f64(len(values))
}

std_dev :: proc "contextless" (values: []f64) -> f64 {
	if len(values) == 0 {
		return 0
	}
	m := mean(values)
	d0 := values[0] - m
	sum := d0 * d0
	for v in values[1:] {
		d := v - m
		sum = sum + d * d
	}
	return math.sqrt(sum / f64(len(values)))
}

kogasa :: proc "contextless" (cov: f64) -> f64 {
	return 100 * (1 - math.tanh(cov + math.pow(cov, 3) / 3 + math.pow(cov, 5) / 5))
}

is_nan :: proc "contextless" (x: f64) -> bool {
	return x != x
}

// `let c = roundTo2(kogasa(sd / avg)); if (!c || isNaN(c)) c = 0;`
consistency_of :: proc "contextless" (values: []f64) -> f64 {
	c := round_to_2(kogasa(std_dev(values) / mean(values)))
	if c == 0 || is_nan(c) {
		return 0
	}
	return c
}
