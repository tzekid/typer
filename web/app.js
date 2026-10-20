// typer's page glue, on every page:
// - the <{ ◐ }> theme switch;
// - in-place navigation: links and forms fetch the next page and swap in its
//   <header> and <main>, so nothing reloads and the island keeps running;
// - settings that save as they change, copy buttons, the language filter;
// - the result chart's hover readout and series toggles.
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

  const load = (href, init) => fetch(href, { ...init, headers: { accept: "text/html" } });

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
      await window.typer?.prepare(doc.querySelector("main"));
      if (mine !== latest) return;
      if (push) {
        history.replaceState({ y: scrollY }, "");
        history.pushState(null, "", res.url);
      }
      swap(doc, push ? 0 : history.state?.y ?? 0);
    } catch (_) {
      // offline or the server is restarting: let the browser say so
      if (mine === latest) location.assign(href);
    } finally {
      clearTimeout(slow);
      if (mine === latest) root.classList.remove("loading");
    }
  }

  function swap(doc, y) {
    const before = document.querySelector("main");
    const main = doc.querySelector("main");
    // DOMParser parses as if script were off: drop what is only for that.
    for (const n of main.querySelectorAll("noscript")) n.remove();
    window.typer?.unmount();
    document.querySelector("header.top").replaceWith(doc.querySelector("header.top"));
    before.replaceWith(main);
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

  document.addEventListener("change", (e) => {
    const form = e.target.form;
    if (!form?.hasAttribute("data-autosave")) return;
    if (e.target.name === "theme") setTheme(e.target.value === "system" ? "" : e.target.value, true);
    const saved = form.querySelector("[data-saved]");
    fetch(form.action, { method: "POST", body: new URLSearchParams(new FormData(form)) }).then((res) => {
      if (res.ok && saved) replay(saved);
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

  // ------ result chart: per-second readout on hover, series toggles

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
  });

  const SERIES = [
    ["wpm", "wpm"],
    ["raw", "raw"],
    ["burst", "burst"],
    ["err", "errors"],
  ];
  let hovered = null;

  function readout(box, e) {
    const svg = box.querySelector("svg");
    const line = svg.querySelector("polyline.wpm").points;
    const n = line.numberOfItems;
    const m = svg.getScreenCTM();
    if (!m || n === 0) return;
    const x = (e.clientX - m.e) / m.a;
    const first = line.getItem(0).x;
    const span = line.getItem(n - 1).x - first;
    const i = n === 1 ? 0 : Math.max(0, Math.min(n - 1, Math.round(((x - first) / span) * (n - 1))));
    const at = line.getItem(i).x;
    const guide = svg.querySelector(".guide");
    guide.setAttribute("x1", at);
    guide.setAttribute("x2", at);
    for (const dot of svg.querySelectorAll(".dot")) {
      const s = dot.classList[1];
      dot.setAttribute("cx", at);
      dot.setAttribute("cy", svg.querySelector(`polyline.${s}`).points.getItem(i).y);
    }
    let html = `<b>${i + 1} s</b>`;
    for (const [key, label] of SERIES) {
      if (off.has(key)) continue;
      const v = Number((box.dataset[key] || "").split(",")[i] || 0);
      html += `<span><i class="swatch ${key}"></i>${label}<em>${v}</em></span>`;
    }
    const tip = box.querySelector(".tip");
    tip.innerHTML = html;
    const left = m.a * at + m.e - box.getBoundingClientRect().left;
    const w = tip.offsetWidth;
    tip.style.transform = `translateX(${left + 16 + w > box.clientWidth ? left - 16 - w : left + 16}px)`;
    box.classList.add("hovering");
    hovered = box;
  }

  function leave() {
    hovered?.classList.remove("hovering");
    hovered = null;
  }

  for (const type of ["pointermove", "pointerdown"]) {
    document.addEventListener(type, (e) => {
      const box = e.target.closest?.(".chart-box");
      if (box && !e.target.closest(".legend")) readout(box, e);
      else if (hovered) leave();
    });
  }
  document.addEventListener("pointerout", (e) => {
    if (!e.relatedTarget) leave();
  });
})();
