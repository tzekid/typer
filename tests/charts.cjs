// End-to-end chart checks against a real server and replayed typing records.
// Run after ./build.sh: NODE_PATH=/path/to/node_modules node tests/charts.cjs
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const net = require('node:net');
const browserName = process.env.CHART_BROWSER || 'chromium';
const browserType = require('playwright')[browserName];

function record(seed, count = 250) {
  const chunks = [];
  const u32 = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n); chunks.push(b); };
  chunks.push(Buffer.from('TYR1')); u32(1);
  chunks.push(Buffer.from([0, 0, 0, 0])); u32(30); u32(seed); u32(0);
  u32(7); chunks.push(Buffer.from('english'));
  const words = Array.from({ length: 100 }, (_, i) => ['the', 'quick', 'brown', 'fox', 'jumps', 'over', 'lazy', 'dog'][i % 8]);
  u32(words.length);
  for (const word of words) { u32(word.length); u32(32); chunks.push(Buffer.from(word)); }
  const text = words.join(' ') + ' ';
  const events = [...text.slice(0, count)].map((c, i) => [1000 + i * 29900 / count, 3, c.charCodeAt(0)]);
  events.push([31000, 6, 0], [31000, 7, 0]);
  u32(events.length);
  for (const [ms, kind, arg] of events) {
    const b = Buffer.alloc(16); b.writeDoubleLE(ms); b[8] = kind; b.writeInt32LE(arg, 12); chunks.push(b);
  }
  return Buffer.concat(chunks);
}

async function seed(base, data) {
  let cookie = '';
  const ids = [];
  for (let i = 0; i < 12; i++) {
    const res = await fetch(base + '/results', { method: 'POST', headers: { origin: base, cookie, 'content-type': 'application/octet-stream', 'x-forwarded-for': `fixture-${i}` }, body: record(i + 1, [260, 274, 235, 213, 250, 242, 263, 255, 247, 265, 251, 259][i]) });
    assert.equal(res.status, 201, await res.text());
    if (res.headers.has('set-cookie')) cookie = res.headers.get('set-cookie').split(';')[0];
    ids.push(Number(res.headers.get('location').split('/').pop()));
  }
  const db = new DatabaseSync(path.join(data, 'typer.sqlite'));
  const today = Math.floor(Date.now() / 86400000) * 86400000;
  // Several tests share a timestamp: pointer selection must also use height.
  for (let i = 0; i < ids.length; i++) db.prepare('UPDATE results SET created_at = ? WHERE id = ?').run(today - (i === 0 ? 21 : i === 11 ? 0 : 4) * 86400000 + 14 * 3600000, ids[i]);
  db.exec("UPDATE users SET name = 'Graph preview'");
  assert.equal(db.prepare('SELECT count(*) AS n FROM results WHERE valid = 1').get().n, ids.length);
  db.close();
  return { cookie, ids };
}

async function start(binary, packs, data, port) {
  const base = `http://127.0.0.1:${port}`;
  const server = spawn(binary, ['serve', data, '--listen', `127.0.0.1:${port}`, '--packs', packs, '--origin', base], { stdio: ['ignore', 'ignore', 'pipe'] });
  let log = '';
  server.stderr.on('data', b => { log += b; });
  for (let i = 0; i < 100; i++) {
    try { if ((await fetch(base + '/healthz')).ok) return { server, base }; } catch {}
    if (server.exitCode !== null) throw new Error(log);
    await new Promise(r => setTimeout(r, 50));
  }
  server.kill();
  throw new Error('Server did not listen: ' + log);
}

async function pointAt(page, point) {
  const pos = await point.evaluate(el => { const b = el.getBBox(); const p = new DOMPoint(b.x + b.width / 2, b.y + b.height / 2).matrixTransform(el.ownerSVGElement.getScreenCTM()); return { x: p.x, y: p.y }; });
  await page.mouse.move(pos.x, pos.y);
}

async function run() {
  const project = path.resolve(__dirname, '..');
  const data = mkdtempSync(path.join(tmpdir(), 'typer-charts-'));
  const output = process.env.CHART_ARTIFACTS || path.join(project, 'build/chart-checks');
  mkdirSync(output, { recursive: true });
  const port = await new Promise(resolve => {
    const probe = net.createServer();
    probe.listen(0, '127.0.0.1', () => { const selected = probe.address().port; probe.close(() => resolve(selected)); });
  });
  const { server, base } = await start(path.join(project, 'build/typer'), path.join(project, 'build/packs'), data, port);
  let browser;
  try {
    const fixture = await seed(base, data);
    for (const name of [browserName]) {
      browser = await browserType.launch({ headless: true });
      const context = await browser.newContext({ viewport: { width: 1280, height: 1000 }, colorScheme: 'dark' });
      await context.addCookies([{ name: 'typer_id', value: fixture.cookie.split('=')[1], url: base }]);
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', e => errors.push(e.message));
      await page.goto(base + '/history');
      await page.evaluate(() => document.fonts.ready);
      const history = page.locator('[data-chart="history"]');
      const svg = history.locator('svg:visible');
      const points = svg.locator('[data-chart-point]');
      const sameTime = points.filter({ has: page.locator('title') }); // native titles have been replaced
      assert.equal(await sameTime.count(), 0);
      for (const index of [0, 2, 3, 11]) {
        const point = points.nth(index);
        await pointAt(page, point);
        const expected = await point.getAttribute('data-wpm');
        await page.waitForFunction(value => document.querySelector('[data-chart="history"] .tip-value')?.textContent === value + 'wpm', expected);
        assert.match(await history.locator('.tip').innerText(), /Accuracy.*100.00%/s);
        assert.equal(await history.locator('.tip').getAttribute('aria-hidden'), 'false');
      }
      await pointAt(page, svg.locator('[data-best]').last());
      assert.match(await history.locator('.tip').innerText(), /New personal best/);
      const readout = await history.locator('.tip').innerText();
      await history.locator('.tip').hover();
      assert.equal(await history.locator('.tip').innerText(), readout);
      assert.equal(await history.locator('.tip').getAttribute('aria-hidden'), 'false');
      await history.screenshot({ path: path.join(output, `${name}-history-dark.png`) });
      await svg.focus();
      await page.keyboard.press('Home');
      assert.match(await history.locator('.tip').innerText(), /Average \(1 test\)/);
      await page.keyboard.press('End');
      assert.match(await history.locator('.tip').innerText(), /Average \(10 tests\)/);
      await page.keyboard.press('Escape');
      assert.equal(await history.locator('.tip').getAttribute('aria-hidden'), 'true');
      await page.keyboard.press('ArrowLeft');
      assert.equal(await history.locator('.tip').getAttribute('aria-hidden'), 'false');
      await page.keyboard.press('Enter');
      await page.waitForURL(/\/results\//);
      assert.equal(await page.locator('.chart-box svg').getAttribute('tabindex'), '0');
      await page.locator('.chart-box svg').focus();
      await page.keyboard.press('End');
      assert.match(await page.locator('.tip').innerText(), /Second 30/);
      for (const series of ['raw', 'burst', 'err']) await page.locator(`[data-series="${series}"]`).click();
      await page.locator('.chart-box svg').focus();
      await page.keyboard.press('Home');
      assert.doesNotMatch(await page.locator('.tip').innerText(), /raw|burst|errors/);
      // Exact-value tooltips must not widen a result page while hidden or
      // while reading a statistic at the right edge of a wrapped row.
      for (const width of [1440, 768, 600, 390, 320]) {
        await page.setViewportSize({ width, height: 1000 });
        await page.mouse.move(0, 0);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `hidden statistic tooltip at ${width}`);
        for (const metric of await page.locator('[data-tip]').all()) {
          await metric.hover();
          assert.equal(await metric.evaluate(el => getComputedStyle(el, '::after').display !== 'none'), true);
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `visible statistic tooltip at ${width}`);
        }
      }
      await page.setViewportSize({ width: 1280, height: 1000 });
      await page.goto(base + '/history');
      for (const chart of ['pace', 'calendar']) {
        const box = page.locator(`[data-chart="${chart}"]`);
        const plot = box.locator('svg:visible');
        await plot.scrollIntoViewIfNeeded();
        await plot.focus();
        await page.keyboard.press('End');
        assert.equal(await box.locator('.tip').getAttribute('aria-hidden'), 'false');
        assert.match(await box.locator('.tip').innerText(), chart === 'pace' ? /End.*wpm.*Accuracy/s : /UTC.*s/s);
        await box.screenshot({ path: path.join(output, `${name}-${chart}.png`) });
      }
      // Scroll and reflow beneath a stationary mouse must not dismiss a
      // keyboard readout through an unrelated pointerout event.
      for (const width of [1440, 1024, 768, 600, 390, 320]) {
        await page.setViewportSize({ width, height: 1000 });
        await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
        for (const chart of ['history', 'pace', 'calendar']) {
          const box = page.locator(`[data-chart="${chart}"]`);
          const plot = box.locator('svg:visible');
          await plot.scrollIntoViewIfNeeded();
          await plot.focus();
          await page.keyboard.press('Home');
          await page.evaluate(() => new Promise(requestAnimationFrame));
          assert.equal(await box.locator('.tip').getAttribute('aria-hidden'), 'false');
          await page.keyboard.press('Escape');
        }
      }
      // Resize the same page, including the SVG initially hidden on desktop.
      await page.setViewportSize({ width: 320, height: 750 });
      await history.scrollIntoViewIfNeeded();
      const phone = history.locator('svg:visible');
      await pointAt(page, phone.locator('[data-chart-point]').last());
      const bounds = await history.locator('.tip').boundingBox();
      assert(bounds.x >= 0 && bounds.x + bounds.width <= 320, JSON.stringify(bounds));
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await history.screenshot({ path: path.join(output, `${name}-history-phone.png`) });
      await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'reduce' });
      await phone.focus();
      await page.keyboard.press('Home');
      await history.screenshot({ path: path.join(output, `${name}-history-light.png`) });
      assert.deepEqual(errors, []);
      // In-place navigation initializes the new plots, just like a reload.
      await page.locator('header nav a[href="/"]').click();
      await page.waitForURL(base + '/');
      await page.locator('header nav a[href="/history"]').click();
      await page.waitForURL(base + '/history');
      assert.equal(await page.locator('.history-trajectory svg:visible').getAttribute('tabindex'), '0');

      // The wasm result is inserted after typing, without loading a new page.
      await page.goto(base + '/?mode=words&n=10');
      await page.waitForFunction(() => document.getElementById('words-text')?.textContent.length > 0);
      const words = await page.locator('#words-text').textContent();
      const saved = page.waitForResponse(res => res.url() === base + '/results' && res.request().method() === 'POST');
      await page.keyboard.type(words, { delay: 40 });
      assert.equal((await saved).status(), 201);
      const live = page.locator('#result svg');
      assert.equal(await live.getAttribute('tabindex'), '0');
      await live.focus();
      await page.keyboard.press('ArrowRight');
      assert.equal(await live.evaluate(el => el === document.activeElement), true);
      await page.keyboard.press('Escape');
      assert.equal(await page.locator('#result').isVisible(), true);
      assert.equal(await page.locator('#result .tip').getAttribute('aria-hidden'), 'true');
      assert.deepEqual(errors, []);
      await context.close();

      const touch = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, colorScheme: 'dark' });
      await touch.addCookies([{ name: 'typer_id', value: fixture.cookie.split('=')[1], url: base }]);
      const phonePage = await touch.newPage();
      await phonePage.goto(base + '/history');
      const touchSvg = phonePage.locator('.history-trajectory svg:visible');
      await touchSvg.scrollIntoViewIfNeeded();
      await touchSvg.locator('[data-best]').last().tap();
      assert.equal(phonePage.url(), base + '/history');
      assert.equal(await phonePage.locator('.history-trajectory .tip').getAttribute('aria-hidden'), 'false');
      await phonePage.screenshot({ path: path.join(output, `${name}-touch.png`) });
      await phonePage.locator('h1').tap();
      assert.equal(await phonePage.locator('.history-trajectory .tip').getAttribute('aria-hidden'), 'true');
      await touch.close();

      const plain = await browser.newContext({ javaScriptEnabled: false });
      await plain.addCookies([{ name: 'typer_id', value: fixture.cookie.split('=')[1], url: base }]);
      const plainPage = await plain.newPage();
      await plainPage.goto(base + '/history');
      assert((await plainPage.locator('.history-dots title').count()) > 0);
      assert.match(await plainPage.locator('.history-best-marks a').first().getAttribute('href'), /^\/results\/\d+$/);
      await plain.close();

      // A new typist has no chart, then a first result, then sampled history.
      const sparse = await browser.newContext();
      const sparsePage = await sparse.newPage();
      await sparsePage.goto(base + '/history');
      assert.equal(await sparsePage.locator('.chart-box').count(), 0);
      const first = await sparse.request.post(base + '/results', { headers: { origin: base, 'content-type': 'application/octet-stream', 'x-forwarded-for': 'sparse' }, data: record(1000, 240) });
      assert.equal(first.status(), 201);
      await sparsePage.reload();
      assert.equal(await sparsePage.locator('.history-trajectory').count(), 0);
      const firstId = Number(first.headers().location.split('/').pop());
      for (let i = 1; i < 246; i++) {
        const res = await sparse.request.post(base + '/results', { headers: { origin: base, 'content-type': 'application/octet-stream', 'x-forwarded-for': `dense-${i}` }, data: record(1000 + i, i === 244 ? 274 : 240 + i % 20) });
        assert.equal(res.status(), 201);
      }
      const db = new DatabaseSync(path.join(data, 'typer.sqlite'));
      db.prepare('UPDATE results SET created_at = ? + (id - ?) * 60000 WHERE id >= ?').run(Date.now() - 246 * 60000, firstId, firstId);
      db.close();
      await sparsePage.reload();
      const denseSvg = sparsePage.locator('.history-trajectory svg:visible');
      assert.equal(await denseSvg.locator('.history-dots circle').count(), 240);
      const best = denseSvg.locator('[data-best]').last();
      await pointAt(sparsePage, best);
      assert.match(await sparsePage.locator('.history-trajectory .tip').innerText(), /109.60.*New personal best/s);
      await sparsePage.setViewportSize({ width: 375, height: 812 });
      assert.equal(await sparsePage.locator('.history-trajectory svg:visible .history-dots circle').count(), 80);
      await sparsePage.locator('.history-trajectory svg:visible').focus();
      await sparsePage.keyboard.press('End');
      assert.match(await sparsePage.locator('.history-trajectory .tip').innerText(), /Average \(10 tests\)/);
      await sparse.close();
      await browser.close(); browser = null;
      console.log(`${name}: values, clustered tests, keyboard, series toggles, history plots, responsive resize, themes, navigation, wasm results, touch and no-script pages passed`);
    }
    writeFileSync(path.join(output, 'checks.txt'), `${browserName} end-to-end chart checks passed.\n`);
    console.log('Artifacts: ' + output);
  } finally {
    if (browser) await browser.close();
    server.kill('SIGTERM');
    await new Promise(r => server.once('exit', r));
    rmSync(data, { recursive: true, force: true });
  }
}

module.exports = { record, seed, start };
if (require.main === module) run().catch(e => { console.error(e); process.exitCode = 1; });
