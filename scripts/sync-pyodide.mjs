import { copyFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const from = join(root, "node_modules", "pyodide");
const to = join(root, "public", "pyodide");
const files = [
  "pyodide.mjs",
  "pyodide.asm.mjs",
  "pyodide.asm.wasm",
  "python_stdlib.zip",
  "pyodide-lock.json",
];

await mkdir(to, { recursive: true });
for (const name of files) {
  await copyFile(join(from, name), join(to, name));
}
console.log(`Synced ${files.length} Pyodide files to public/pyodide`);
