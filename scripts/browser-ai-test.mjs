import http from "node:http";
import { execFileSync, spawn } from "node:child_process";
import { mkdir, readFile, rm, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const out = join(root, "build", "browser-ai");
const sample = "/Users/wujunhao/Desktop/第1章绪论.docx";
const executable = join(
  process.env.HOME,
  "Library/Caches/ms-playwright/chromium-1248/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
);
const port = 4176;
const apiPort = 4199;

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });

const mock = http.createServer((request, response) => {
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Headers", "authorization, content-type");
  if (request.method === "OPTIONS") {
    response.writeHead(204);
    response.end();
    return;
  }
  request.resume();
  request.on("end", () => {
    const content = JSON.stringify({ version: 1, style_aliases: { "heading 1": "heading 2" } });
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ choices: [{ message: { content } }] }));
  });
});
await new Promise((resolve) => mock.listen(apiPort, "127.0.0.1", resolve));

const server = spawn(process.execPath, [join(root, "node_modules/vite/bin/vite.js"), "preview", "--port", String(port), "--strictPort"], {
  cwd: root,
  stdio: "pipe",
});
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("vite preview did not start")), 15000);
  server.stdout.on("data", (chunk) => {
    if (String(chunk).includes(String(port))) {
      clearTimeout(timer);
      resolve();
    }
  });
});

const browser = await chromium.launch({ executablePath: executable, headless: true });
try {
  const page = await browser.newPage({ acceptDownloads: true });
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle" });
  await page.click("#ai-box summary");
  await page.check("#ai-enable");
  await page.check('input[name="fontmode"][value="texlive"]');
  await page.fill("#ai-base", `http://127.0.0.1:${apiPort}/v1`);
  await page.fill("#ai-model", "mock");
  await page.fill("#ai-key", "test");
  await page.setInputFiles("#file", sample);
  await page.click("#convert");
  await page.waitForSelector("#result:not(.hidden), #error:not(.hidden)", { timeout: 300000 });
  if (await page.isVisible("#error")) throw new Error(await page.textContent("#error"));
  await page.click("#ai-suggest");
  await page.waitForSelector("#ai-proposals:not(.hidden), #ai-status:has-text(\"失败\")", { timeout: 120000 });
  if (!(await page.isVisible("#ai-proposals"))) throw new Error(await page.textContent("#ai-status"));
  if (!String(await page.textContent("#ai-list")).includes("heading 1 → heading 2")) {
    throw new Error("AI aliases were not rendered");
  }
  await page.click("#ai-apply");
  await page.waitForSelector("#ai-proposals", { state: "hidden", timeout: 300000 });
  if (await page.isVisible("#error")) throw new Error(await page.textContent("#error"));
  const downloadPromise = page.waitForEvent("download");
  await page.click("#download");
  const download = await downloadPromise;
  const zip = join(out, download.suggestedFilename());
  await download.saveAs(zip);
  const tex = execFileSync("unzip", ["-p", zip, "main.tex"], { encoding: "utf8" });
  if (/\\docxformat\[[^\]]*style=heading 1[,}\]]/.test(tex)) throw new Error("AI alias was not applied to heading 1 references");
  if (!/\\docxformat\[[^\]]*style=heading 2[,}\]]/.test(tex)) throw new Error("AI alias target is missing");
  const unpacked = join(out, "unpacked");
  await mkdir(unpacked, { recursive: true });
  execFileSync("unzip", ["-q", "-o", zip, "-d", unpacked]);
  for (let iteration = 0; iteration < 2; iteration += 1) {
    execFileSync("lualatex", ["-interaction=nonstopmode", "-halt-on-error", "main.tex"], {
      cwd: unpacked,
      stdio: "pipe",
      timeout: 300000,
    });
  }
  if (!(await stat(join(unpacked, "main.pdf"))).size) throw new Error("AI profile ZIP did not compile");
  if (errors.length) throw new Error(`browser errors:\n${errors.join("\n")}`);
  console.log(`PASS AI style flow: ${(await stat(zip)).size} bytes ZIP, alias applied, LuaLaTeX compiled`);
} finally {
  await browser.close();
  server.kill();
  mock.close();
}
