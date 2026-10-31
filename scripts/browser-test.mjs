/**
 * Drive the built static site in headless Chromium: load Pyodide, convert a
 * DOCX and save the ZIP produced by the actual download button.
 */
import { spawn } from "node:child_process";
import { mkdir, rm, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const out = join(root, "build", "browser");
const sample = process.argv[2] || "/Users/wujunhao/emt-fpe/emt/实验设计与思考.docx";
const executable = join(
  process.env.HOME,
  "Library/Caches/ms-playwright/chromium-1248/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
);

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });

const port = 4173;
const server = spawn(process.execPath, [join(root, "node_modules/vite/bin/vite.js"), "preview", "--port", String(port), "--strictPort"], {
  cwd: root,
  stdio: "pipe",
});
await new Promise((resolveReady, reject) => {
  const timer = setTimeout(() => reject(new Error("vite preview did not start")), 15000);
  server.stdout.on("data", (chunk) => {
    const text = String(chunk);
    if (text.includes(String(port))) {
      clearTimeout(timer);
      resolveReady();
    }
  });
  server.stderr.on("data", (chunk) => process.stderr.write(chunk));
});

const browser = await chromium.launch({ executablePath: executable, headless: true });
try {
  const page = await browser.newPage({ acceptDownloads: true });
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  page.on("console", (message) => {
    console.log(`[console:${message.type()}]`, message.text());
    if (message.type() === "error") errors.push(message.text());
  });
  page.on("worker", (worker) => {
    console.log("[worker]", worker.url());
    worker.on("close", () => console.log("[worker closed]"));
  });
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle" });
  await page.setInputFiles("#file", sample);
  await page.click("#convert");
  await page.waitForSelector("#result:not(.hidden), #error:not(.hidden)", { timeout: 180000 });
  if (await page.isVisible("#error")) {
    throw new Error(`conversion failed: ${await page.textContent("#error")}`);
  }
  const summary = await page.textContent("#summary");
  const href = await page.getAttribute("#download", "href");
  if (!href?.startsWith("blob:")) throw new Error("download link missing");
  const downloadPromise = page.waitForEvent("download");
  await page.click("#download");
  const download = await downloadPromise;
  const zipPath = join(out, download.suggestedFilename());
  await download.saveAs(zipPath);
  const info = await stat(zipPath);
  if (info.size < 1000) throw new Error(`ZIP too small: ${info.size}`);
  if (errors.length) throw new Error(`browser errors:\n${errors.join("\n")}`);
  console.log(`PASS browser conversion: ${info.size} bytes, ${summary}`);
} finally {
  await browser.close();
  server.kill();
}
