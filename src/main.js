const $ = (id) => document.getElementById(id);
const dropzone = $("dropzone");
const fileInput = $("file");
const fileinfo = $("fileinfo");
const filename = $("filename");
const filesize = $("filesize");
const clearButton = $("clear");
const convertButton = $("convert");
const hint = $("hint");
const progress = $("progress");
const errorBox = $("error");
const result = $("result");
const summary = $("summary");
const download = $("download");
const unmapped = $("unmapped");
const fontmodeWarning = $("fontmode-warning");
const reportBox = $("report-box");
const reportList = $("report");
const runtimeHash = $("runtime-hash");

const MAX_BYTES = 100 * 1024 * 1024;
const worker = new Worker("worker.js", { type: "module" });
let currentFile = null;
let currentUrl = null;
let busy = false;

function formatBytes(value) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

function showError(message) {
  errorBox.textContent = message;
  errorBox.classList.remove("hidden");
}

function clearError() {
  errorBox.textContent = "";
  errorBox.classList.add("hidden");
}

function setFile(file) {
  clearError();
  result.classList.add("hidden");
  progress.classList.add("hidden");
  if (currentUrl) {
    URL.revokeObjectURL(currentUrl);
    currentUrl = null;
  }
  currentFile = null;
  convertButton.disabled = true;

  if (!file) {
    fileinfo.classList.add("hidden");
    return;
  }
  const extension = file.name.split(".").pop().toLowerCase();
  if (extension === "doc") {
    showError("旧版 .doc 是二进制格式，浏览器内暂不能直接转换。请在 Word 中“另存为” .docx 后再上传。");
    fileinfo.classList.add("hidden");
    return;
  }
  if (extension !== "docx") {
    showError("请选择 .docx 文件。");
    fileinfo.classList.add("hidden");
    return;
  }
  if (file.size > MAX_BYTES) {
    showError(`文件超过 ${formatBytes(MAX_BYTES)}，请拆分后再转换。`);
    fileinfo.classList.add("hidden");
    return;
  }
  currentFile = file;
  filename.textContent = file.name;
  filesize.textContent = formatBytes(file.size);
  fileinfo.classList.remove("hidden");
  convertButton.disabled = false;
  hint.textContent = "转换在本机完成，不会上传文件。";
}

async function readFile(file) {
  const buffer = await file.arrayBuffer();
  const magic = new Uint8Array(buffer.slice(0, 8));
  if (magic[0] === 0x50 && magic[1] === 0x4b) return buffer;
  if (magic[0] === 0xd0 && magic[1] === 0xcf && magic[2] === 0x11 && magic[3] === 0xe0) {
    throw new Error("这是旧版 .doc 文件。请在 Word 中另存为 .docx 后再上传。");
  }
  throw new Error("文件不是有效的 DOCX（未找到 ZIP 结构）。");
}

const stageLabels = { engine: 0, assets: 1, parse: 2, package: 3 };

function setStage(stage) {
  progress.classList.remove("hidden");
  const index = stageLabels[stage];
  [...progress.children].forEach((item, i) => {
    item.classList.toggle("done", i < index);
    item.classList.toggle("active", i === index);
  });
}

function showReport(report) {
  reportBox.classList.add("hidden");
  reportList.replaceChildren();
  const entries = Object.entries(report?.report || {});
  if (!entries.length) return;
  for (const [kind, count] of entries.sort((a, b) => b[1] - a[1])) {
    const item = document.createElement("li");
    item.textContent = `${kind} × ${count}`;
    reportList.append(item);
  }
  reportBox.classList.remove("hidden");
}

convertButton.addEventListener("click", async () => {
  if (!currentFile || busy) return;
  busy = true;
  clearError();
  result.classList.add("hidden");
  convertButton.disabled = true;
  clearButton.disabled = true;
  progress.classList.remove("hidden");
  [...progress.children].forEach((item) => item.classList.remove("done", "active"));
  setStage("engine");
  try {
    const buffer = await readFile(currentFile);
    const fontMode = document.querySelector('input[name="fontmode"]:checked')?.value || "system";
    worker.postMessage({ type: "convert", buffer, fileName: currentFile.name, fontMode }, [buffer]);
  } catch (error) {
    busy = false;
    convertButton.disabled = false;
    clearButton.disabled = false;
    progress.classList.add("hidden");
    showError(error.message || String(error));
  }
});

worker.addEventListener("message", (event) => {
  const data = event.data || {};
  if (data.type === "stage") {
    setStage(data.stage);
    return;
  }
  if (data.type === "error") {
    busy = false;
    convertButton.disabled = !currentFile;
    clearButton.disabled = false;
    progress.classList.add("hidden");
    showError(data.message);
    return;
  }
  if (data.type !== "done") return;

  busy = false;
  convertButton.disabled = !currentFile;
  clearButton.disabled = false;
  progress.classList.add("hidden");

  const report = data.report;
  const total = report.report_total || 0;
  const media = report.media_files || 0;
  const fonts = report.fonts_used?.length || 0;
  const modeLabel = report.font_mode === "texlive" ? "TeX Live 替代字体" : "Word 原字体";
  summary.textContent = `${modeLabel} · 提示 ${total} 项 · 图片 ${media} 个 · 使用字体 ${fonts} 种`;
  if (total === 0) summary.textContent += " · 无降级提示";

  if (report.font_mode === "system") {
    fontmodeWarning.textContent =
      "原字体模式要求编译环境已安装 Word 字体（如宋体、Times New Roman）。Overleaf 通常没有这些字体；" +
      "若要直接上传 Overleaf，请改用“TeX Live 替代字体”，或自行上传字体文件并修改 main.tex 中的字体路径。";
    fontmodeWarning.classList.remove("hidden");
  } else {
    fontmodeWarning.classList.add("hidden");
  }

  if (report.unmapped_fonts?.length) {
    unmapped.textContent =
      "以下字体没有可用的 TeX 替代文件，将回落到 docxlike 默认字体：" +
      report.unmapped_fonts.join("、");
    unmapped.classList.remove("hidden");
  } else {
    unmapped.classList.add("hidden");
  }

  showReport(report);
  if (data.manifest?.runtime_sha256) {
    runtimeHash.textContent = `· Lua ${data.manifest.runtime_sha256["docxlike.lua"].slice(0, 12)}`;
  }

  if (currentUrl) URL.revokeObjectURL(currentUrl);
  currentUrl = URL.createObjectURL(new Blob([data.zip], { type: "application/zip" }));
  download.href = currentUrl;
  download.download = data.name || "docxlike-output.zip";
  result.classList.remove("hidden");
  result.scrollIntoView({ behavior: "smooth", block: "nearest" });
});

worker.addEventListener("error", (event) => {
  busy = false;
  convertButton.disabled = !currentFile;
  clearButton.disabled = false;
  progress.classList.add("hidden");
  showError(event.message || "转换引擎加载失败。");
});

dropzone.addEventListener("click", () => fileInput.click());
dropzone.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    fileInput.click();
  }
});

fileInput.addEventListener("change", () => setFile(fileInput.files?.[0]));

for (const name of ["dragenter", "dragover"]) {
  dropzone.addEventListener(name, (event) => {
    event.preventDefault();
    dropzone.classList.add("dragover");
  });
}

for (const name of ["dragleave", "drop"]) {
  dropzone.addEventListener(name, (event) => {
    event.preventDefault();
    dropzone.classList.remove("dragover");
  });
}

dropzone.addEventListener("drop", (event) => {
  const file = event.dataTransfer?.files?.[0];
  if (file) setFile(file);
});

clearButton.addEventListener("click", () => {
  fileInput.value = "";
  setFile(null);
  hint.textContent = "首次转换需要加载约 12 MB 的转换引擎。";
});

fetch("assets/manifest.json")
  .then((response) => (response.ok ? response.json() : null))
  .then((manifest) => {
    if (manifest?.runtime_sha256?.["docxlike.lua"]) {
      runtimeHash.textContent = `· Lua ${manifest.runtime_sha256["docxlike.lua"].slice(0, 12)}`;
    }
  })
  .catch(() => {});
