// Rahmt die Rohaufnahmen der Screenshot-Fahrt: node render.cjs <rohordner> <zielordner>
// Rohordner: <größe>/<sprache>/NN-name.png (Artefakt „storeshots“) → Ziel: <größe>/<sprache>/<i>-<name>.png
const { chromium } = require("playwright");
const fs = require("node:fs"), path = require("node:path");
const { pathToFileURL } = require("node:url");
const [src, dst] = process.argv.slice(2);
const texts = JSON.parse(fs.readFileSync(path.join(__dirname, "texts.json"), "utf8"));
const SIZES = { pro: [402, 874], promax: [440, 956] };
(async () => {
  const browser = await chromium.launch();
  for (const size of fs.readdirSync(src).filter(s => SIZES[s])) {
    const [w, h] = SIZES[size];
    const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 3 });
    for (const lang of fs.readdirSync(path.join(src, size))) {
      const files = fs.readdirSync(path.join(src, size, lang));
      let i = 0;
      for (const name of texts.order) {
        const f = files.find(x => x.endsWith(`-${name}.png`));
        if (!f) { console.log(`fehlt: ${size}/${lang}/${name}`); continue; }
        i += 1;
        const shot = "data:image/png;base64," + fs.readFileSync(path.join(src, size, lang, f)).toString("base64");
        await page.addInitScript(([t, s]) => { window.TITLE = t; window.SHOT = s; }, [texts[lang][name], shot]);
        await page.goto(pathToFileURL(path.join(__dirname, "frame.html")).href);
        await page.evaluate(() => Promise.all([document.fonts.ready, new Promise(r => { const im = document.getElementById("shot"); im.complete ? r() : im.onload = r; })]));
        // Lange Überschriften auf höchstens drei Zeilen bringen
        await page.evaluate(() => { const h = document.getElementById("title"); let s = 9.4;
          while (h.getBoundingClientRect().height > window.innerHeight * 0.155 && s > 6) { s -= 0.3; h.style.fontSize = s + "vw"; } });
        const out = path.join(dst, size, lang); fs.mkdirSync(out, { recursive: true });
        await page.screenshot({ path: path.join(out, `${i}-${name}.png`) });
      }
      console.log(size, lang, "fertig");
    }
    await page.close();
  }
  await browser.close();
})();
