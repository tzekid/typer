// typer island: forwards browser input to core.wasm and executes its draw
// commands on a canvas. All test logic lives in the wasm. The instance lives
// as long as the tab: app.js swaps pages in place and calls typer.prepare,
// typer.mount and typer.unmount around each test page.
(() => {
  "use strict";

  const FONT_PX = 28;
  const FONT = `${FONT_PX}px "DM Mono", ui-monospace, monospace`;
  const LATIN_EXT = "ąćęłńśźżčďěňřšťůž";
  const QUOTE = 2;
  const ACTIVE = 1;
  const FINISHING = 2;
  const FINISHED = 3;
  const WASM = document.currentScript.dataset.wasm;

  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const still = matchMedia("(prefers-reduced-motion: reduce)");
  const colorNames = ["--bg", "--main", "--caret", "--sub", "--sub-alt", "--text", "--error", "--error-extra"];
  const readColors = () => {
    const css = getComputedStyle(document.documentElement);
    return colorNames.map((n) => css.getPropertyValue(n).trim());
  };
  let colors = readColors();

  // Text is measured on a canvas of its own, so layout works before a mount.
  const measurer = document.createElement("canvas").getContext("2d");
  measurer.font = FONT;

  let ex = null;
  let mem = null;
  let u8 = null;
  let booting = null;
  let packLanguage = "";
  const keyIndex = new Map();
  let noCode = 0;
  const untracked = 0xffff;

  const views = () => {
    if (u8 === null || u8.buffer !== mem.buffer) {
      u8 = new Uint8Array(mem.buffer);
      cmdBase = -1;
    }
    return u8;
  };
  const str = (ptr, len) => decoder.decode(views().subarray(ptr, ptr + len));

  const imports = {
    env: {
      pow: Math.pow,
      exp: Math.exp,
      js_measure: (ptr, len) => measurer.measureText(str(ptr, len)).width,
      js_result: (hp, hl, rp, rl) => {
        const html = str(hp, hl);
        const record = views().slice(rp, rp + rl);
        showResult(html);
        enqueue(record);
      },
    },
  };

  function boot() {
    booting ??= Promise.all([WebAssembly.instantiateStreaming(fetch(WASM), imports), document.fonts.load(FONT)]).then(([{ instance }]) => {
      ex = instance.exports;
      mem = ex.memory;
      for (let i = 0; i < ex.mt_key_count(); i++) keyIndex.set(str(ex.mt_key_name_ptr(i), ex.mt_key_name_len(i)), i);
      noCode = keyIndex.get("NoCode");
      ex.mt_init(FONT_PX, 1000);
      ex.mt_use_english();
      packLanguage = "english";
    });
    return booting;
  }

  async function usePack(language, url) {
    if (language === packLanguage) return;
    let ok;
    if (language === "english") ok = ex.mt_use_english();
    else {
      const [bytes] = await Promise.all([fetch(url).then((r) => r.arrayBuffer()), document.fonts.load(FONT, LATIN_EXT)]);
      const p = ex.mt_alloc(bytes.byteLength);
      views().set(new Uint8Array(bytes), p);
      ok = ex.mt_set_pack(p, bytes.byteLength);
    }
    if (!ok) throw new Error(`language pack ${language} failed to load`);
    packLanguage = language;
  }

  const configOf = (main) => {
    const el = main?.querySelector("#typer-config");
    return el ? JSON.parse(el.textContent) : null;
  };

  // Everything a test page needs before it is shown, so it appears drawn.
  async function prepare(main) {
    const c = configOf(main);
    if (c === null) return;
    await boot();
    await usePack(c.language, c.pack);
  }

  // ------ results outbox: kept until the server acknowledges them

  const OUTBOX = "typer:outbox";
  const readOutbox = () => JSON.parse(localStorage.getItem(OUTBOX) || "[]");
  const toB64 = (bytes) => {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const fromB64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  let flushing = false;

  function enqueue(record) {
    const box = readOutbox();
    box.push(toB64(record));
    localStorage.setItem(OUTBOX, JSON.stringify(box));
    flush();
  }

  async function flush() {
    if (flushing) return;
    flushing = true;
    try {
      for (;;) {
        const box = readOutbox();
        if (box.length === 0) break;
        const res = await fetch("/results", {
          method: "POST",
          headers: { "content-type": "application/octet-stream" },
          body: fromB64(box[0]),
          keepalive: true,
        });
        if (!res.ok && res.status !== 400) break;
        const rest = readOutbox();
        rest.shift();
        localStorage.setItem(OUTBOX, JSON.stringify(rest));
        const loc = res.headers.get("location");
        if (res.ok && loc && rest.length === 0 && el && !el.result.hidden) {
          el.link.href = loc;
          el.link.hidden = false;
        }
      }
    } catch (_) {
      // offline or server restarting: the outbox keeps the record
    } finally {
      flushing = false;
    }
  }

  // ------ the mounted test page

  let el = null; // its elements, null when no test page is shown
  let cfg = null;
  let ctx = null;
  let cssWidth = 0;
  let lineH = 0;
  let motion = 0; // caret glide in ms; 0 moves everything in the letter's frame
  let scheduled = false;
  let timer = 0;
  let idleTimer = 0;
  let pendingDelete = null;
  let textGen = -1;
  const textCache = new Map();
  let cmdBase = -1;
  let cmdU32 = null;
  let cmdF32 = null;
  let caretX = -1;
  let caretY = -1;
  let caretLine = -1;
  let topLine = 0;
  let slide = null;
  let tabs = false;
  let repeated = false;
  let seed = null; // of the words now shown, for a restart with the same ones
  let queue = null;
  let refilling = null;

  // fade: the page itself is new (app.js fades pages it swaps in).
  function mount(main, fade = false) {
    cfg = configOf(main);
    if (cfg === null) return false;
    const $ = (id) => main.querySelector(`#${id}`);
    el = {
      stage: $("stage"),
      timer: $("timer"),
      clip: main.querySelector(".lines-clip"),
      lines: $("lines"),
      canvas: $("words"),
      caret: $("caret"),
      input: $("typer-input"),
      result: $("result"),
      after: $("after"),
      link: main.querySelector("[data-result-link]"),
      hint: $("hint"),
      wordsText: $("words-text"),
    };
    ctx = el.canvas.getContext("2d", { alpha: false, desynchronized: true });
    motion = still.matches ? 0 : cfg.caretMs;
    queue = { seed: cfg.queue?.seed, from: cfg.queue?.from ?? 0, quotes: cfg.quotes ?? [], next: 0 };
    seed = null;
    textGen = -1;
    listen(el);
    const mine = el;
    prepare(main)
      .then(() => {
        if (el !== mine) return;
        lineH = ex.mt_line_height();
        el.caret.style.height = `${lineH}px`;
        el.clip.style.height = `${lineH * 3}px`;
        el.lines.style.top = `${-lineH}px`;
        size();
        ex.mt_resize(cssWidth);
        return restart(false, fade);
      })
      .catch((err) => {
        if (el === mine) el.stage.textContent = `typer failed to start: ${err.message}`;
      });
    flush();
    return true;
  }

  function unmount() {
    if (el === null) return;
    clearTimeout(timer);
    clearTimeout(idleTimer);
    slide?.cancel();
    slide = null;
    el = null;
    cfg = null;
    flush();
  }

  // ------ drawing

  function size() {
    cssWidth = Math.floor(el.clip.clientWidth);
    const h = ex.mt_height();
    const dpr = window.devicePixelRatio || 1;
    el.canvas.style.width = `${cssWidth}px`;
    el.canvas.style.height = `${h}px`;
    el.canvas.width = Math.round(cssWidth * dpr);
    el.canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = FONT;
    ctx.textBaseline = "middle";
  }

  // Word texts are stable until the text generation changes, so their
  // decoded strings are cached; per-frame scratch text is decoded each time.
  function text(op, ptr, len) {
    if ((op & 0x80) === 0) return str(ptr, len);
    const key = ptr * 4096 + len;
    let t = textCache.get(key);
    if (t === undefined) {
      t = str(ptr, len);
      textCache.set(key, t);
    }
    return t;
  }

  function draw(n) {
    const gen = ex.mt_text_gen();
    if (gen !== textGen) {
      textGen = gen;
      textCache.clear();
    }
    const base = ex.mt_cmds();
    views();
    if (base !== cmdBase) {
      cmdBase = base;
      cmdU32 = new Uint32Array(mem.buffer, base);
      cmdF32 = new Float32Array(mem.buffer, base);
    }
    const u32 = cmdU32;
    const f32 = cmdF32;
    const height = el.canvas.height;
    for (let i = 0; i < n; i++) {
      const o = i * 8;
      const color = colors[u32[o + 1]];
      const op = u32[o];
      switch (op & 0x7f) {
        case 1:
          ctx.fillStyle = color;
          ctx.fillRect(0, 0, cssWidth, height);
          break;
        case 2:
          ctx.fillStyle = color;
          ctx.fillRect(f32[o + 2], f32[o + 3], f32[o + 4], f32[o + 5]);
          break;
        case 3:
          ctx.fillStyle = color;
          ctx.fillText(text(op, u32[o + 6], u32[o + 7]), f32[o + 2], f32[o + 3]);
          break;
        case 4: {
          const a = f32[o + 4];
          ctx.save();
          ctx.beginPath();
          ctx.rect(a, 0, f32[o + 5] - a, height);
          ctx.clip();
          ctx.fillStyle = color;
          ctx.fillText(text(op, u32[o + 6], u32[o + 7]), f32[o + 2], f32[o + 3]);
          ctx.restore();
          break;
        }
      }
    }
  }

  // The caret glides along a line; to another line it jumps, and when the
  // text scrolls it rides up with its line instead of sweeping across it.
  function placeCaret() {
    const x = ex.mt_caret_x();
    const y = ex.mt_caret_y();
    const line = ex.mt_caret_line();
    if (x === caretX && y === caretY && line === caretLine) return;
    el.caret.style.transitionDuration = motion > 0 && line === caretLine ? `${motion}ms` : "0ms";
    el.caret.style.transform = `translate(${x - 1}px, ${y}px)`;
    caretX = x;
    caretY = y;
    caretLine = line;
  }

  // The lines glide up instead of jumping: the canvas already shows the new
  // lines (and the one leaving, in the clipped row above), so start it k
  // lines lower and let it settle.
  function slideUp(k) {
    let from = k * lineH;
    if (slide?.playState === "running") from += new DOMMatrixReadOnly(getComputedStyle(el.lines).transform).m42;
    slide?.cancel();
    slide = el.lines.animate([{ transform: `translateY(${from}px)` }, { transform: "translateY(0)" }], {
      duration: Math.round(motion * 1.5),
      easing: "cubic-bezier(.25, .7, .35, 1)",
    });
  }

  // The caret blinks only after a second without input.
  function typed() {
    el.caret.classList.remove("idle");
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => el?.caret.classList.add("idle"), 1000);
  }

  function frame(now) {
    scheduled = false;
    if (el === null) return;
    const n = ex.mt_frame(now);
    if (n > 0) draw(n);
    const top = ex.mt_top_line();
    if (top !== topLine) {
      if (top > topLine && motion > 0 && ex.mt_phase() === ACTIVE) slideUp(top - topLine);
      topLine = top;
    }
    placeCaret();
    if (ex.mt_timer_changed()) el.timer.textContent = str(ex.mt_timer_ptr(), ex.mt_timer_len());
    const hide = ex.mt_phase() >= FINISHING;
    if (el.caret.hidden !== hide) el.caret.hidden = hide;
    const wake = ex.mt_next_wake();
    if (wake === 0) kick();
    else if (wake > 0) {
      clearTimeout(timer);
      timer = setTimeout(kick, wake);
    }
  }

  function kick() {
    if (!scheduled) {
      scheduled = true;
      requestAnimationFrame(frame);
    }
  }

  function fadeIn(x) {
    if (!still.matches) x.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 180, easing: "ease-out" });
  }

  // ------ quotes: the server deals this browser a shuffled queue, a window
  // at a time; the cookie remembers the position across page loads.

  function refill() {
    if (refilling) return refilling;
    const q = queue;
    const at = q.from + q.quotes.length;
    const url = `/quotes?lang=${encodeURIComponent(cfg.language)}&q=${cfg.quoteGroups}&seed=${q.seed}&from=${at}`;
    refilling = fetch(url)
      .then((r) => (r.ok ? r.json() : []))
      .then((more) => {
        q.quotes.push(...more);
      })
      .catch(() => {})
      .finally(() => {
        refilling = null;
      });
    return refilling;
  }

  // Hands the next quote to the core. False when there is none to hand.
  async function nextQuote() {
    if (queue.next >= queue.quotes.length) await refill();
    const q = queue.quotes[queue.next];
    if (q === undefined) return false;
    queue.next++;
    document.cookie = `typer_queue=${queue.seed}.${queue.from + queue.next}; Path=/; Max-Age=31536000; SameSite=Lax`;
    if (queue.quotes.length - queue.next <= 5) refill();
    const text = encoder.encode(q.text);
    const source = encoder.encode(q.source);
    const lang = encoder.encode(cfg.quoteLanguage);
    const p = ex.mt_inbox(text.length + source.length + lang.length);
    const m = views();
    m.set(text, p);
    m.set(source, p + text.length);
    m.set(lang, p + text.length + source.length);
    ex.mt_set_quote(text.length, source.length, lang.length, q.id, q.group);
    return true;
  }

  // ------ test lifecycle

  // same: the text just shown again (same quote, or same words: which then
  // can't count, as on Monkeytype); otherwise new text.
  async function restart(same, fade = true) {
    const mine = el;
    same &&= seed !== null;
    if (!same) {
      if (cfg.mode === QUOTE && !(await nextQuote())) {
        el.stage.textContent = "no quotes of this length here yet";
        return;
      }
      if (el !== mine) return;
      seed = crypto.getRandomValues(new Uint32Array(2));
    }
    repeated = same && cfg.mode !== QUOTE;
    const flags = (cfg.punctuation ? 1 : 0) | (cfg.numbers ? 2 : 0) | (repeated ? 4 : 0);
    ex.mt_start(cfg.mode, cfg.mode2, flags, seed[0], seed[1]);
    topLine = 0;
    caretLine = -1;
    slide?.cancel();
    tabs = !!ex.mt_has_tabs();
    el.result.hidden = true;
    el.after.hidden = true;
    el.link.hidden = true;
    el.clip.hidden = false;
    el.timer.hidden = false;
    el.hint.hidden = false;
    hint();
    el.caret.classList.add("idle");
    el.wordsText.textContent = str(ex.mt_words_ptr(), ex.mt_input_len());
    el.input.value = " ";
    el.input.focus();
    if (fade) fadeIn(el.lines);
    kick();
  }

  function hint() {
    const key = tabs ? "shift + tab" : "tab";
    const what = cfg.mode === QUOTE ? "a new quote" : "new words";
    el.hint.innerHTML = `${repeated ? "same words again, so this one won't count · " : ""}<kbd>${key}</kbd> restart · twice for ${what}`;
  }

  // Tab restarts a test that has begun with the same text, and deals new
  // text before the first key and on the result.
  function onTab() {
    const phase = ex.mt_phase();
    restart(phase === ACTIVE || phase === FINISHING);
  }

  function showResult(html) {
    if (el === null) return;
    el.result.innerHTML = html;
    el.result.hidden = false;
    el.after.hidden = false;
    el.clip.hidden = true;
    el.timer.hidden = true;
    el.hint.hidden = true;
    fadeIn(el.result);
    fadeIn(el.after);
  }

  function syncInput() {
    const p = ex.mt_input_ptr();
    el.input.value = " " + str(p, ex.mt_input_len());
  }

  const codeOf = (e) => {
    const i = keyIndex.get(e.code);
    if (i !== undefined) return i;
    if (!e.code || e.key === "Unidentified") return noCode;
    return untracked;
  };

  // ------ input, bound to each mounted page's elements

  function listen({ input, stage, after }) {
    input.addEventListener("keydown", (e) => {
      if (ex === null) return;
      if (e.key === "Escape" && ex.mt_phase() === FINISHED) {
        e.preventDefault();
        restart(true);
        return;
      }
      // Tab restarts, unless the quote itself has tabs: then shift + tab does.
      if (e.key === "Tab" && (!tabs || e.shiftKey)) {
        e.preventDefault();
        onTab();
        return;
      }
      if (e.key.startsWith("Arrow") || e.key === "Home" || e.key === "End" || e.key === "PageUp" || e.key === "PageDown") {
        e.preventDefault();
      }
      ex.mt_key_down(e.timeStamp, codeOf(e), e.repeat ? 1 : 0);
      typed();
      if (!e.isComposing && !e.metaKey && !(e.ctrlKey && !e.altKey)) {
        // Physical keyboards: handle the key here and skip the textarea's
        // editing pipeline. IME, dead keys and mobile keyboards ("Process",
        // "Dead", "Unidentified") still go through beforeinput below.
        const key = e.key === "Tab" ? "\t" : e.key === "Enter" ? "\n" : e.key;
        if ([...key].length === 1) {
          e.preventDefault();
          const cp = key.codePointAt(0);
          if (ex.mt_before_insert(cp)) ex.mt_insert(e.timeStamp, cp);
          kick();
          return;
        }
        if (e.key === "Backspace") {
          e.preventDefault();
          deleteBackward(e.timeStamp, e.altKey ? 1 : 0);
          kick();
          return;
        }
      } else if (e.key === "Backspace" && e.ctrlKey && !e.isComposing) {
        e.preventDefault();
        deleteBackward(e.timeStamp, 1);
        kick();
        return;
      }
      kick();
    });

    // Releases change nothing on screen, so they schedule no frame.
    input.addEventListener("keyup", (e) => {
      if (ex !== null) ex.mt_key_up(e.timeStamp, codeOf(e));
    });

    input.addEventListener("beforeinput", (e) => {
      if (ex === null) return;
      const t = e.inputType;
      if (t === "insertText" || t === "insertLineBreak") {
        const data = t === "insertLineBreak" ? "\n" : e.data;
        if (data == null) {
          e.preventDefault();
          return;
        }
        const chars = [...data];
        if (chars.length === 1 && t === "insertText") {
          // Common case: the browser inserts the character itself.
          const cp = data.codePointAt(0);
          if (!ex.mt_before_insert(cp)) e.preventDefault();
          else if (ex.mt_insert(e.timeStamp, cp)) {
            e.preventDefault();
            syncInput();
          }
        } else {
          e.preventDefault();
          for (const ch of chars) {
            const cp = ch.codePointAt(0);
            if (ex.mt_before_insert(cp)) ex.mt_insert(e.timeStamp, cp);
          }
          syncInput();
        }
        kick();
      } else if (t === "deleteContentBackward" || t === "deleteWordBackward") {
        if (!ex.mt_before_delete()) {
          e.preventDefault();
          return;
        }
        pendingDelete = { ms: e.timeStamp, word: t === "deleteWordBackward" ? 1 : 0 };
      } else if (t !== "insertCompositionText") {
        e.preventDefault();
      }
    });

    input.addEventListener("input", () => {
      if (pendingDelete === null) return;
      const v = input.value;
      const remaining = v === "" ? -1 : [...v.slice(1)].length;
      ex.mt_delete(pendingDelete.ms, pendingDelete.word, remaining);
      pendingDelete = null;
      syncInput();
      kick();
    });

    input.addEventListener("compositionend", (e) => {
      for (const ch of e.data || "") {
        const cp = ch.codePointAt(0);
        if (ex.mt_before_insert(cp)) ex.mt_insert(e.timeStamp, cp);
      }
      syncInput();
      kick();
    });

    stage.addEventListener("pointerdown", (e) => {
      if (!e.target.closest("button, a")) input.focus();
    });
    after.querySelector("[data-next]").addEventListener("click", () => restart(false));
    after.querySelector("[data-repeat]").addEventListener("click", () => restart(true));
  }

  // Backspace without the browser: a character or the whole word input,
  // or back into the previous word when the input is already empty.
  function deleteBackward(ms, word) {
    if (!ex.mt_before_delete()) return;
    const len = [...str(ex.mt_input_ptr(), ex.mt_input_len())].length;
    const remaining = len === 0 ? -1 : word ? 0 : len - 1;
    ex.mt_delete(ms, word, remaining);
  }

  // Typing anywhere focuses the test; on the result Tab deals the next test
  // and Escape repeats this one, wherever the focus is.
  document.addEventListener("keydown", (e) => {
    if (el === null || ex === null || document.activeElement === el.input) return;
    if (e.key === "Tab") {
      e.preventDefault();
      onTab();
      return;
    }
    if (e.key === "Escape" && ex.mt_phase() === FINISHED) {
      e.preventDefault();
      restart(true);
      return;
    }
    if (e.target.closest("input, textarea, select, dialog")) return;
    if ((e.key === "Enter" || e.key === " ") && e.target.closest("button, a")) return;
    el.input.focus();
  });
  addEventListener("resize", () => {
    if (el === null || ex === null) return;
    size();
    ex.mt_resize(cssWidth);
    kick();
  });
  addEventListener("pagehide", flush);
  addEventListener("typer:theme", () => {
    colors = readColors();
    if (el === null || ex === null) return;
    ex.mt_redraw();
    kick();
  });

  window.typer = { prepare, mount, unmount };

  // This page may be the test; if not, warm up so the test opens drawn.
  if (!mount(document.querySelector("main"), true)) addEventListener("load", () => setTimeout(boot, 300));
})();
