#!/usr/bin/env python3
"""Build the browser assets from the latest local docxlike checkout.

The runtime files are comment-stripped for distribution. TeX and Lua comment
removal is lexical, then verified separately by compiling representative
documents with both runtimes and comparing their PDF drawing/text streams.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

AUTHOR = "吴俊豪 <andrew.junhao.wu@gmail.com>"
DESCRIPTION = "docxlike — Word-compatible page, paragraph and line layout"
LICENSE = "LaTeX Project Public License 1.3c or later"

FONT_ALIASES = {
    "Times New Roman": "serif",
    "Times": "serif",
    "Cambria": "serif",
    "Georgia": "serif",
    "Arial": "sans",
    "Helvetica": "sans",
    "Calibri": "sans",
    "Segoe UI": "sans",
    "Verdana": "sans",
    "Tahoma": "sans",
    "Aptos": "sans",
    "Courier New": "mono",
    "Consolas": "mono",
    "Lucida Console": "mono",
    "SimSun": "song",
    "宋体": "song",
    "NSimSun": "song",
    "新宋体": "song",
    "MingLiU": "song",
    "PMingLiU": "song",
    "細明體": "song",
    "新細明體": "song",
    "SimHei": "hei",
    "黑体": "hei",
    "Microsoft YaHei": "hei",
    "微软雅黑": "hei",
    "Microsoft JhengHei": "hei",
    "微軟正黑體": "hei",
    "DengXian": "hei",
    "等线": "hei",
    "KaiTi": "kai",
    "楷体": "kai",
    "DFKai-SB": "kai",
    "標楷體": "kai",
    "FangSong": "fang",
    "仿宋": "fang",
}

FONT_FILES = {
    "serif": {
        "file": "texgyretermes-regular.otf",
        "bold": "texgyretermes-bold.otf",
        "italic": "texgyretermes-italic.otf",
        "bolditalic": "texgyretermes-bolditalic.otf",
    },
    "sans": {
        "file": "texgyreheros-regular.otf",
        "bold": "texgyreheros-bold.otf",
        "italic": "texgyreheros-italic.otf",
        "bolditalic": "texgyreheros-bolditalic.otf",
    },
    "mono": {
        "file": "texgyrecursor-regular.otf",
        "bold": "texgyrecursor-bold.otf",
        "italic": "texgyrecursor-italic.otf",
        "bolditalic": "texgyrecursor-bolditalic.otf",
    },
    "song": {"file": "FandolSong-Regular.otf", "bold": "FandolSong-Bold.otf"},
    "hei": {"file": "FandolHei-Regular.otf", "bold": "FandolHei-Bold.otf"},
    "kai": {"file": "FandolKai-Regular.otf"},
    "fang": {"file": "FandolFang-Regular.otf"},
}


def strip_tex(source: str) -> str:
    """Remove TeX comments while preserving tokenization.

    A percent sign starts a comment unless escaped. The rest of the line and the
    end-of-line character are removed together, exactly as TeX consumes them.
    """
    out = []
    i, n = 0, len(source)
    while i < n:
        ch = source[i]
        if ch == "\\":
            out.append(source[i : i + 2])
            i += 2
            continue
        if ch == "%":
            newline = source.find("\n", i)
            i = n if newline < 0 else newline + 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def strip_lua(source: str) -> str:
    """Remove Lua short/long comments without touching strings."""
    out = []
    i, n = 0, len(source)
    while i < n:
        ch = source[i]
        if ch in "\"'":
            quote = ch
            j = i + 1
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j] == quote:
                    j += 1
                    break
                if source[j] == "\n":
                    break
                j += 1
            out.append(source[i:j])
            i = j
            continue
        if ch == "-" and source.startswith("--", i):
            long = re.match(r"--\[(=*)\[", source[i:])
            if long:
                terminator = "]" + long.group(1) + "]"
                end = source.find(terminator, i + long.end())
                if end < 0:
                    i = n
                else:
                    i = end + len(terminator)
                continue
            newline = source.find("\n", i)
            i = n if newline < 0 else newline
            continue
        if ch == "[":
            long = re.match(r"\[(=*)\[", source[i:])
            if long:
                terminator = "]" + long.group(1) + "]"
                end = source.find(terminator, i + long.end())
                if end < 0:
                    out.append(source[i:])
                    i = n
                else:
                    end += len(terminator)
                    out.append(source[i:end])
                    i = end
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def texlive_font_map() -> dict:
    mapping = {}
    for name, alias in FONT_ALIASES.items():
        faces = FONT_FILES[alias]
        entry = {"file": faces["file"], "path": "", "asian": alias in ("song", "hei", "kai", "fang")}
        for key in ("bold", "italic", "bolditalic"):
            if key in faces:
                entry[key] = faces[key]
        mapping[name] = entry
    mapping["Cambria Math"] = {"file": "texgyretermes-math.otf", "path": "", "asian": False}
    return mapping


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docxlike", type=Path, default=Path("/Users/wujunhao/latex-docxlike"))
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "public/assets")
    args = parser.parse_args()
    source = args.docxlike.resolve()
    target = args.out.resolve()
    target.mkdir(parents=True, exist_ok=True)

    converter = source / "tools/docx2docxlike.py"
    sty = source / "docxlike.sty"
    lua = source / "docxlike.lua"
    for path in (converter, sty, lua):
        assert path.is_file(), path

    runtime_sty = (
        f"% {DESCRIPTION}\n% Author: {AUTHOR}\n% License: {LICENSE}\n" + strip_tex(sty.read_text(encoding="utf-8"))
    )
    runtime_lua = (
        f"-- {DESCRIPTION}\n-- Author: {AUTHOR}\n-- License: {LICENSE}\n" + strip_lua(lua.read_text(encoding="utf-8"))
    )
    (target / "docx2docxlike.py").write_bytes(converter.read_bytes())
    (target / "docxlike.sty").write_text(runtime_sty, encoding="utf-8")
    (target / "docxlike.lua").write_text(runtime_lua, encoding="utf-8")
    (target / "font-map-texlive.json").write_text(
        json.dumps(texlive_font_map(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (target / "font-map-system.json").write_text(
        json.dumps({"*": {"system": True}}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    manifest = {
        "docxlike": str(source),
        "runtime_sha256": {"docxlike.sty": sha256(sty), "docxlike.lua": sha256(lua)},
        "distributed_sha256": {
            "docxlike.sty": sha256(target / "docxlike.sty"),
            "docxlike.lua": sha256(target / "docxlike.lua"),
        },
        "converter_sha256": sha256(converter),
        "font_maps": {
            "system": "original Word family names (host fonts required)",
            "texlive": f"{len(texlive_font_map())} TeX Live substitute families",
        },
    }
    (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
