// typer island: forwards browser input to core.wasm and executes its draw
// commands on a canvas. All test logic lives in the wasm.
(() => {
  "use strict";

  const cfg = JSON.parse(document.getElementById("typer-config").textContent);
  const canvas = document.getElementById("words");
  const input = document.getElementById("typer-input");
  const resultEl = document.getElementById("result");
  const wordsText = document.getElementById("words-text");
  const caret = document.getElementById("caret");
  const stage = document.getElementById("stage");

  const hint = document.querySelector(".hint kbd");

  const ctx = canvas.getContext("2d", { alpha: false, desynchronized: true });
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const colorNames = ["--bg", "--main", "--caret", "--sub", "--sub-alt", "--text", "--error", "--error-extra"];
  const readColors = () => {
    const css = getComputedStyle(document.documentElement);
    return colorNames.map((n) => css.getPropertyValue(n).trim());
  };
  let colors = readColors();
  const font = `${cfg.fontPx}px ${cfg.fontFamily}`;
  const quoteMode = cfg.quotes !== undefined;

  let ex = null;
  let mem = null;
  let u8 = null;
  let cssWidth = 0;
  let scheduled = false;
  let timer = 0;
  let pendingDelete = null;
  let textGen = -1;
  const textCache = new Map();
  let caretX = -1;
  let caretY = -1;
  let idleTimer = 0;
  const keyIndex = new Map();
  let untracked = 0xffff;
  let noCode = 0;
  let tabs = false;
  let cmdBase = -1;
  let cmdU32 = null;
  let cmdF32 = null;

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
      js_measure: (ptr, len) => ctx.measureText(str(ptr, len)).width,
      js_result: (hp, hl, rp, rl) => {
        const html = str(hp, hl);
        const record = views().slice(rp, rp + rl);
        showResult(html);
        enqueue(record);
      },
    },
  };

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
        if (res.ok) {
          const link = resultEl.querySelector("[data-result-link]");
          const loc = res.headers.get("location");
          if (link && loc) link.href = loc;
        }
      }
    } catch (_) {
      // offline or server restarting: the outbox keeps the record
    } finally {
      flushing = false;
    }
  }

  // ------ drawing

  function size() {
    cssWidth = Math.floor(stage.clientWidth);
    const h = ex.mt_height();
    const dpr = window.devicePixelRatio || 1;
    canvas.style.width = `${cssWidth}px`;
    canvas.style.height = `${h}px`;
    canvas.width = Math.round(cssWidth * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = font;
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
    for (let i = 0; i < n; i++) {
      const o = i * 8;
      const color = colors[u32[o + 1]];
      const op = u32[o];
      switch (op & 0x7f) {
        case 1:
          ctx.fillStyle = color;
          ctx.fillRect(0, 0, cssWidth, canvas.height);
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
          ctx.rect(a, 0, f32[o + 5] - a, canvas.height);
          ctx.clip();
          ctx.fillStyle = color;
          ctx.fillText(text(op, u32[o + 6], u32[o + 7]), f32[o + 2], f32[o + 3]);
          ctx.restore();
          break;
        }
      }
    }
  }

  function placeCaret() {
    const x = ex.mt_caret_x();
    const y = ex.mt_caret_y();
    if (x === caretX && y === caretY) return;
    caretX = x;
    caretY = y;
    caret.style.transform = `translate(${x - 1}px, ${y}px)`;
  }

  // The caret blinks only after a second without input.
  function typed() {
    caret.classList.remove("idle");
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => caret.classList.add("idle"), 1000);
  }

  function frame(now) {
    scheduled = false;
    const n = ex.mt_frame(now);
    if (n > 0) draw(n);
    placeCaret();
    const hide = ex.mt_phase() >= 2;
    if (caret.hidden !== hide) caret.hidden = hide;
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

  // ------ test lifecycle

  function seed() {
    const s = new Uint32Array(2);
    crypto.getRandomValues(s);
    return s;
  }

  // ------ quotes: the server deals this browser a shuffled queue, a window
  // at a time; the cookie remembers the position across page loads.

  const queue = { seed: cfg.queue?.seed, from: cfg.queue?.from ?? 0, quotes: cfg.quotes ?? [], next: 0 };
  let refilling = null;

  function refill() {
    if (refilling) return refilling;
    const at = queue.from + queue.quotes.length;
    const url = `/quotes?lang=${encodeURIComponent(cfg.language)}&q=${cfg.quoteGroups}&seed=${queue.seed}&from=${at}`;
    refilling = fetch(url)
      .then((r) => (r.ok ? r.json() : []))
      .then((more) => {
        queue.quotes.push(...more);
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

  async function restart() {
    const s = seed();
    resultEl.hidden = true;
    canvas.hidden = false;
    if (quoteMode && !(await nextQuote())) {
      stage.textContent = "no quotes of this length here yet";
      return;
    }
    const flags = (cfg.punctuation ? 1 : 0) | (cfg.numbers ? 2 : 0);
    ex.mt_start(cfg.mode, cfg.mode2, flags, s[0], s[1]);
    tabs = !!ex.mt_has_tabs();
    if (hint) hint.textContent = tabs ? "shift + tab" : "tab";
    caret.classList.add("idle");
    wordsText.textContent = str(ex.mt_words_ptr(), ex.mt_input_len());
    input.value = " ";
    input.focus();
    kick();
  }

  function showResult(html) {
    resultEl.innerHTML = html;
    resultEl.hidden = false;
    canvas.hidden = true;
  }

  function syncInput() {
    const p = ex.mt_input_ptr();
    input.value = " " + str(p, ex.mt_input_len());
  }

  const codeOf = (e) => {
    const i = keyIndex.get(e.code);
    if (i !== undefined) return i;
    if (!e.code || e.key === "Unidentified") return noCode;
    return untracked;
  };

  // ------ input

  input.addEventListener("keydown", (e) => {
    // Tab restarts, unless the quote itself has tabs: then shift + tab does.
    if (e.key === "Tab" && (!tabs || e.shiftKey)) {
      e.preventDefault();
      restart();
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

  // Backspace without the browser: a character or the whole word input,
  // or back into the previous word when the input is already empty.
  function deleteBackward(ms, word) {
    if (!ex.mt_before_delete()) return;
    ex.mt_input_ptr();
    const len = [...str(ex.mt_input_ptr(), ex.mt_input_len())].length;
    const remaining = len === 0 ? -1 : word ? 0 : len - 1;
    ex.mt_delete(ms, word, remaining);
  }

  // Releases change nothing on screen, so they schedule no frame.
  input.addEventListener("keyup", (e) => {
    ex.mt_key_up(e.timeStamp, codeOf(e));
  });

  input.addEventListener("beforeinput", (e) => {
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

  // Typing anywhere focuses the test; Tab restarts from the result screen too.
  document.addEventListener("keydown", (e) => {
    if (document.activeElement === input) return;
    if (e.key === "Tab") {
      e.preventDefault();
      restart();
      return;
    }
    if (e.target.closest("input, textarea, select, dialog")) return;
    input.focus();
  });
  stage.addEventListener("pointerdown", () => input.focus());
  window.addEventListener("resize", () => {
    size();
    ex.mt_resize(cssWidth);
    kick();
  });
  window.addEventListener("pagehide", flush);
  window.addEventListener("typer:theme", () => {
    colors = readColors();
    if (ex === null) return;
    ex.mt_redraw();
    kick();
  });

  // ------ boot

  async function boot() {
    const english = cfg.language === "english";
    const [{ instance }, pack] = await Promise.all([
      WebAssembly.instantiateStreaming(fetch(cfg.wasm), imports),
      english ? null : fetch(cfg.pack).then((r) => r.arrayBuffer()),
      document.fonts.load(font),
      english ? null : document.fonts.load(font, "ąćęłńśźżčďěňřšťůž"),
    ]);
    ex = instance.exports;
    mem = ex.memory;
    for (let i = 0; i < ex.mt_key_count(); i++) keyIndex.set(str(ex.mt_key_name_ptr(i), ex.mt_key_name_len(i)), i);
    noCode = keyIndex.get("NoCode");
    ctx.font = font;
    cssWidth = Math.floor(stage.clientWidth);
    ex.mt_init(cfg.fontPx, cssWidth);
    caret.style.height = `${ex.mt_line_height()}px`;
    caret.style.transitionDuration = `${cfg.caretMs}ms`;
    let ok = false;
    if (english) ok = ex.mt_use_english();
    else {
      const bytes = new Uint8Array(pack);
      const p = ex.mt_alloc(bytes.length);
      views().set(bytes, p);
      ok = ex.mt_set_pack(p, bytes.length);
    }
    if (!ok) throw new Error(`language pack ${cfg.language} failed to load`);
    size();
    ex.mt_resize(cssWidth);
    await restart();
    flush();
  }

  boot().catch((err) => {
    stage.textContent = `typer failed to start: ${err.message}`;
  });
})();
