package engine

// Directly typable space characters (upstream utils/strings.ts SPACE_CODE_POINTS).
is_space :: proc "contextless" (c: rune) -> bool {
	switch c {
	case 0x0020, 0x2002, 0x2003, 0x2009, 0x3000, 0x00A0, 0x1680, 0x202F, 0xFEFF, 0x2007, 0x2008, 0x2004, 0x200A, 0x200B:
		return true
	}
	return false
}

@(rodata)
EQUIVALENCE_SETS := [?][]rune {
	{0x2019, 0x2018, '\'', 0x02BC, 0x05F3, 0x02BB, 0x1FBD},
	{'"', 0x201D, 0x201C, 0x201E},
	{0x2013, 0x2014, '-', 0x2010, 0x2011},
	{',', 0x201A},
}

@(rodata)
RUSSIAN_EQUIVALENCE := [?]rune{0x0451, 0x0435, 'e'}

@(private)
contains_rune :: proc "contextless" (set: []rune, c: rune) -> bool {
	for s in set {
		if s == c {
			return true
		}
	}
	return false
}

Language_Rules :: enum u8 {
	None,
	Russian,
}

// areCharactersVisuallyEqual
visually_equal :: proc "contextless" (a, b: rune, rules: Language_Rules) -> bool {
	if a == b {
		return true
	}
	if (a == ' ' || b == ' ') && is_space(a) && is_space(b) {
		return true
	}
	for set in EQUIVALENCE_SETS {
		if contains_rune(set, a) && contains_rune(set, b) {
			return true
		}
	}
	if rules == .Russian {
		set := RUSSIAN_EQUIVALENCE
		if contains_rune(set[:], a) && contains_rune(set[:], b) {
			return true
		}
	}
	return false
}

// normalizeData: map a typed char onto the target char when visually equal,
// and any Unicode space onto U+0020.
normalize_data :: proc "contextless" (data: rune, input: []rune, target: []rune, rules: Language_Rules) -> rune {
	if len(input) < len(target) {
		t := target[len(input)]
		if visually_equal(data, t, rules) {
			return t
		}
	}
	if is_space(data) {
		return ' '
	}
	return data
}

// Physical keys that upstream records in the event log (helpers.ts keysToTrack).
// The index into this table is the key code used throughout the engine and
// shared with the island, which builds its lookup from mt_key_name().
@(rodata)
TRACKED_KEYS := [?]string {
	"NumpadMultiply", "NumpadSubtract", "NumpadAdd", "NumpadDecimal", "NumpadEqual", "NumpadDivide",
	"Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9",
	"Backquote", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Digit0",
	"Minus", "Equal",
	"KeyQ", "KeyW", "KeyE", "KeyR", "KeyT", "KeyY", "KeyU", "KeyI", "KeyO", "KeyP",
	"BracketLeft", "BracketRight", "Backslash",
	"KeyA", "KeyS", "KeyD", "KeyF", "KeyG", "KeyH", "KeyJ", "KeyK", "KeyL", "Semicolon", "Quote",
	"IntlBackslash", "KeyZ", "KeyX", "KeyC", "KeyV", "KeyB", "KeyN", "KeyM", "Comma", "Period", "Slash",
	"Space", "Enter", "Tab",
	"NoCode",
}

KEY_UNTRACKED :: u16(0xFFFF)
KEY_NO_CODE :: u16(len(TRACKED_KEYS) - 1)
// Each press of a key without a code gets its own identity (upstream "NoCode{n}").
KEY_NO_CODE_BASE :: u16(1000)

key_from_name :: proc(name: string) -> u16 {
	for k, i in TRACKED_KEYS {
		if k == name {
			return u16(i)
		}
	}
	if len(name) > 6 && name[:6] == "NoCode" {
		return KEY_NO_CODE
	}
	return KEY_UNTRACKED
}

key_is_tracked :: proc "contextless" (code: u16) -> bool {
	return code < u16(len(TRACKED_KEYS))
}
