// Real HTTP and browser regressions. Run after ./build.sh with Playwright on NODE_PATH.
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdtempSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { once } = require('node:events');
const { record } = require('./charts.cjs');
const { chromium } = require('playwright');

async function run() {
  const project = path.resolve(__dirname, '..');
  const data = mkdtempSync(path.join(tmpdir(), 'typer-reliability-'));
  const probe = net.createServer().listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const server = spawn(path.join(project, 'build/typer'), ['serve', data, '--listen', `127.0.0.1:${port}`, '--packs', path.join(project, 'build/packs'), '--origin', base]);
  let log = '';
  server.stdout.on('data', b => { log += b; });
  server.stderr.on('data', b => { log += b; });
  let browser;
  const failures = [];
  async function check(name, test) {
    try { await test(); console.log(`PASS ${name}`); }
    catch (error) { failures.push(name); console.error(`FAIL ${name}: ${error.message}`); }
  }
  const post = (body, cookie = '') => fetch(base + '/results', { method: 'POST', headers: { origin: base, cookie, 'content-type': 'application/octet-stream' }, body });
  try {
    for (let i = 0; i < 100; i++) {
      try { if ((await fetch(base + '/healthz')).ok) break; } catch {}
      if (server.exitCode !== null) throw new Error('Server exited');
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    await check('key links authenticate without logging credentials', async () => {
      const saved = await post(record(501));
      assert.equal(saved.status, 201);
      const cookie = saved.headers.get('set-cookie').split(';')[0];
      const token = cookie.split('=')[1];
      const claimed = await fetch(base + '/key/' + token, { redirect: 'manual' });
      assert.equal(claimed.status, 303);
      assert.equal(claimed.headers.get('set-cookie').split(';')[0], cookie);
      await fetch(base + '/healthz');
      await new Promise(resolve => setTimeout(resolve, 50));
      assert(!log.includes(token), 'request log exposed the key token');
    });
    await check('words tests cannot finish through a forged timeout', async () => {
      const forged = record(502);
      forged[8] = 1; // words mode; all 100 targets, only about 50 typed
      forged.writeUInt32LE(100, 12);
      assert.equal((await post(forged)).status, 400);
    });
    await check('normal timed results and duplicate retries still work', async () => {
      const body = record(503);
      const first = await post(body);
      assert.equal(first.status, 201);
      const retry = await post(body, first.headers.get('set-cookie').split(';')[0]);
      assert.equal(retry.status, 200);
      assert.equal(retry.headers.get('location'), first.headers.get('location'));
      assert.equal((await fetch(base + first.headers.get('location'))).status, 200);
    });
    browser = await chromium.launch({ headless: true });
    await check('offline finished test saves on reconnect without navigation', async () => {
      const context = await browser.newContext();
      try {
        const page = await context.newPage();
        await page.goto(base + '/?mode=words&n=10');
        await page.waitForFunction(() => document.getElementById('words-text')?.textContent.length > 0);
        const words = await page.locator('#words-text').textContent();
        await context.setOffline(true);
        await page.keyboard.type(words, { delay: 30 });
        await page.waitForFunction(() => JSON.parse(localStorage.getItem('typer:outbox') || '[]').length === 1);
        await context.setOffline(false);
        await page.waitForFunction(() => JSON.parse(localStorage.getItem('typer:outbox') || '[]').length === 0, null, { timeout: 8000 });
        await page.locator('[data-result-link]:visible').waitFor();
        await page.locator('[data-result-link]').click();
        await page.waitForURL(/\/results\/\d+$/);
      } finally { await context.close(); }
    });
    await check('outbox retries a temporary refusal on a non-test page', async () => {
      const context = await browser.newContext();
      try {
        await context.addInitScript(body => localStorage.setItem('typer:outbox', JSON.stringify([body])), record(504).toString('base64'));
        let requests = 0;
        await context.route('**/results', async route => {
          requests++;
          if (requests === 1) await route.fulfill({ status: 429, body: 'slow down' });
          else await route.continue();
        });
        const page = await context.newPage();
        await page.goto(base + '/history');
        await page.waitForFunction(() => JSON.parse(localStorage.getItem('typer:outbox') || '[]').length === 0, null, { timeout: 10000 });
        assert.equal(requests, 2);
      } finally { await context.close(); }
    });
    assert.deepEqual(failures, []);
  } finally {
    if (browser) await browser.close();
    const exited = once(server, 'exit');
    server.kill('SIGTERM');
    await exited;
    rmSync(data, { recursive: true, force: true });
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
