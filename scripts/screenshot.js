#!/usr/bin/env node
// Usage: node scripts/screenshot.js <url> <css-selector> <output.png>

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const [url, selector, outFile] = process.argv.slice(2);

if (!url || !selector || !outFile) {
  console.error('Usage: node scripts/screenshot.js <url> <css-selector> <output.png>');
  process.exit(1);
}

fs.mkdirSync(path.dirname(outFile), { recursive: true });

// Use puppeteer from dev-ai's own node_modules
const DEV_AI_ROOT = path.resolve(__dirname, '..');
let usePuppeteer = false;
try {
  require.resolve(path.join(DEV_AI_ROOT, 'node_modules/puppeteer'));
  usePuppeteer = true;
} catch (_) {}

if (usePuppeteer) {
  const puppeteer = require(path.join(DEV_AI_ROOT, 'node_modules/puppeteer'));
  (async () => {
    const browser = await puppeteer.launch({ args: ['--no-sandbox'] });
    const page = await browser.newPage();
    await page.setViewport({ width: 1280, height: 900 });
    await page.goto(url, { waitUntil: 'networkidle2' });
    const el = await page.$(selector);
    if (!el) {
      console.error(`Selector not found: ${selector}`);
      await browser.close();
      process.exit(1);
    }
    await el.screenshot({ path: outFile });
    await browser.close();
    console.log(`Saved: ${outFile}`);
  })();
} else {
  // Fallback: full-page screenshot (no element clipping)
  console.warn('puppeteer not found — taking full-page screenshot. Run: npm install puppeteer');
  execSync(
    `google-chrome --headless --disable-gpu --screenshot="${outFile}" --window-size=1280,900 "${url}"`,
    { stdio: 'inherit' }
  );
  console.log(`Saved: ${outFile}`);
}
