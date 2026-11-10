// Check the painted canvas, not just the hidden text used by screen readers.
// TEST_BROWSER=webkit BROWSER_WS_ENDPOINT=ws://127.0.0.1:43223/ runs against
// a matching Playwright container when the host lacks WebKit's libraries.
const assert = require('node:assert/strict');
const { mkdtempSync, mkdirSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { once } = require('node:events');
const { start } = require('./charts.cjs');
const name = process.env.TEST_BROWSER || 'chromium';
const browserType = require('playwright')[name];

async function painted(page) {
  await page.waitForFunction(() => document.getElementById('words-text')?.textContent.length > 0);
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const pixels = await page.locator('#words').evaluate(canvas => {
    const probe = document.createElement('canvas').getContext('2d');
    probe.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
    probe.fillRect(0, 0, 1, 1);
    const expected = [...probe.getImageData(0, 0, 1, 1).data];
    const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
    let ink = 0;
    for (let i = 0; i < data.length; i += 4) {
      if (Math.abs(data[i] - expected[0]) + Math.abs(data[i + 1] - expected[1]) + Math.abs(data[i + 2] - expected[2]) > 40) ink++;
    }
    return { background: [...data.slice(0, 4)], expected, ink };
  });
  assert.deepEqual(pixels.background, pixels.expected, 'canvas background must match the theme');
  assert(pixels.ink > 100, 'the canvas must contain visible word glyphs');
}

async function run() {
  const project = path.resolve(__dirname, '..');
  const data = mkdtempSync(path.join(tmpdir(), 'typer-canvas-'));
  const probe = net.createServer().listen(0, '127.0.0.1'); await once(probe, 'listening');
  const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
  const { server, base } = await start(process.env.TYPER_BINARY || path.join(project, 'build/typer'), path.join(project, 'build/packs'), data, port);
  let browser;
  try {
    browser = process.env.BROWSER_WS_ENDPOINT ? await browserType.connect(process.env.BROWSER_WS_ENDPOINT) : await browserType.launch({ headless: true });
    for (const colorScheme of ['light', 'dark']) {
      const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, colorScheme, isMobile: true, hasTouch: true });
      try {
        const page = await context.newPage();
        const errors = []; page.on('pageerror', error => errors.push(error.message));
        await page.goto(base + '/?mode=words&n=10');
        await painted(page);
        if (process.env.CANVAS_ARTIFACTS) {
          mkdirSync(process.env.CANVAS_ARTIFACTS, { recursive: true });
          await page.screenshot({ path: path.join(process.env.CANVAS_ARTIFACTS, `${name}-${colorScheme}.png`) });
        }
        for (const viewport of [{ width: 390, height: 500 }, { width: 844, height: 390 }, { width: 390, height: 844 }]) {
          await page.setViewportSize(viewport);
          await painted(page);
        }
        await page.locator('[data-theme-toggle]').tap(); await painted(page);
        await page.locator('[data-theme-toggle]').tap(); await painted(page);
        await page.locator('header nav a[href="/history"]').tap(); await page.waitForURL(base + '/history');
        await page.locator('header nav a[href="/"]').tap(); await page.waitForURL(base + '/');
        await painted(page);
        await page.reload(); await painted(page);
        const words = await page.locator('#words-text').textContent();
        await page.locator('#stage').tap();
        const saved = page.waitForResponse(response => response.url() === base + '/results' && response.request().method() === 'POST');
        // Mobile keyboards use the input pipeline instead of physical key codes.
        for (const character of words) {
          await page.keyboard.insertText(character);
          await new Promise(resolve => setTimeout(resolve, 45));
        }
        assert.equal((await saved).status(), 201);
        await page.locator('[data-result-link]:visible').waitFor();
        assert.equal(await page.locator('#result .invalid').count(), 0);
        await page.locator('[data-next]').tap(); await painted(page);
        assert.deepEqual(errors, []);
        console.log(`${name} ${colorScheme}: painted glyphs, resize, theme changes, navigation, reload, mobile input, saved result and restart passed`);
      } finally { await context.close(); }
    }
  } finally {
    if (browser) await browser.close();
    const exited = once(server, 'exit'); server.kill('SIGTERM'); await exited;
    rmSync(data, { recursive: true, force: true });
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
