const BASE = new URL("./", self.location.href);
let enginePromise = null;
let assetsPromise = null;

function post(type, payload = {}) {
  self.postMessage({ type, ...payload });
}

async function fetchBytes(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`无法加载 ${url}（HTTP ${response.status}）`);
  return new Uint8Array(await response.arrayBuffer());
}

async function getEngine() {
  if (!enginePromise) {
    post("stage", { stage: "engine" });
    enginePromise = (async () => {
      const { loadPyodide } = await import(/* @vite-ignore */ new URL("pyodide/pyodide.mjs", BASE).href);
      return loadPyodide({ indexURL: new URL("pyodide/", BASE).href });
    })().catch((error) => {
      enginePromise = null;
      throw error;
    });
  }
  return enginePromise;
}

async function loadAssets(pyodide) {
  if (assetsPromise) return assetsPromise;
  assetsPromise = (async () => {
    post("stage", { stage: "assets" });
    const names = [
      "docx2docxlike.py",
      "web_convert.py",
      "font-map-system.json",
      "font-map-texlive.json",
      "docxlike.sty",
      "docxlike.lua",
      "manifest.json",
    ];
    try {
      pyodide.FS.mkdirTree("/assets");
    } catch {}
    for (const name of names) {
      const bytes = await fetchBytes(new URL(`assets/${name}`, BASE).href);
      pyodide.FS.writeFile(`/assets/${name}`, bytes);
    }
    pyodide.runPython(new TextDecoder().decode(pyodide.FS.readFile("/assets/web_convert.py")));
    const manifest = JSON.parse(new TextDecoder().decode(pyodide.FS.readFile("/assets/manifest.json")));
    return manifest;
  })().catch((error) => {
    assetsPromise = null;
    throw error;
  });
  return assetsPromise;
}

async function convert(buffer, fileName, fontMode, profile = null) {
  const pyodide = await getEngine();
  const manifest = await loadAssets(pyodide);
  post("stage", { stage: "parse" });
  const fontMap = fontMode === "texlive" ? "/assets/font-map-texlive.json" : "/assets/font-map-system.json";
  const stem = fileName.replace(/\.[^.]+$/, "").replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_").slice(0, 80) || "document";
  const prefix = `${stem}-docxlike`;
  try {
    pyodide.FS.mkdirTree("/work");
  } catch {}
  pyodide.FS.writeFile("/work/input.docx", new Uint8Array(buffer));
  pyodide.globals.set("profile_json", JSON.stringify(profile || null));
  const raw = await pyodide.runPythonAsync(`
import json, shutil, pathlib
work = pathlib.Path('/work/out')
if work.exists():
    shutil.rmtree(work)
profile = json.loads(profile_json) if profile_json else None
result = convert('/work/input.docx', '/work/out', '/assets/docx2docxlike.py', '${fontMap}',
                 ['/assets/docxlike.sty', '/assets/docxlike.lua'], profile=profile)
json.dumps(result, ensure_ascii=False)
`);
  const report = JSON.parse(raw);
  post("stage", { stage: "package" });
  await pyodide.runPythonAsync(`
import pathlib
zip_path = pathlib.Path('/work/result.zip')
if zip_path.exists():
    zip_path.unlink()
make_zip('/work/out', str(zip_path))
`);
  const bytes = pyodide.FS.readFile("/work/result.zip");
  const copy = bytes.slice().buffer;
  pyodide.runPython(`
import shutil
shutil.rmtree('/work', ignore_errors=True)
`);
  post("done", {
    zip: copy,
    name: prefix + ".zip",
    report,
    manifest: { runtime_sha256: manifest.runtime_sha256, converter_sha256: manifest.converter_sha256 },
  });
}

self.onmessage = async (event) => {
  const { type, buffer, fileName, fontMode, profile } = event.data || {};
  if (type !== "convert") return;
  try {
    await convert(buffer, fileName, fontMode, profile);
  } catch (error) {
    const message = (error && (error.message || String(error))) || "转换失败";
    post("error", { message });
  }
};
