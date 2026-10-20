# typer

A typing test with Monkeytype's rules, rebuilt in Odin as one server binary
plus one wasm typing surface. No npm, no framework, no accounts.

Live at <https://typer.plosca.ru>.

## What it does

- **Modes:**
  - time: 15, 30, 60 or 120 s;
  - words: 10, 25, 50 or 100;
  - quote: short, medium, long, thicc, or all.
- **Content:** punctuation and numbers options; 444 word lists and 15,828
  quotes, all taken from Monkeytype.
- **Quotes:** each browser gets its own shuffled queue, and no quote repeats
  until the pool runs out. Line breaks show as ↵ and are typed with Enter.
  When a quote contains tabs, Tab types them and Shift+Tab restarts.
- **Stats:** the same as Monkeytype's (wpm, raw, accuracy, consistency,
  character counts, the speed chart), and the same rules decide whether a
  result counts.
- **Typists:** your first finished test gives your browser a typist with a
  generated name. You can rename it on `/me`. The key link shown there moves
  the same typist to another device.
- **Leaderboard:** each typist's best valid result, per mode and language.
- **History:** your own results and personal bests.
- **Settings:** smooth caret off, fast, medium (default) or slow; light or
  dark theme (or follow the system), switched with the `<{ ◐ }>` button.

## How it works

- **Engine** (`src/engine`) is compiled into both the server and the
  island. It holds:
  - the test state machine;
  - word generation and quote packs;
  - the stats;
  - the result renderer (HTML and SVG);
  - the record format.
- **Island** (`src/island`, `wasm32-freestanding`) is the typing surface. It
  lays out the text and draws it on a canvas, so a keystroke repaints only
  the words that changed and the page never re-runs layout. The caret is a
  DOM element moved with a CSS transform, so its glide runs on the
  compositor. `web/island.js` is the glue: it forwards input events, runs the
  draw commands and handles the outbox.
- **Server** (`src/server`, native) is a single `core:nbio` event loop
  (io_uring on Linux, kqueue on macOS) on top of SQLite. It serves:
  - server-rendered pages;
  - precompressed, content-hashed assets (brotli and gzip);
  - the per-browser quote queue windows;
  - the result API.

Each result is stored as its record: the setup, the target text and every
keystroke the engine applied. The server replays each upload through the
same engine and ignores any numbers the client sends. For a quote result it
also checks that the text typed is that quote.

Results wait in a `localStorage` outbox until the server acknowledges them,
so a test finished while offline is uploaded later.

Identity is a random 256-bit token kept in an `HttpOnly`, `SameSite=Lax`
cookie. The server stores only its SHA-256. Every POST must come from the
site's own origin, and writes are rate-limited per client address.

## Build and run

Requirements:

- Odin at the version in `.odinversion`;
- clang and `wasm-ld` on PATH;
- `brotli`, `gzip` and the SQLite library.

```sh
./build.sh upstream  # Monkeytype checkout at upstream.commit (word lists, quotes)
./build.sh           # packs, web assets and core.wasm, then build/typer
build/typer serve /tmp/typer --packs build/packs   # http://127.0.0.1:9334
```

`build.sh pack` and `build.sh web` build the individual stages.

Other commands:

- `typer doctor <data dir>` checks the database.
- `typer claim <data dir> <name> [--origin https://host]` creates the typist
  `<name>` and gives it every result that has no typist yet: results from
  before typists existed, which are kept out of the leaderboard until
  claimed. It prints the new typist's key link, which you open once in your
  browser. It can run while the server is up.

## Deploy

`scripts/deploy.sh` must be run from a clean, committed tree on the server.
It:

1. builds an `x86-64-v3` binary;
2. installs an immutable release under `~/.local/opt/typer/releases/<rev>`;
3. switches the `current` link and restarts the `typer.service` user unit;
4. checks `/healthz` and the running executable, and rolls back to the
   previous release if either fails.

Database migrations run when the server starts.

First time only:

- copy `deploy/typer.service` to `~/.config/systemd/user/`;
- copy `deploy/typer.caddy` to `/etc/caddy/conf.d/`;
- reload Caddy.

## Credits and license

The test rules, the stats and all word lists and quotes come from
[Monkeytype](https://github.com/monkeytypegame/monkeytype) (GPL-3.0). typer
is therefore GPL-3.0 as well; see `LICENSE`.

The fonts are DM Mono and Quando, both under the SIL Open Font License; see
`web/fonts/`.
