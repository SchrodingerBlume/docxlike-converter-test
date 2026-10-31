"""Browser glue: run the upstream docx2docxlike converter inside Pyodide."""
from __future__ import annotations

import importlib.util
import json
import pathlib
import re
import shutil
import zipfile


def _load_converter(path: str):
    spec = importlib.util.spec_from_file_location("docx2docxlike", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("无法加载 docx2docxlike.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def convert(docx_path: str, out_dir: str, converter_path: str, font_map_path: str, runtime_paths: list[str]) -> dict:
    out = pathlib.Path(out_dir)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    media = out / "main-media"
    font_map = json.loads(pathlib.Path(font_map_path).read_text(encoding="utf-8"))
    system_fonts = bool(font_map.get("*", {}).get("system"))
    module = _load_converter(converter_path)
    converter = module.Converter(
        pathlib.Path(docx_path),
        font_map,
        media_dir=media,
        media_prefix="main-media/",
    )
    tex = converter.convert()
    (out / "main.tex").write_text(tex, encoding="utf-8")
    for runtime in runtime_paths:
        source = pathlib.Path(runtime)
        (out / source.name).write_bytes(source.read_bytes())
    used = sorted(
        {name.replace("~", " ") for name in re.findall(r"(?:latin-text-font|asian-text-font|complex-script-font)=([^,}\]\n]+)", tex)}
    )
    unmapped = [] if system_fonts else [name for name in used if name not in font_map]
    report = dict(converter.rep.items)
    return {
        "report": report,
        "report_total": sum(report.values()),
        "fonts_used": used,
        "font_mode": "system" if system_fonts else "texlive",
        "unmapped_fonts": unmapped,
        "tex_lines": tex.count("\n") + 1,
        "media_files": sum(1 for path in media.rglob("*") if path.is_file()) if media.exists() else 0,
    }


def make_zip(out_dir: str, zip_path: str, prefix: str = "") -> None:
    """Zip main.tex at the root so Overleaf's Upload Project finds it directly."""
    root = pathlib.Path(out_dir)
    base = prefix.strip("/")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                name = path.relative_to(root).as_posix()
                archive.write(path, f"{base}/{name}" if base else name)
