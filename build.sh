#!/usr/bin/env bash
# typer build: ./build.sh [upstream|pack|web|server] (default: server)
set -euo pipefail
cd "$(dirname "$0")"

UPSTREAM_COMMIT="$(cat upstream.commit)"
UPSTREAM="${UPSTREAM:-upstream}"
STATIC="$UPSTREAM/frontend/static"
OPT="${OPT:-speed}"
VET=(-vet -strict-style)
VERSION="$(git rev-parse --short=12 HEAD 2>/dev/null || echo dev)"

# Upstream Monkeytype is the data source for word lists and quotes, pinned to
# one commit.
upstream() {
  if [[ -d "$UPSTREAM/.git" ]]; then
    have="$(git -C "$UPSTREAM" rev-parse HEAD)"
    [[ "$have" == "$UPSTREAM_COMMIT"* ]] && return
    echo "upstream: $UPSTREAM is at $have, want $UPSTREAM_COMMIT" >&2
    exit 1
  fi
  git init -q "$UPSTREAM"
  git -C "$UPSTREAM" remote add origin https://github.com/monkeytypegame/monkeytype.git
  git -C "$UPSTREAM" fetch -q --depth 1 origin "$UPSTREAM_COMMIT"
  git -C "$UPSTREAM" checkout -q FETCH_HEAD
}

pack() {
  [[ -d "$STATIC/languages" ]] || upstream
  odin build tools/pack -out:build/pack -o:speed "${VET[@]}"
  ./build/pack "$STATIC" build/packs
}

# First 10 hex digits of the SHA-256, as the server names hashed assets.
hash10() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-10
}

web() {
  [[ -f build/packs/lang/english.bin ]] || pack
  mkdir -p build/web
  odin build src/island -target:freestanding_wasm32 -no-entry-point -o:size -source-code-locations:obfuscated "${VET[@]}" -out:build/web/core.wasm
  cp web/island.js web/theme.js build/web/
  css="$(cat web/app.css)"
  for font in web/fonts/*.woff2; do
    name="$(basename "$font")"
    css="${css//FONT:$name//assets/${name%%.*}.$(hash10 "$font").${name#*.}}"
  done
  printf '%s\n' "$css" > build/web/app.css
  for f in island.js theme.js app.css core.wasm; do
    brotli -q 11 -f -o "build/web/$f.br" "build/web/$f"
    gzip -9 -n -c "build/web/$f" > "build/web/$f.gz"
  done
}

server() {
  web
  odin build src/server -out:build/typer -o:"$OPT" "${VET[@]}" -define:TYPER_VERSION="$VERSION" ${TARGET:+-microarch:"$TARGET"}
}

case "${1:-server}" in
upstream) upstream ;;
pack) pack ;;
web) web ;;
server) server ;;
*)
  echo "usage: $0 [upstream|pack|web|server]" >&2
  exit 2
  ;;
esac
