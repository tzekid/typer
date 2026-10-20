package engine

// Why a finished test does not count, mirroring upstream finish() checks.
// Empty when valid.
invalid_reason :: proc(t: ^Test, setup: Setup, r: Result) -> string {
	m2 := setup.mode2
	too_short :=
		r.test_duration < 1 ||
		(setup.mode == .Time && m2 < 15 && m2 > 0) ||
		(setup.mode == .Time && m2 == 0 && r.test_duration < 15) ||
		(setup.mode == .Words && m2 < 10 && m2 > 0) ||
		(setup.mode == .Words && m2 == 0 && r.test_duration < 15) ||
		(setup.mode == .Zen && r.test_duration < 15)
	if too_short {
		return "test invalid: too short"
	}
	if !t.bailed_out {
		kps := count_per_interval(t, timer_boundaries(t), .Insert_Text)
		afk := true
		for c in kps[max(len(kps) - 5, 0):] {
			if c != 0 {
				afk = false
			}
		}
		if afk {
			return "test invalid: afk detected"
		}
	}
	// Quotes may be retried; other tests can't count once their words were seen.
	if .Repeated in setup.flags && setup.mode != .Quote {
		return "test invalid: repeated"
	}
	words10 := setup.mode == .Words && m2 == 10
	limit := 420.0 if words10 else 350.0
	if r.wpm < 0 || r.wpm > limit {
		return "test invalid: wpm"
	}
	if r.raw_wpm < 0 || r.raw_wpm > limit {
		return "test invalid: raw"
	}
	if r.acc < 75 || r.acc > 100 {
		return "test invalid: accuracy"
	}
	return ""
}
