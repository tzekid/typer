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
  let colors = [];

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
    }).catch((error) => { booting = null; throw error; });
    return booting;
  }

  function usePack(language, bytes) {
    if (language === packLanguage) return;
    let ok;
    if (language === "english") ok = ex.mt_use_english();
    else {
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
  const prepared = new WeakMap();
  function prepare(main) {
    const c = configOf(main);
    if (c === null) return;
    if (!prepared.has(main)) {
      prepared.set(main, Promise.all([
        boot(),
        c.mode === QUOTE || c.language === "english" ? null : fetch(c.pack).then((res) => {
          if (!res.ok) throw new Error(`language pack ${c.language} failed to load`);
          return res.arrayBuffer();
        }),
        c.language === "english" ? null : document.fonts.load(FONT, LATIN_EXT),
      ]).then(([, bytes]) => bytes).catch((error) => { prepared.delete(main); throw error; }));
    }
    // Preparing a page must not mutate the engine of the mounted test.
    return prepared.get(main);
  }

  // ------ results outbox: kept until the server acknowledges them

  const OUTBOX = "typer:outbox";
  let memoryBox = null;
  function readOutbox() {
    if (memoryBox) return memoryBox.slice();
    try {
      const items = JSON.parse(localStorage.getItem(OUTBOX) || "[]");
      return Array.isArray(items) ? items.filter(item => typeof item === "string") : [];
    } catch { return []; }
  }
  function writeOutbox(items) {
    try {
      localStorage.setItem(OUTBOX, JSON.stringify(items));
      memoryBox = null;
    } catch { memoryBox = items; }
  }
  const lock = (name, fn) => navigator.locks ? navigator.locks.request(name, fn) : fn();
  async function changeIdentity(request) {
    return lock("typer:upload", async () => {
      const response = await request();
      if (response.ok) {
        await lock(OUTBOX, () => writeOutbox([]));
        displayedRecord = null;
        resultChannel?.postMessage({ forgotten: true });
      }
      return response;
    });
  }
  const toB64 = (bytes) => {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const fromB64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  let flushing = false;
  let retryTimer = 0;
  let displayedRecord = null;
  const resultChannel = window.BroadcastChannel ? new BroadcastChannel("typer:results") : null;

  function savedResult({ record, location, name, forgotten }) {
    if (forgotten) {
      memoryBox = null;
      displayedRecord = null;
      return;
    }
    const nav = document.querySelector("header.top nav");
    if (name && nav && !nav.querySelector(".me")) {
      const me = document.createElement("a");
      me.className = "me";
      me.href = "/me";
      me.textContent = name;
      nav.append(me);
    }
    if (record === displayedRecord && location && el && !el.result.hidden) {
      el.status.textContent = "";
      el.link.href = location;
      el.link.hidden = false;
    }
  }
  if (resultChannel) resultChannel.onmessage = event => savedResult(event.data);

  async function enqueue(record) {
    const encoded = toB64(record);
    displayedRecord = encoded;
    // Keep storage updates short; an upload never blocks a new local save.
    await lock(OUTBOX, () => {
      const box = readOutbox();
      box.push(encoded);
      writeOutbox(box);
    });
    flush();
  }

  async function flush() {
    if (flushing) return;
    clearTimeout(retryTimer);
    flushing = true;
    let retry = false;
    try {
      // Only one tab uploads at a time, including the first response that
      // establishes the browser's identity cookie.
      await lock("typer:upload", async () => {
        if (!readOutbox().length) return;
        // Receive the identity cookie before any result can be committed.
        const session = await fetch("/me/session", { method: "POST" });
        if (!session.ok) throw new Error("Could not establish the typist session");
        for (;;) {
          const box = readOutbox();
          if (box.length === 0) break;
          const body = fromB64(box[0]);
          // keepalive lets a page being left finish the upload, but browsers
          // refuse keepalive bodies over 64 KiB (long tests, long quotes).
          const res = await fetch("/results", {
            method: "POST",
            headers: { "content-type": "application/octet-stream" },
            body,
            keepalive: body.length <= 60000,
          });
          // Rate limits and server trouble pass: keep the record for later. Any
          // other refusal is final, and must not hold back the records after it.
          if (res.status === 429 || res.status >= 500) {
            retry = true;
            break;
          }
          await lock(OUTBOX, () => {
            const rest = readOutbox();
            const at = rest.indexOf(box[0]);
            if (at >= 0) rest.splice(at, 1);
            writeOutbox(rest);
          });
          const loc = res.headers.get("location");
          if (res.ok && loc) {
            const saved = { record: box[0], location: loc, name: decodeURIComponent(res.headers.get("x-typist") || "") };
            savedResult(saved);
            resultChannel?.postMessage(saved);
          } else if (box[0] === displayedRecord && el) {
            el.status.textContent = "This result could not be saved.";
          }
        }
      });
    } catch (_) {
      // offline or server restarting: the outbox keeps the record
      retry = true;
    } finally {
      flushing = false;
      if (retry) {
        if (el && displayedRecord) el.status.textContent = memoryBox ? "Waiting to save. Keep this tab open." : "Queued. Will retry shortly.";
        retryTimer = setTimeout(flush, 5000);
      }
      else if (readOutbox().length) retryTimer = setTimeout(flush, 0);
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
      status: main.querySelector("[data-save-status]"),
      hint: $("hint"),
      wordsText: $("words-text"),
    };
    ctx = el.canvas.getContext("2d", { alpha: false, desynchronized: true });
    el.canvas.addEventListener("contextrestored", repaint);
    motion = still.matches ? 0 : cfg.caretMs;
    queue = { seed: cfg.queue?.seed, from: cfg.queue?.from ?? 0, quotes: cfg.quotes ?? [], next: 0 };
    seed = null;
    textGen = -1;
    if (cfg.rtl || cfg.joining) mountShaped(el, cfg.rtl);
    el.releaseViewport = followTypingViewport(el);
    listen(el);
    const mine = el;
    prepare(main)
      .then((bytes) => {
        if (el !== mine) return;
        if (cfg.mode !== QUOTE) usePack(cfg.language, bytes);
        lineH = ex.mt_line_height();
        el.caret.style.height = `${lineH}px`;
        el.clip.style.height = `${lineH * 3}px`;
        el.lines.style.top = `${-lineH}px`;
        size();
        // WebKit can return empty custom properties during script startup.
        // Read the palette after the mounted page has been laid out.
        colors = readColors();
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
    pendingDelete = null;
    if (el.shaped) clearShapedHighlights();
    el.releaseViewport?.();
    el = null;
    cfg = null;
    flush();
  }

  // On phones the keyboard can pan the visual viewport independently of the
  // document. Center the painted lines, which sit below the hidden input.
  function followTypingViewport({ stage, input, clip, result }) {
    const view = window.visualViewport;
    if (!view || !matchMedia("(any-pointer: coarse)").matches) return;

    const events = new AbortController();
    const options = { signal: events.signal, passive: true };
    let width = view.width;
    let fullHeight = view.height;
    let previousScrollY = scrollY;
    let following = false;
    let touchSelected = false;
    let userScrolled = false;
    let alignTimer, restoreTimer;
    let rotatedWhileTyping = false;
    const keyboardSizes = {}; // last measured keyboard viewport in each orientation

    function release(restore) {
      if (!following) return;
      document.body.style.removeProperty("min-height");
      if (restore && !userScrolled) {
        const y = previousScrollY;
        // Safari can ignore scroll requests while its native dismissal is
        // finishing, even after reporting the full viewport height.
        restoreTimer = setTimeout(() => {
          if (!document.hidden && (document.activeElement === document.body || document.activeElement === input)) {
            document.scrollingElement.scrollTop = y;
          }
        }, document.activeElement === input ? 0 : 600);
      }
      rotatedWhileTyping = false;
      following = false;
      touchSelected = false;
      userScrolled = false;
    }

    function align() {
      if (document.hidden) return;
      if (view.scale !== 1) {
        if (document.activeElement !== input || !result.hidden) release(false);
        return;
      }
      const editing = document.activeElement === input;
      if (view.width !== width) {
        rotatedWhileTyping = following && editing;
        width = view.width;
        fullHeight = document.documentElement.clientHeight;
      }
      // Browser toolbar movement is smaller than a docked software keyboard.
      const layoutHeight = document.documentElement.clientHeight;
      const open = Math.max(layoutHeight, touchSelected ? fullHeight : 0) - view.height > 100;
      const lines = clip.getBoundingClientRect();
      const orientation = width > layoutHeight ? "landscape" : "portrait";
      // During rotation Safari may report its full landscape viewport or
      // a sliver in portrait while the same keyboard is still on screen.
      const rotating = rotatedWhileTyping && editing && (!open || view.height < lines.height);
      if (open && !rotating && editing && lines.height) {
        keyboardSizes[orientation] = { width, height: view.height };
        rotatedWhileTyping = false;
      }
      const leftEditor = !editing && document.activeElement !== document.body;
      if ((!open && !rotating) || !result.hidden || leftEditor) {
        release(!open && result.hidden && !leftEditor);
        if (!open) fullHeight = Math.max(view.height, layoutHeight);
        return;
      }
      // Done blurs the input before Safari finishes dismissing the keyboard.
      // Restore on the ensuing resize, after its native pan has finished.
      if (!editing || userScrolled || !lines.height) return;
      let height = view.height;
      if (rotating) {
        const known = keyboardSizes[orientation];
        if (known?.width === width) height = known.height;
        else if (layoutHeight <= lines.height * 3) height = lines.height;
      }
      const pageTop = Math.max(0, scrollY + lines.top + (lines.height - height) / 2);
      // Short pages otherwise hit their bottom scroll limit before the text
      // reaches the center. The footer absorbs the extra height.
      const needed = Math.ceil(pageTop + (rotating ? layoutHeight : view.height));
      if (document.documentElement.scrollHeight < needed) document.body.style.minHeight = needed + "px";
      following = true;
      // Safari can report the same keyboard pan in both scrollY and offsetTop.
      // Compare positions in document coordinates to avoid applying it twice.
      const delta = pageTop - view.pageTop;
      if (Math.abs(delta) > 1) window.scrollBy({ top: delta, behavior: still.matches ? "auto" : "smooth" });
    }

    function schedule() {
      clearTimeout(alignTimer);
      alignTimer = setTimeout(align, 90);
    }

    function select() {
      clearTimeout(restoreTimer);
      if (!following) previousScrollY = scrollY;
      userScrolled = false;
      schedule();
    }

    function userScroll() {
      clearTimeout(restoreTimer);
      if (following || (touchSelected && document.activeElement === input)) userScrolled = true;
    }

    stage.addEventListener("pointerdown", e => {
      touchSelected = e.pointerType === "touch" || e.pointerType === "pen";
      select();
    }, options);
    input.addEventListener("focus", select, options);
    input.addEventListener("blur", schedule, options);
    view.addEventListener("resize", schedule, options);
    document.addEventListener("visibilitychange", schedule, options);
    window.addEventListener("pageshow", schedule, options);
    window.addEventListener("pointerdown", () => clearTimeout(restoreTimer), options);
    window.addEventListener("touchmove", userScroll, options);
    window.addEventListener("wheel", userScroll, options);
    return () => {
      clearTimeout(alignTimer);
      clearTimeout(restoreTimer);
      events.abort();
      release(false);
    };
  }

  // ------ drawing

  function size() {
    if (!el.clip.clientWidth) return;
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
    const key = ptr;
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

  // Native text layout keeps joined glyphs and bidirectional runs intact.
  // Each word has one text node. Ranges paint feedback without splitting it.
  function mountShaped(elements, rtl) {
    const layer = document.createElement("div");
    layer.className = "shaped-words";
    layer.dir = rtl ? "rtl" : "ltr";
    layer.setAttribute("aria-hidden", "true");
    elements.lines.before(layer);
    elements.shaped = layer;
    elements.shapedWords = [];
    elements.shapedActive = 0;
    elements.canvas.hidden = true;
  }

  const highlights = ["typed-correct", "typed-error", "typed-extra"];
  function clearShapedHighlights() {
    for (const name of highlights) CSS.highlights?.delete(name);
  }

  function drawShaped() {
    const layer = el.shaped;
    const words = el.shapedWords;
    const count = ex.mt_word_count();
    for (let i = words.length; i < count; i++) {
      const target = str(ex.mt_word_text(i, 0), ex.mt_input_len());
      const newline = target.endsWith("\n");
      const display = target.replace(/[ \n]$/u, "").replaceAll("\t", "→") + (newline ? "↵" : "");
      const span = document.createElement("span");
      const node = document.createTextNode(display);
      span.append(node);
      layer.append(span, newline ? document.createElement("br") : document.createTextNode(" "));
      words.push({ target, display, node, span, input: null });
    }
    const active = ex.mt_active_word();
    // A cross-word deletion can change both neighboring words in one frame.
    const previous = el.shapedActive ?? 0;
    const sets = el.shapedSets ??= highlights.map(() => typeof Highlight === "function" ? new Highlight() : new Set());
    const start = Math.max(0, Math.min(active, previous) - 1);
    const end = Math.min(count - 1, Math.max(active, previous) + 1);
    for (let i = start; i <= end; i++) {
      const word = words[i];
      const input = str(ex.mt_word_text(i, 1), ex.mt_input_len());
      if (input === word.input) continue;
      word.input = input;
      for (const [kind, range] of word.ranges || []) sets[kind].delete(range);
      word.ranges = [];
      const chars = Array.from(word.display);
      const actual = Array.from(input.replace(/[ \n]$/u, ""));
      const target = Array.from(word.target);
      const extras = actual.slice(chars.length).join("");
      word.node.data = word.display + extras;
      let offset = 0;
      for (let k = 0; k < actual.length; k++) {
        const glyph = chars[k] ?? actual[k];
        const range = new Range();
        range.setStart(word.node, offset);
        offset += glyph.length;
        range.setEnd(word.node, offset);
        const kind = k >= chars.length ? 2 : actual[k] === target[k] ? 0 : 1;
        sets[kind].add(range);
        word.ranges.push([kind, range]);
      }
      word.caretOffset = offset;
    }
    el.shapedActive = active;
    for (const [i, name] of highlights.entries()) CSS.highlights?.set(name, sets[i]);
    const w = words[active];
    if (!w) return;
    const range = new Range();
    range.setStart(w.node, w.caretOffset || 0);
    range.collapse(true);
    const point = range.getBoundingClientRect();
    const clip = el.clip.getBoundingClientRect();
    const row = Math.round((w.span.offsetTop || 0) / lineH);
    const top = Math.max(0, row - 1) * lineH;
    layer.style.transform = `translateY(-${top}px)`;
    const origin = el.lines.getBoundingClientRect();
    const x = point.height ? point.left : w.span.getBoundingClientRect()[cfg.rtl ? "right" : "left"];
    const caretWidth = parseFloat(getComputedStyle(el.caret).width);
    const caretLeft = Math.max(0, Math.min(x - clip.left - (cfg.rtl ? caretWidth : 0), clip.width - caretWidth));
    el.caret.style.transform = `translate(${caretLeft}px, ${clip.top - origin.top + row * lineH - top}px)`;
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
    if (!el?.ready) return;
    const n = ex.mt_frame(now);
    if (el.shaped) {
      if (n > 0) drawShaped();
    } else if (n > 0) draw(n);
    const count = ex.mt_word_count();
    if (el.accessibleCount !== count) {
      el.wordsText.textContent = str(ex.mt_words_ptr(), ex.mt_input_len());
      el.accessibleCount = count;
    }
    const top = ex.mt_top_line();
    if (top !== topLine) {
      if (!el.shaped && top > topLine && motion > 0 && ex.mt_phase() === ACTIVE) slideUp(top - topLine);
      topLine = top;
    }
    if (!el.shaped) placeCaret();
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
    const q = queue;
    if (q.refilling) return q.refilling;
    const at = q.from + q.quotes.length;
    const url = `/quotes?lang=${encodeURIComponent(cfg.language)}&q=${cfg.quoteGroups}&seed=${q.seed}&from=${at}`;
    q.refilling = fetch(url)
      .then((r) => (r.ok ? r.json() : []))
      .then((more) => {
        q.quotes.push(...more);
      })
      .catch(() => {})
      .finally(() => {
        q.refilling = null;
      });
    return q.refilling;
  }

  // Hands the next quote to the core. False when there is none to hand.
  async function nextQuote() {
    const mine = queue;
    if (queue.next >= queue.quotes.length) await refill();
    if (queue !== mine || el === null) return false;
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
    if (mine.restarting) return;
    same &&= seed !== null;
    if (!same) {
      if (cfg.mode === QUOTE) {
        if (!cfg.quotes.length) {
          mine.stage.textContent = "No quotes of this length in this language.";
          mine.hint.hidden = true;
          return;
        }
        mine.restarting = true;
        let ready;
        try { ready = await nextQuote(); } finally { mine.restarting = false; }
        if (el !== mine) return;
        if (!ready) {
          const retry = document.createElement("button");
          retry.type = "button";
          retry.className = "quiet";
          retry.textContent = "Try again";
          retry.onclick = () => restart(false);
          mine.hint.replaceChildren("Could not load the next quote. ", retry);
          mine.hint.hidden = false;
          retry.focus();
          return;
        }
      }
      if (el !== mine) return;
      seed = crypto.getRandomValues(new Uint32Array(2));
    }
    repeated = same && cfg.mode !== QUOTE;
    const flags = (cfg.punctuation ? 1 : 0) | (cfg.numbers ? 2 : 0) | (repeated ? 4 : 0);
    if (el.shaped) { el.shaped.replaceChildren(); el.shapedWords = []; el.shapedActive = 0; el.shapedSets = null; clearShapedHighlights(); }
    ex.mt_start(cfg.mode, cfg.mode2, flags, seed[0], seed[1]);
    el.ready = true;
    topLine = 0;
    caretLine = -1;
    slide?.cancel();
    tabs = !!ex.mt_has_tabs();
    el.result.hidden = true;
    el.after.hidden = true;
    el.link.hidden = true;
    displayedRecord = null;
    el.clip.hidden = false;
    if (el.clip.clientWidth !== cssWidth) { size(); ex.mt_resize(cssWidth); }
    pendingDelete = null;
    el.compositionEpoch = (el.compositionEpoch || 0) + 1;
    el.status.textContent = "";
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
    el.hint.innerHTML = `${repeated ? "Same words again. This score won't count. " : ""}<span class="desktop-shortcut"><kbd>tab</kbd> ${tabs ? "indent · " : "restart · "}<kbd>shift + tab</kbd> leave test</span><button type="button" class="quiet touch-restart">${repeated ? "new words" : "restart"}</button>`;
    const button = el.hint.querySelector("button");
    if (tabs) button.classList.remove("touch-restart");
    button.onclick = repeated ? () => restart(false) : onTab;
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
    document.dispatchEvent(new CustomEvent("typer:result", { detail: el.result }));
    el.result.hidden = false;
    el.status.textContent = "Saving…";
    el.after.hidden = false;
    el.after.querySelector("[data-next]").focus({ preventScroll: true });
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
    // Keys an input method takes part in: a dead key's follow-up (macOS
    // US International: ' then space gives a lone '), IME composition.
    // Their text arrives through composition events, never the fast path.
    // Safari ends the composition before sending the keydown of the key
    // that ended it, so a keydown in the same instant as a compositionend
    // belongs to it as well.
    let composing = false;
    let composedAt = -Infinity;
    const imeKey = (e) => composing || e.isComposing || e.keyCode === 229 || e.timeStamp - composedAt < 30;

    input.addEventListener("keydown", (e) => {
      if (!el?.ready || !el.result.hidden) return;
      // Shift+Tab always leaves the editor. Tab indents code or restarts prose.
      if (e.key === "Tab" && e.shiftKey) return;
      if (e.key === "Tab" && !tabs) {
        e.preventDefault();
        if (!e.repeat) onTab();
        return;
      }
      if (e.key.startsWith("Arrow") || e.key === "Home" || e.key === "End" || e.key === "PageUp" || e.key === "PageDown") {
        e.preventDefault();
      }
      ex.mt_key_down(e.timeStamp, codeOf(e), e.repeat ? 1 : 0);
      typed();
      const ime = imeKey(e);
      if (!ime && !e.metaKey && !(e.ctrlKey && !e.altKey)) {
        // Physical keyboards: handle the key here and skip the textarea's
        // editing pipeline. IME, dead keys and mobile keyboards ("Process",
        // "Dead", "Unidentified") still go through beforeinput below.
        const key = e.key === "Tab" ? "\t" : e.key === "Enter" ? "\n" : e.key;
        if ([...key].length === 1) {
          e.preventDefault();
          const cp = key.codePointAt(0);
          if (ex.mt_before_insert(cp)) ex.mt_insert(e.timeStamp, cp);
          syncInput();
          kick();
          return;
        }
        if (e.key === "Backspace") {
          e.preventDefault();
          deleteBackward(e.timeStamp, e.altKey ? 1 : 0);
          kick();
          return;
        }
      } else if (e.key === "Backspace" && (e.ctrlKey || e.metaKey) && !ime) {
        e.preventDefault();
        deleteBackward(e.timeStamp, 1);
        kick();
        return;
      }
      kick();
    });

    // Releases change nothing on screen, so they schedule no frame.
    input.addEventListener("keyup", (e) => {
      if (el?.ready) ex.mt_key_up(e.timeStamp, codeOf(e));
    });

    input.addEventListener("beforeinput", (e) => {
      if (!el?.ready) return;
      const t = e.inputType;
      if (composing || e.isComposing || /Composition/.test(t)) return;
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
      } else if (t === "deleteContentBackward" || t === "deleteWordBackward" || t === "deleteHardLineBackward") {
        if (!ex.mt_before_delete()) {
          e.preventDefault();
          return;
        }
        pendingDelete = { ms: e.timeStamp, word: t === "deleteContentBackward" ? 0 : 1 };
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

    let composition = [];
    let baseLength = 0;
    let compositionEpoch;
    function updateComposition(value, ms, commit) {
      if (compositionEpoch !== el?.compositionEpoch || !el?.result.hidden) return;
      const next = Array.from(value || "");
      // An IME may replace the entire candidate on every key. Keep the
      // unchanged prefix and record only edits the keyboard actually made.
      let prefix = 0;
      while (prefix < next.length && prefix < composition.length && next[prefix] === composition[prefix]) prefix++;
      if (prefix < composition.length && ex.mt_before_delete()) {
        ex.mt_delete(ms, 0, baseLength + prefix);
      }
      composition.length = prefix;
      for (const ch of next.slice(prefix)) {
        if (!commit && /\s/u.test(ch)) break;
        const cp = ch.codePointAt(0);
        if (!ex.mt_before_insert(cp)) break;
        ex.mt_insert(ms, cp);
        composition.push(ch);
      }
      typed();
      kick();
    }
    input.addEventListener("compositionstart", e => {
      if (!el?.ready) return;
      composing = true;
      const current = str(ex.mt_input_ptr(), ex.mt_input_len());
      const replacing = e.data || "";
      composition = current.endsWith(replacing) ? Array.from(replacing) : [];
      compositionEpoch = el.compositionEpoch;
      baseLength = Array.from(current).length - composition.length;
    });
    input.addEventListener("compositionupdate", e => {
      if (composing) updateComposition(e.data, e.timeStamp, false);
    });

    input.addEventListener("compositionend", (e) => {
      if (!composing) return;
      composing = false;
      composedAt = e.timeStamp;
      updateComposition(e.data, e.timeStamp, true);
      syncInput();
      kick();
    });

    // Touch keyboards open only from a tap's own events; the mouse is
    // handled in the document mousedown listener below.
    stage.addEventListener("click", () => {
      if (el?.input === input && el.result.hidden) input.focus({ preventScroll: true });
    });

    // Focus really went elsewhere in the page (not to another app or tab,
    // which give it back on return): say so.
    let away = 0;
    input.addEventListener("blur", () => {
      clearTimeout(away);
      away = setTimeout(() => {
        if (el?.input === input && document.hasFocus() && document.activeElement !== input && el.result.hidden) stage.classList.add("unfocused");
      }, 500);
    });
    input.addEventListener("focus", () => {
      clearTimeout(away);
      stage.classList.remove("unfocused");
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
    syncInput();
  }

  // While a test is up, the mouse never takes focus from it: a press on the
  // page background, the text or the setup bar would otherwise blur the
  // input (links and buttons still get their clicks). On the result, the
  // page behaves normally, so its text can be selected.
  document.addEventListener("mousedown", (e) => {
    if (el === null || e.button !== 0 || !el.result.hidden) return;
    if (e.target.closest("a, button, input, textarea, select, [contenteditable]")) return;
    e.preventDefault();
    if (document.activeElement !== el.input) el.input.focus();
  });

  // Printable keys can focus the test. Results retain ordinary focus navigation
  // and Escape repeats the finished test.
  document.addEventListener("keydown", (e) => {
    if (!el?.ready || document.activeElement === el.input) return;
    if (e.target.closest(".chart-box")) return;
    if (e.key === "Escape" && ex.mt_phase() === FINISHED) {
      e.preventDefault();
      restart(true);
      return;
    }
    if (e.target.closest("input, textarea, select, dialog")) return;
    if ((e.key === "Enter" || e.key === " ") && e.target.closest("button, a")) return;
    if (el.result.hidden && !e.metaKey && !e.altKey && !e.ctrlKey && [...e.key].length === 1) el.input.focus();
  });
  addEventListener("resize", () => {
    if (!el?.ready) return;
    size();
    ex.mt_resize(cssWidth);
    kick();
  });
  // A tab in the background can lose its canvas pixels (Safari frees the
  // backing store; a lost 2D context also forgets its scale and font), and
  // frames only paint what changed. Coming back repaints everything.
  function repaint() {
    if (!el?.ready || document.visibilityState !== "visible") return;
    size();
    ex.mt_resize(cssWidth);
    ex.mt_redraw();
    kick();
  }
  document.addEventListener("visibilitychange", repaint);
  addEventListener("pageshow", (e) => {
    if (e.persisted) repaint();
  });
  addEventListener("pagehide", flush);
  addEventListener("online", flush);
  addEventListener("typer:theme", () => {
    colors = readColors();
    if (!el?.ready) return;
    ex.mt_redraw();
    kick();
  });

  window.typer = { prepare, mount, unmount, changeIdentity };

  // This page may be the test; if not, warm up so the test opens drawn.
  if (!mount(document.querySelector("main"), true)) addEventListener("load", () => setTimeout(() => boot().catch(() => {}), 300));
  flush();
})();
