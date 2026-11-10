// typer's page glue, on every page:
// - the <{ ◐ }> theme switch;
// - in-place navigation: links and forms fetch the next page and swap in its
//   <header> and <main>, so nothing reloads and the island keeps running;
// - settings that save as they change, copy buttons, the language filter;
// - chart readouts for pointer, touch and keyboard, and result series toggles.
// Without script, all of it still works as plain links and forms.
(() => {
  "use strict";

  const root = document.documentElement;

  // ------ theme: a cookie, so the server renders the right one next time

  const media = matchMedia("(prefers-color-scheme: dark)");
  const channel = "BroadcastChannel" in window ? new BroadcastChannel("typer:theme") : null;
  const current = () => root.dataset.theme || (media.matches ? "dark" : "light");

  // theme: "light", "dark" or "" to follow the system.
  function setTheme(theme, announce) {
    if (theme) root.dataset.theme = theme;
    else delete root.dataset.theme;
    document.cookie = `typer_theme=${theme}; Path=/; Max-Age=${theme ? 31536000 : 0}; SameSite=Lax`;
    for (const radio of document.querySelectorAll('input[name="theme"]')) radio.checked = radio.value === (theme || "system");
    dispatchEvent(new CustomEvent("typer:theme"));
    if (announce && channel) channel.postMessage(theme);
  }

  document.addEventListener("click", (e) => {
    if (!e.target.closest("[data-theme-toggle]")) return;
    e.preventDefault();
    setTheme(current() === "dark" ? "light" : "dark", true);
    // Back to the test, so the next space types instead of flipping again.
    document.getElementById("typer-input")?.focus();
  });
  if (channel) channel.onmessage = (e) => setTheme(e.data, false);
  media.addEventListener("change", () => {
    if (!root.dataset.theme) dispatchEvent(new CustomEvent("typer:theme"));
  });

  // ------ navigation

  history.scrollRestoration = "manual";
  const NATIVE = /^\/(assets|packs|key)\//;
  let early = null; // { href, page }: fetched on pointerdown, used on click
  let latest = 0; // a newer navigation wins over a slower older one

  function target(a, e) {
    if (!a || a.target || a.hasAttribute("download")) return null;
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return null;
    const url = new URL(a.href, location.href);
    if (url.origin !== location.origin || NATIVE.test(url.pathname)) return null;
    if (url.hash && url.pathname === location.pathname && url.search === location.search) return null;
    return url;
  }

  const load = async (href, init) => {
    await settingsSave;
    return fetch(href, { ...init, headers: { accept: "text/html" } });
  };

  // Most clicks start ~80 ms before they finish: begin fetching right away.
  document.addEventListener("pointerdown", (e) => {
    const url = target(e.target.closest("a[href]"), e);
    if (url) early = { href: url.href, page: load(url.href) };
  });

  document.addEventListener("click", (e) => {
    if (e.defaultPrevented) return;
    const url = target(e.target.closest("a[href]"), e);
    if (!url) return;
    e.preventDefault();
    const page = early?.href === url.href ? early.page : load(url.href);
    early = null;
    go(url.href, page, true);
  });

  document.addEventListener("submit", (e) => {
    const form = e.target;
    const url = new URL(form.action, location.href);
    if (e.defaultPrevented || form.target || url.origin !== location.origin) return;
    e.preventDefault();
    const data = new URLSearchParams(new FormData(form, e.submitter));
    if (form.method === "get") {
      url.search = data;
      go(url.href, load(url.href), true);
    } else {
      go(url.href, load(url.href, { method: "POST", body: data }), true);
    }
  });

  addEventListener("popstate", () => go(location.href, load(location.href), false));

  async function go(href, page, push) {
    const mine = ++latest;
    const slow = setTimeout(() => root.classList.add("loading"), 150);
    try {
      const res = await page;
      const html = (res.headers.get("content-type") || "").startsWith("text/html");
      const text = await res.text();
      if (mine !== latest) return;
      if (!res.ok && !html) {
        problem(text);
        return;
      }
      const doc = new DOMParser().parseFromString(text, "text/html");
      const next = doc.querySelector("main");
      await Promise.all([
        window.typer?.prepare(next),
        next?.dataset.page === "history" ? document.fonts.load('13px "DM Mono"', next.textContent) : null,
      ]);
      if (mine !== latest) return;
      if (push) {
        history.replaceState({ y: scrollY }, "");
        history.pushState(null, "", res.url + new URL(href).hash);
      }
      swap(doc, push ? 0 : history.state?.y ?? 0);
      // A link into the page (#recent) lands there, as it would without script.
      if (push && new URL(href).hash) document.getElementById(new URL(href).hash.slice(1))?.scrollIntoView();
    } catch (_) {
      // offline or the server is restarting: let the browser say so
      if (mine === latest) location.assign(href);
    } finally {
      clearTimeout(slow);
      if (mine === latest) root.classList.remove("loading");
    }
  }

  function swap(doc, y) {
    leave();
    const before = document.querySelector("main");
    const main = doc.querySelector("main");
    // DOMParser parses as if script were off: drop what is only for that.
    for (const n of main.querySelectorAll("noscript")) n.remove();
    window.typer?.unmount();
    document.querySelector("header.top").replaceWith(doc.querySelector("header.top"));
    before.replaceWith(main);
    initCharts(main);
    document.title = doc.title;
    scrollTo(0, y);
    if (!window.typer?.mount(main)) (main.querySelector("[autofocus]") || main).focus({ preventScroll: true });
  }

  // Error responses are plain text (bad input, rate limit): show them in place.
  function problem(text) {
    const p = document.createElement("p");
    p.className = "message problem";
    p.textContent = text;
    document.querySelector("main").prepend(p);
  }

  // ------ settings save as they change

  let settingsSave = Promise.resolve();
  let settingsVersion = 0;
  document.addEventListener("change", (e) => {
    const form = e.target.form;
    if (!form?.hasAttribute("data-autosave")) return;
    if (e.target.name === "theme") setTheme(e.target.value === "system" ? "" : e.target.value, true);
    const saved = form.querySelector("[data-saved]");
    const body = new URLSearchParams(new FormData(form));
    const version = ++settingsVersion;
    if (saved) saved.hidden = true;
    // Set-Cookie responses must arrive in the same order as the choices.
    settingsSave = settingsSave.then(() => fetch(form.action, { method: "POST", body }))
      .then((res) => {
        if (!res.ok) throw new Error("Could not save settings. Please try again.");
        if (version === settingsVersion && saved?.isConnected) replay(saved);
      }).catch(() => {
        if (version === settingsVersion && form.isConnected) problem("Could not save settings. Please try again.");
      });
  });

  // Shows a toast again from the start (its CSS animation hides it).
  function replay(toast) {
    toast.hidden = true;
    void toast.offsetWidth;
    toast.hidden = false;
  }

  // ------ copy buttons: the field just before them

  document.addEventListener("click", (e) => {
    const button = e.target.closest("[data-copy]");
    if (!button) return;
    const field = button.previousElementSibling;
    navigator.clipboard.writeText(field.value).then(() => {
      button.textContent = "copied";
      setTimeout(() => (button.textContent = "copy"), 1500);
    });
    field.select();
  });

  // ------ filter: typing in it narrows a list (the languages)

  document.addEventListener("input", (e) => {
    const box = e.target.closest("[data-filter]");
    if (!box) return;
    const needle = box.value.trim().toLowerCase().replace(/\s+/g, "_");
    let shown = 0;
    for (const item of document.querySelectorAll(box.dataset.filter)) {
      const hit = item.textContent.includes(needle);
      item.hidden = !hit;
      shown += hit;
    }
    const none = document.querySelector("[data-none]");
    if (none) none.hidden = shown > 0;
  });

  // Enter in the filter opens the first language left.
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || !e.target.matches("[data-filter]")) return;
    const first = [...document.querySelectorAll(e.target.dataset.filter)].find((x) => !x.hidden);
    first?.querySelector("a")?.click();
  });

  // ------ charts: one readout style, using each plot's rendered points

  const HIDDEN = "typer:chart-hidden";
  const off = new Set((localStorage.getItem(HIDDEN) || "").split(" ").filter(Boolean));
  const showSeries = () => (root.dataset.chartHidden = [...off].join(" "));
  showSeries();

  document.addEventListener("click", (e) => {
    const button = e.target.closest(".chart-box [data-series]");
    if (!button) return;
    const s = button.dataset.series;
    if (!off.delete(s)) off.add(s);
    localStorage.setItem(HIDDEN, [...off].join(" "));
    showSeries();
    if (hovered?.box === button.closest(".chart-box")) showPoint(hovered, hovered.index);
  });

  const SERIES = [
    ["wpm", "wpm"],
    ["raw", "raw"],
    ["burst", "burst"],
    ["err", "errors"],
  ];
  const charts = new WeakMap();
  let hovered = null;
  let tipId = 0;

  function initCharts(scope) {
    for (const svg of scope.querySelectorAll(".chart-box svg")) {
      if (charts.has(svg)) continue;
      const box = svg.closest(".chart-box");
      const result = box.dataset.chart === "result";
      let points;
      if (result) {
        points = [...svg.querySelector("polyline.wpm").points].map((p, i) => ({ x: p.x, y: p.y, data: { label: `Second ${i + 1}` } }));
      } else {
        // A personal-best diamond can coincide with a sampled test dot.
        const unique = new Map();
        for (const el of svg.querySelectorAll("[data-chart-point]")) {
          el.querySelector("title")?.remove(); // native titles remain without JS
          const rect = el.getBBox();
          unique.set(el.dataset.order ?? unique.size, { el, x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, data: el.dataset });
        }
        points = [...unique.values()];
        if (box.dataset.chart === "history") points.sort((a, b) => Number(a.data.order) - Number(b.data.order));
        const overlay = document.createElementNS("http://www.w3.org/2000/svg", "g");
        overlay.setAttribute("class", "chart-hover");
        overlay.setAttribute("aria-hidden", "true");
        if (box.dataset.chart === "history") overlay.innerHTML = '<line class="guide" y1="33" y2="225"/>';
        overlay.innerHTML += '<circle class="chart-selection" r="6"/>';
        svg.append(overlay);
      }
      if (!points.length) continue;
      let tip = box.querySelector(".tip");
      if (!tip) {
        tip = document.createElement("div");
        tip.className = "tip";
        box.append(tip);
      }
      if (!tip.id) tip.id = `chart-tip-${++tipId}`;
      tip.setAttribute("role", "status");
      tip.setAttribute("aria-atomic", "true");
      tip.setAttribute("aria-hidden", "true");
      svg.setAttribute("tabindex", "0");
      svg.setAttribute("role", "group");
      svg.setAttribute("aria-describedby", `${svg.getAttribute("aria-describedby") || ""} ${tip.id}`.trim());
      svg.setAttribute("aria-description", "Use arrow keys to explore, Home or End to jump, and Escape to close." + (box.dataset.chart === "history" ? " Enter opens the selected test." : ""));
      for (const a of svg.querySelectorAll("a")) a.setAttribute("tabindex", "-1");
      charts.set(svg, { svg, box, tip, points, result, measured: result || svg.getClientRects().length > 0, index: 0, values: result ? Object.fromEntries(SERIES.map(([key]) => [key, box.dataset[key].split(",")])) : null });
    }
  }

  function row(tip, label, value, series) {
    const item = document.createElement("span");
    item.className = "tip-row";
    if (series) {
      const swatch = document.createElement("i");
      swatch.className = `swatch ${series}`;
      item.append(swatch);
    }
    item.append(document.createTextNode(label));
    const number = document.createElement("em");
    number.textContent = value;
    item.append(number);
    tip.append(item);
  }

  function showPoint(state, index, keyboard = false) {
    measureChart(state);
    const { svg, box, tip, points, result } = state;
    const point = points[index];
    if (hovered !== state) leave();
    state.keyboard = keyboard;
    const changed = hovered !== state || state.index !== index || state.hiddenSeries !== root.dataset.chartHidden;
    state.hiddenSeries = root.dataset.chartHidden;
    points[state.index].el?.classList.remove("chart-point-active");
    state.index = index;
    point.el?.classList.add("chart-point-active");
    const m = svg.getScreenCTM();
    if (!m) return;
    tip.setAttribute("aria-live", keyboard ? "polite" : "off");
    if (changed) {
      tip.replaceChildren();
      const title = document.createElement("b");
      title.textContent = point.data.label;
      tip.append(title);
      const value = document.createElement("strong");
      value.className = "tip-value";
      if (box.dataset.chart === "calendar") {
        const seconds = Number(point.data.seconds);
        value.textContent = seconds === 0 ? "No practice" : seconds < 60 ? `${Number(seconds.toFixed(1))} s` : `${Number((seconds / 60).toFixed(1))} min`;
        tip.append(value);
      } else {
        value.append(document.createTextNode(result ? state.values.wpm[index] : point.data.wpm));
        const unit = document.createElement("small");
        unit.textContent = "wpm";
        value.append(unit);
        tip.append(value);
        if (result) {
          for (const [key, label] of SERIES.slice(1)) {
            if (!off.has(key)) row(tip, label, state.values[key][index], key);
          }
        } else {
          row(tip, "Accuracy", `${point.data.acc}%`);
          if (point.data.average) row(tip, `Average (${point.data.count} ${point.data.count === "1" ? "test" : "tests"})`, `${point.data.average} wpm`, "wpm");
          if ("best" in point.data) {
            const best = document.createElement("p");
            best.className = "tip-best";
            best.textContent = "New personal best";
            tip.append(best);
          }
        }
      }
    }
    const guide = svg.querySelector(".guide");
    guide?.setAttribute("x1", point.x);
    guide?.setAttribute("x2", point.x);
    if (result) {
      for (const dot of svg.querySelectorAll(".dot")) {
        const key = dot.classList[1];
        dot.setAttribute("cx", point.x);
        dot.setAttribute("cy", svg.querySelector(`polyline.${key}`).points.getItem(index).y);
      }
    } else {
      const ring = svg.querySelector(".chart-selection");
      ring.setAttribute("cx", point.x);
      ring.setAttribute("cy", point.y);
    }
    const anchor = new DOMPoint(point.x, point.y).matrixTransform(m);
    const rect = box.getBoundingClientRect();
    const plot = svg.getBoundingClientRect();
    box.classList.add("hovering");
    const width = tip.offsetWidth, height = tip.offsetHeight;
    let left = anchor.x + 18;
    if (left + width > Math.min(rect.right, innerWidth - 12)) left = anchor.x - width - 18;
    left = Math.max(12, Math.min(left, innerWidth - width - 12));
    let top = anchor.y - height - 16;
    if (top < plot.top + 8) top = anchor.y + 16;
    top = Math.max(12, Math.min(top, plot.bottom - height - 8, innerHeight - height - 12));
    tip.style.transform = `translate(${left - rect.left}px, ${top - rect.top}px)`;
    tip.setAttribute("aria-hidden", "false");
    svg.classList.add("chart-active");
    box.classList.add("hovering");
    hovered = state;
  }

  function leave() {
    if (!hovered) return;
    hovered.points[hovered.index].el?.classList.remove("chart-point-active");
    hovered.svg.classList.remove("chart-active");
    hovered.box.classList.remove("hovering");
    hovered.tip.setAttribute("aria-hidden", "true");
    hovered = null;
  }

  function measureChart(state) {
    if (state.measured) return;
    for (const point of state.points) {
      const rect = point.el.getBBox();
      point.x = rect.x + rect.width / 2;
      point.y = rect.y + rect.height / 2;
    }
    state.measured = true;
  }

  for (const type of ["pointermove", "pointerdown"]) {
    document.addEventListener(type, (e) => {
      if (hovered?.tip.contains(e.target)) return;
      const svg = e.target.closest?.(".chart-box svg");
      const state = charts.get(svg);
      if (!state) {
        if (type === "pointerdown" || !hovered?.keyboard) leave();
        return;
      }
      if (type === "pointerdown" && e.pointerType === "touch") e.preventDefault();
      measureChart(state);
      const m = svg.getScreenCTM();
      if (!m) return;
      const at = new DOMPoint(e.clientX, e.clientY).matrixTransform(m.inverse());
      let index = 0, distance = Infinity;
      for (const [i, point] of state.points.entries()) {
        const d = (point.x - at.x) ** 2 + (state.result ? 0 : (point.y - at.y) ** 2);
        if (d < distance) { index = i; distance = d; }
      }
      showPoint(state, index);
    });
  }
  document.addEventListener("pointerout", (e) => {
    if (e.pointerType !== "touch" && hovered && !hovered.keyboard &&
        (hovered.svg.contains(e.target) || hovered.tip.contains(e.target)) &&
        !hovered.svg.contains(e.relatedTarget) && !hovered.tip.contains(e.relatedTarget)) leave();
  });
  // A tap leaves the readout open; tapping a tiny linked mark should not
  // navigate away before its values can be read.
  document.addEventListener("click", (e) => {
    if (e.pointerType === "touch" && e.target.closest?.(".chart-box svg")) e.preventDefault();
  }, true);
  document.addEventListener("pointercancel", leave);
  document.addEventListener("focusin", (e) => {
    const state = charts.get(e.target);
    if (state) showPoint(state, state.index, true);
    else leave();
  });
  document.addEventListener("focusout", (e) => {
    if (hovered?.svg === e.target) leave();
  });
  document.addEventListener("keydown", (e) => {
    const state = charts.get(e.target);
    if (e.key === "Escape") return leave();
    if (!state) return;
    let index = state.index;
    if (e.key === "ArrowRight" || e.key === "ArrowDown") index++;
    else if (e.key === "ArrowLeft" || e.key === "ArrowUp") index--;
    else if (e.key === "Home") index = 0;
    else if (e.key === "End") index = state.points.length - 1;
    else if (e.key === "Enter") {
      state.points[index].el?.closest("a")?.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      return;
    } else return;
    e.preventDefault();
    showPoint(state, Math.max(0, Math.min(index, state.points.length - 1)), true);
  });
  addEventListener("resize", leave);
  addEventListener("blur", leave);
  document.addEventListener("typer:result", (e) => initCharts(e.detail));
  initCharts(document);
})();
