// The <{ ◐ }> switch: flips light/dark in place and remembers the choice in
// a cookie, so the server renders the right theme on the next page (no
// flash). Without JavaScript the same button posts to /theme.
(() => {
  "use strict";

  const root = document.documentElement;
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const channel = "BroadcastChannel" in window ? new BroadcastChannel("typer:theme") : null;
  const current = () => root.dataset.theme || (media.matches ? "dark" : "light");

  function apply(theme, announce) {
    root.dataset.theme = theme;
    document.cookie = `typer_theme=${theme}; Path=/; Max-Age=31536000; SameSite=Lax`;
    window.dispatchEvent(new CustomEvent("typer:theme"));
    if (announce && channel) channel.postMessage(theme);
  }

  document.addEventListener("click", (e) => {
    const button = e.target.closest("[data-theme-toggle]");
    if (!button) return;
    e.preventDefault();
    apply(current() === "dark" ? "light" : "dark", true);
    // Back to the test, so the next space types instead of flipping again.
    document.getElementById("typer-input")?.focus();
  });

  if (channel) channel.onmessage = (e) => apply(e.data, false);

  // Following the system: repaint the canvas when the system flips.
  media.addEventListener("change", () => {
    if (!root.dataset.theme) window.dispatchEvent(new CustomEvent("typer:theme"));
  });
})();
