// Deliberately overlap real browser requests to check that the latest choice wins.
const assert = require('node:assert/strict');
const { mkdtempSync, readFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const net = require('node:net');
const browserType = require('playwright')[process.env.TEST_BROWSER || 'chromium'];
const { start } = require('./charts.cjs');

const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
async function run() {
  const project = path.resolve(__dirname, '..');
  const data = mkdtempSync(path.join(tmpdir(), 'typer-navigation-'));
  const probe = net.createServer().listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const { server, base } = await start(path.join(project, 'build/typer'), path.join(project, 'build/packs'), data, port);
  const browser = process.env.BROWSER_WS_ENDPOINT ? await browserType.connect(process.env.BROWSER_WS_ENDPOINT) : await browserType.launch({ headless: true });
  const failures = [];
  async function check(name, test) {
    const context = await browser.newContext();
    const release = deferred();
    try { await test(context, release); console.log(`PASS ${name}`); }
    catch (error) { failures.push(name); console.error(`FAIL ${name}: ${error.message}`); }
    finally { release.resolve(); await context.close(); }
  }
  try {
    await check('last settings change survives reordered request delivery', async (context, release) => {
      const first = deferred();
      let posts = 0;
      await context.route('**/settings', async route => {
        if (route.request().method() === 'POST' && ++posts === 1) { first.resolve(); await release.promise; }
        await route.continue();
      });
      const page = await context.newPage();
      await page.goto(base + '/settings');
      await page.locator('input[name="caret"][value="fast"]').check();
      await first.promise;
      await page.locator('input[name="caret"][value="slow"]').check();
      // The old implementation sends the second request immediately. Give it
      // time to overtake; the fixed implementation queues it behind the first.
      await page.waitForTimeout(250);
      const completed = page.waitForResponse(res => res.url() === base + '/settings' && res.request().method() === 'POST' && res.request().postData().includes('caret=fast'));
      release.resolve();
      await (await completed).finished();
      await page.waitForFunction(() => !document.querySelector('[data-saved]').hidden);
      await page.waitForTimeout(100);
      await page.reload();
      assert.equal(await page.locator('input[name="caret"][value="slow"]').isChecked(), true);
    });
    await check('cancelled language load cannot replace the current language', async (context, release) => {
      const started = deferred();
      const drained = deferred();
      await context.route('**/packs/japanese_hiragana.bin', async route => {
        started.resolve(); await release.promise; await route.continue(); drained.resolve();
      });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(base + '/languages?mode=words&n=10');
      await page.locator('a[href="/?mode=words&n=10&lang=japanese_hiragana"]').click();
      await started.promise;
      await page.locator('a[href="/?mode=words&n=10&lang=russian"]').click();
      await page.waitForURL(/lang=russian/);
      await page.waitForFunction(() => document.getElementById('words-text')?.textContent.length > 0);
      const loaded = page.waitForResponse('**/packs/japanese_hiragana.bin');
      release.resolve(); await drained.promise; await (await loaded).finished();
      await page.waitForTimeout(100);
      const before = await page.locator('#words-text').textContent();
      await page.keyboard.press('Tab');
      await page.waitForFunction(old => document.getElementById('words-text').textContent !== old, before);
      const words = await page.locator('#words-text').textContent();
      const bytes = readFileSync(path.join(project, 'build/packs/lang/russian.bin'));
      const count = bytes.readUInt32LE(8), at = (16 + bytes.readUInt32LE(12) + 3) & ~3;
      const blob = at + (count + 1) * 4;
      const allowed = new Set(Array.from({ length: count }, (_, i) => bytes.subarray(blob + bytes.readUInt32LE(at + i * 4), blob + bytes.readUInt32LE(at + (i + 1) * 4)).toString()));
      assert(words.trim().split(/\s+/).every(word => allowed.has(word)), 'text changed to the cancelled language');
      assert.deepEqual(errors, []);
    });
    await check('leaving an exhausted quote queue cancels its pending restart', async (context, release) => {
      const started = deferred();
      await context.route('**/quotes?**', async route => { started.resolve(); await release.promise; await route.continue(); });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(base + '/?mode=quote&q=1');
      await page.waitForFunction(() => document.getElementById('words-text')?.textContent.length > 0);
      for (let i = 1; i < 20; i++) {
        const before = await page.locator('#words-text').textContent();
        await page.keyboard.press('Tab');
        await page.waitForFunction(old => document.getElementById('words-text').textContent !== old, before);
      }
      await started.promise;
      await page.keyboard.press('Tab');
      await page.locator('a[href="/settings"]').click();
      await page.waitForURL(base + '/settings');
      const loaded = page.waitForResponse('**/quotes?**');
      release.resolve(); await (await loaded).finished();
      await page.waitForTimeout(100);
      assert.deepEqual(errors, []);
      assert.equal(await page.locator('main').getAttribute('data-page'), 'settings');
    });
    assert.deepEqual(failures, []);
  } finally {
    await browser.close();
    const exited = once(server, 'exit'); server.kill('SIGTERM'); await exited;
    rmSync(data, { recursive: true, force: true });
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
