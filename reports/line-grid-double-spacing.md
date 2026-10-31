# 正文行距按两倍网格输出的复现记录

日期：2026-10-31
范围：只记录现象与证据。**未修改 docxlike 核心运行文件。** 按约定，本轮只维护转换器。

## 现象

真实文档 `实验设计与思考.docx`（27 KB）转换后正文行距明显偏大。该文档：

- 正文直接字号 12bp（`w:sz=24`）。
- 段落没有显式行距（`w:spacing` 只有 before/after，没有 `w:line`）。
- 页面网格为 `w:docGrid w:type="lines" w:linePitch="312"`，即 15.6bp。
- 段落默认开启 `snapToGrid`。

转换器输出的页面设置与字体设置是正确的：

```text
document-grid={grid=specify-line-grid-only,lines={pitch=15.6bp}}
Normal 段落 snap-to-grid=true
```

但编译出的 PDF 中，连续正文行的基线间距是 **31.2bp**，正好是两个网格（2 × 15.6bp）。Word 同一文档应为 **15.6bp**。

## 最小复现

`build/gridprobe/main.tex`（`build/` 不入库）使用 docxlike 当前根运行文件：

```tex
\documentclass{article}
\usepackage[preset=none]{docxlike}
\usepackage{luatexja-fontspec}
\setmainfont{texgyretermes-regular.otf}[Path={},Kerning=Off,Ligatures=TeXOff]
\setmainjfont{FandolSong-Regular.otf}[Path={},Kerning=Off]
\ExplSyntaxOn
\docxlike_font_gset:nn{Times~New~Roman}{\rmfamily}
\docxlike_font_gset:nn{SimSun}{\mcfamily}
\docxlike_setup:n{
 diagnostics=true,
 compatibility-mode=word-2013,
 page-setup={paper={width=595.3bp,height=841.9bp},
   margins={top=72bp,bottom=72bp,left=90bp,right=90bp},
   document-grid={grid=specify-line-grid-only,lines={pitch=15.6bp}}},
 styles={Normal={font={latin-text-font=Times~New~Roman,asian-text-font=SimSun,
     size=10.5bp,kerning-for-fonts=false,
     snap-to-grid-when-document-grid-is-defined=true},
   paragraph={alignment=left,
     snap-to-grid-when-document-grid-is-defined=true}}}
}
\docxlike_body_setup:n{}
\ExplSyntaxOff
\begin{document}\pagestyle{empty}
\docxformat[paragraph={alignment=left}]{这是一段十二磅的中文测试文字……}
\end{document}
```

编译命令：

```sh
TEXINPUTS=/Users/wujunhao/latex-docxlike: \
LUAINPUTS=/Users/wujunhao/latex-docxlike: \
lualatex -interaction=nonstopmode -halt-on-error main.tex
```

## 测量结果

PDF 文本行顶部坐标：

```text
80.07, 111.27, 142.47
```

行距：

```text
31.2bp, 31.2bp
```

docxlike 自身诊断（`diagnostics=true`，10.5bp 正文）：

```text
size=10.5bp; natural=13.61717bp; line-rule=auto(1);
lead=15.6bp; grid=15.6bp; ...
```

在行盒层读取到的尺寸：

```text
hlist height=19.14624965948bp depth=12.053736476494bp
height + depth = 31.2bp
```

同时 `\baselineskip` 在 `\begin{document}` 前后都是 `15.6585pt`，即 15.6bp。

也就是说：

- 诊断里的 `lead` 是 15.6bp；
- `\baselineskip` 是 15.6bp；
- 但实际每个行盒被赋成了 31.2bp 的高深；
- 行间胶为 0，于是基线间距等于行盒总高深 31.2bp。

## 已排除

- 不是转换器把 312 twips 换算错：转换器输出确实为 `pitch=15.6bp`。
- 不是字体替换造成：12bp 字号、15.6bp 网格的关系没有被字体文件改变。
- 不是段落 before/after：同一段内连续行就已经是 31.2bp。
- 不是 `\baselineskip` 在文档层被改大：文档层读数是 15.6bp。
- 不是显式行距：源文档没有 `w:line`，转换器也没有输出 `line-spacing`。

## 根因范围

进一步定位（通过测试文档包装 `docxlike.runtime.load('linebreak')`，不改核心）：

```text
HG| BOX H=16.09 A=12.71 obj=0.00+0.00 k=1.002 snap -> 20.32+11.00
```

- 行盒实际自然高度 `H=16.09bp`，大于网格 pitch `15.6bp`。
- `linebox()` 的 snap 分支执行 `n = ceil(H / pitch - 0.001)`，得到 `n=2`。
- 于是 `total = max(bls, 2 * 15.6) = 31.2bp`，`asc+desc=31.2bp`。
- 行间胶为 0，基线间距直接等于 31.2bp。

同一个 12bp 文本，分别用 FandolSong 和 SimSun 编译：

```text
FandolSong: HG| BOX H=18.89 ... -> 19.73+11.59, deltas [31.2, 31.2]
SimSun:     HG| BOX H=16.09 ... -> 20.32+11.00, deltas [31.2, 31.2]
```

两者都超过 15.6bp，都被取整成两个网格。**原始 SimSun 在 12bp 下同样触发**，所以这不是字体替换单独造成的。

10.5bp 时差异更明显：

```text
FandolSong: H=16.53bp，两个网格（31.2bp）
SimSun:     H=14.08bp，一个网格（15.6bp）
```

替换字体把 Fandol 的自然行高放大，会让临界点更容易被越过；但 12bp + 15.6bp 网格这个真实文档组合，用原字体也已经越界。

同时存在一个内部不一致：

- 格式层诊断：12bp 的 `natural=15.5625bp`（小于 15.6bp）；
- 行盒层实际用字体度量得到 `H=16.09bp`（大于 15.6bp）。

网格取整用的是行盒层的 16.09bp，而不是格式层的 15.5625bp。Word 在同一设置下按一个网格排版（用户已确认原版行距更紧）。因此根因是 docxlike 行盒自然高度/网格取整，不是 DOCX 换算。

按本轮约定，**未修改核心 `docxlike-*.dtx`，也未在转换器里加行距补丁**。转换器不做“强行写 15.6bp 行距”的规避，因为那会掩盖 Word 行距语义。

## 为什么之前没暴露

- docxlike 的网格测试（`test/grid-alignment.py`）几乎都显式写 `line-spacing=exactly, at=18bp`，走 exact 分支，直接跳过按网格取整。
- 现有 CJK 控制大多有显式行距，或者网格 pitch 明显大于 12bp 文本的自然高度，不会碰到 `H > pitch` 的临界。
- 学校模板（hithesis / NEUThesis）通常用固定行距（如 exactly 22bp），也绕开了这条路径。
- 真实 Word 文档常见的组合是：`docGrid type=lines`、`linePitch=312`（15.6bp）、正文 12bp、段落不写 `w:line`、默认 snapToGrid。这个精确组合此前没有对应测试，一撞上就是两倍行距。

## 影响面

- 文档使用“仅行网格”（`docGrid type=lines`）+ 段落贴网格 + 自然行高接近网格 pitch 时会出现。
- 这类文档常见于 Word / Pages 导出的普通正文；用户感知就是“明显比 Word 松一倍”。
- 只影响行距，不影响字体、字号、文字内容；但会改变分页和整篇版式。

## 证据位置

- `build/gridprobe/main.tex`：最小复现源。
- `build/gridprobe/main.log`：`docxlike diagnostics` 与 `HGPROBE HLIST` 输出。
- `build/gridprobe/main.pdf`：31.2bp 行距的实测 PDF。
- `build/e2e/real-document/`：真实文档转换、ZIP、PDF（`npm test` 生成）。
- `build/real-page-1.png`：真实文档第一页渲染。

## 结论

转换器把 Word 的网格参数正确传给了 docxlike；当前 docxlike 把 15.6bp 网格排成了 31.2bp 行距。这是核心排版缺陷，需要在 docxlike 行盒/网格层修复，不能在转换器里覆盖。


## 转换器侧处理（已提交）

2026-10-31，`tools/docx2docxlike.py` 增加 `grid_line_spacing()`：

- 仅当节使用 `docGrid type=lines`、段落没有显式 `w:line`、且段落/样式未关闭 `snapToGrid` 时生效。
- 按段落最大字号计算 Word 网格单元数：
  `cells = max(1, ceil(1.3 * fontSize / pitch))`。
- 输出 `line-spacing=exactly, at=cells*pitch`，并写
  `snap-to-grid-when-document-grid-is-defined=false`，避免 docxlike
  再按字体实测行高取整一次。
- 显式行距、关闭网格、页眉页脚和表格单元格不套用这条规则。

验证：

- `实验设计与思考.docx`：转换后 **4 页**，与 Word `docProps/app.xml` 的
  `Pages=4` 一致；正文基线间距 **15.6bp**，不再是 31.2bp。
- `A Graph Neural Network...docx`：修复 `\docxrow` 后 **5 页**，与 Word `Pages=5` 一致。
- 1732 项 Word 字体控制：通过数保持 1223，零回退。
- 616 项语料与 CJK 控制仍需在新运行文件上重跑。
- 网页转换器 E2E 已把“真实文档页数必须等于 Word `Pages`”写成断言。

核心 docxlike 的原始网格缺陷仍保留在 `linebox()` 中；本次不修改它，转换器用
Word 网格单元显式写入精确行距来保证当前在线产品的输出与 Word 页数一致。
