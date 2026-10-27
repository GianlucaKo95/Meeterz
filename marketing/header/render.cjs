// Rendert das App-Store-Kopfbild (Universal 16:9, 5244 × 2950 px) für alle Sprachen nach out/<sprache>.png
// Aufruf: node marketing/header/render.cjs [sprache …]
const { chromium } = require("playwright");
const { readFileSync, mkdirSync } = require("node:fs");
const { pathToFileURL } = require("node:url");
const { join } = require("node:path");

(async () => {
const here = __dirname;
const texts = JSON.parse(readFileSync(join(here, "texts.json"), "utf8"));
const langs = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(texts);
const out = join(here, "out");
mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 2622, height: 1475 }, deviceScaleFactor: 2 });
for (const lang of langs) {
  await page.addInitScript(t => { window.TEXTS = t; }, texts[lang]);
  await page.goto(pathToFileURL(join(here, "header.html")).href);
  await page.evaluate(() => document.fonts.ready);
  // Lange Überschriften (es/pt) eine Stufe kleiner, damit sie in drei Zeilen passen
  await page.evaluate(() => {
    const h = document.getElementById("title");
    let size = 104;
    while (h.getBoundingClientRect().height > 330 && size > 76) { size -= 4; h.style.fontSize = size + "px"; }
  });
  await page.screenshot({ path: join(out, `${lang}.png`), omitBackground: false });
  console.log(lang, "fertig");
}
await browser.close();
})();
