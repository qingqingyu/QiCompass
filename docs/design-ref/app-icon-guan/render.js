// 用法：node render.js（在本目录外运行也可）。产出 png/{A,B,C}-{sc,tc}.png（1024×1024，不透明）。
// 依赖：环境预装的 Playwright（无新依赖）。
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const dir = __dirname, b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  for (const v of ['A', 'B', 'C']) for (const [g, tag] of [['观', 'sc'], ['觀', 'tc']]) {
    await p.goto('file://' + path.join(dir, 'icon.html') + `?v=${v}&g=${encodeURIComponent(g)}`);
    await p.evaluate(() => document.fonts.ready);
    await p.waitForTimeout(300);
    const ok = await p.evaluate(() => [...document.fonts].every(f => f.status !== 'error'));
    if (!ok) throw new Error('font failed to load for ' + v + g);
    await p.screenshot({ path: path.join(dir, 'png', `${v}-${tag}.png`), omitBackground: false });
  }
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
