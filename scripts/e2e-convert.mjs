/**
 * End-to-end check without a browser:
 * convert real DOCX files with Pyodide, unpack the ZIP and compile it with LuaLaTeX.
 * It also compiles the same generated document with the unmodified docxlike runtime
 * and asserts that comment stripping changed no painted geometry.
 */
import { execFileSync } from "node:child_process";
import { cp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadPyodide } from "pyodide";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const build = join(root, "build", "e2e");
const nativePython = "/Users/wujunhao/latex-docxlike/build/native-table-cross-engine-v1/python/bin/python";
const docxlike = "/Users/wujunhao/latex-docxlike";

const samples = [
  [
    "cjk-runs",
    join(docxlike, "build/autonomous-five-hour-v1/font-inputs-v1/font-explicit-derived-zh-12-15.docx"),
  ],
  [
    "floating-picture",
    join(docxlike, "build/multilingual-validation-v24/build/multilingual-targeted/floating/inputs/word-float-11-top-bottom.docx"),
  ],
  ["real-document", "/Users/wujunhao/emt-fpe/emt/实验设计与思考.docx"],
  [
    "real-table",
    "/Users/wujunhao/emt-fpe/emt/A Graph Neural Network and Probabilistic Framework for Modeling EMT Dynamics in Single.docx",
  ],
  ["real-step", "/Users/wujunhao/emt-fpe/emt/步骤1.docx"],
  ["real-fp-pre", "/Users/wujunhao/emt-fpe/emt/Fp-pre.docx"],
];

const pyodide = await loadPyodide({ indexURL: join(root, "node_modules", "pyodide") + "/" });
pyodide.FS.mkdirTree("/assets");
for (const name of [
  "docx2docxlike.py",
  "web_convert.py",
  "font-map-system.json",
  "font-map-texlive.json",
  "docxlike.sty",
  "docxlike.lua",
]) {
  pyodide.FS.writeFile(`/assets/${name}`, await readFile(join(root, "public", "assets", name)));
}
await pyodide.runPythonAsync(await readFile(join(root, "public", "assets", "web_convert.py"), "utf8"));

await rm(build, { recursive: true, force: true });
await mkdir(build, { recursive: true });

for (const [name, source] of samples) {
  try {
    await stat(source);
  } catch {
    console.warn(`SKIP ${name}: ${source} not found`);
    continue;
  }
  const out = join(build, name);
  const unpacked = join(out, "unpacked");
  await mkdir(unpacked, { recursive: true });
  pyodide.FS.mkdirTree("/work");
  pyodide.FS.writeFile("/work/input.docx", await readFile(source));
  const raw = await pyodide.runPythonAsync(`
import json, shutil, pathlib
work = pathlib.Path('/work/out')
if work.exists():
    shutil.rmtree(work)
result = convert('/work/input.docx', '/work/out', '/assets/docx2docxlike.py', '/assets/font-map-texlive.json',
                 ['/assets/docxlike.sty', '/assets/docxlike.lua'])
zip_path = pathlib.Path('/work/result.zip')
if zip_path.exists():
    zip_path.unlink()
make_zip('/work/out', str(zip_path))
json.dumps(result, ensure_ascii=False)
`);
  const report = JSON.parse(raw);
  const zip = pyodide.FS.readFile("/work/result.zip");
  await writeFile(join(out, "result.zip"), zip);
  execFileSync("unzip", ["-q", "-o", join(out, "result.zip"), "-d", unpacked]);
  pyodide.runPython("import shutil; shutil.rmtree('/work', ignore_errors=True)");

  const main = unpacked;
  for (const iteration of [1, 2]) {
    execFileSync("lualatex", ["-interaction=nonstopmode", "-halt-on-error", "main.tex"], {
      cwd: main,
      stdio: "pipe",
      timeout: 180000,
    });
  }
  const pdf = await stat(join(main, "main.pdf"));
  if (["real-document", "real-table", "real-step", "real-fp-pre"].includes(name)) {
    const pages = Number(
      execFileSync(nativePython, ["-c", "import pymupdf,sys; print(len(pymupdf.open(sys.argv[1])))", join(main, "main.pdf")], {
        encoding: "utf8",
      }).trim(),
    );
    const app = execFileSync("unzip", ["-p", source, "docProps/app.xml"], { encoding: "utf8" });
    const expected = Number(/<Pages>(\d+)<\/Pages>/.exec(app)?.[1] || 0);
    if (!expected) throw new Error(`${name} has no Word page-count metadata`);
    if (pages !== expected) throw new Error(`real document page count ${pages} != Word ${expected}`);
    console.log(`PASS real document page count: ${pages} == Word ${expected}`);
  }
  console.log(
    `PASS ${name}: ${pdf.size} bytes PDF, ${report.report_total} report items, ` +
      `${report.media_files} media files, fonts=${report.fonts_used.join(", ") || "-"}`,
  );

  // Compare the distributed, comment-stripped runtime with the source runtime.
  const compare = join(out, "uncommented");
  await cp(main, compare, { recursive: true });
  for (const runtime of ["docxlike.sty", "docxlike.lua"]) {
    await cp(join(docxlike, runtime), join(compare, runtime));
  }
  execFileSync("rm", ["-f", "main.aux", "main.log", "main.fls"], { cwd: compare });
  for (const iteration of [1, 2]) {
    execFileSync("lualatex", ["-interaction=nonstopmode", "-halt-on-error", "main.tex"], {
      cwd: compare,
      stdio: "pipe",
      timeout: 180000,
    });
  }
  execFileSync(nativePython, [join(root, "scripts/compare-pdfs.py"), join(main, "main.pdf"), join(compare, "main.pdf")], {
    stdio: "pipe",
  });
  console.log(`PASS ${name}: comment-stripped runtime paints identically`);
}

// Original-font mode: keep Word family names and resolve installed fonts.
{
  const source = join(docxlike, "build/autonomous-five-hour-v1/font-inputs-v1/font-explicit-derived-zh-12-15.docx");
  const outDir = join(build, "system-fonts");
  const unpacked = join(outDir, "unpacked");
  await mkdir(unpacked, { recursive: true });
  pyodide.FS.mkdirTree("/work");
  pyodide.FS.writeFile("/work/input.docx", await readFile(source));
  const raw = await pyodide.runPythonAsync(`
import json, shutil, pathlib
work = pathlib.Path('/work/out')
if work.exists():
    shutil.rmtree(work)
result = convert('/work/input.docx', '/work/out', '/assets/docx2docxlike.py', '/assets/font-map-system.json',
                 ['/assets/docxlike.sty', '/assets/docxlike.lua'])
zip_path = pathlib.Path('/work/result.zip')
if zip_path.exists():
    zip_path.unlink()
make_zip('/work/out', str(zip_path))
json.dumps(result, ensure_ascii=False)
`);
  const report = JSON.parse(raw);
  if (report.font_mode !== "system") throw new Error(`expected system mode, got ${report.font_mode}`);
  await writeFile(join(outDir, "result.zip"), pyodide.FS.readFile("/work/result.zip"));
  execFileSync("unzip", ["-q", "-o", join(outDir, "result.zip"), "-d", unpacked]);
  pyodide.runPython("import shutil; shutil.rmtree('/work', ignore_errors=True)");
  const tex = await readFile(join(unpacked, "main.tex"), "utf8");
  if (!tex.includes("\\setmainfont{Times New Roman}[")) throw new Error("missing original Times New Roman");
  if (!tex.includes("\\setmainjfont{SimSun}[")) throw new Error("missing original SimSun");
  if (/texgyre|Fandol/.test(tex)) throw new Error("system mode still contains substitute fonts");
  for (const iteration of [1, 2]) {
    execFileSync("lualatex", ["-interaction=nonstopmode", "-halt-on-error", "main.tex"], {
      cwd: unpacked,
      stdio: "pipe",
      timeout: 180000,
      env: {
        ...process.env,
        OSFONTDIR: join(docxlike, "build", "multilingual", "fonts"),
      },
    });
  }
  const pdf = await stat(join(unpacked, "main.pdf"));
  console.log(`PASS system fonts: ${pdf.size} bytes PDF, original family names preserved`);
}
