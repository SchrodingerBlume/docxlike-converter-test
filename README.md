# docxlike-web

浏览器内的 DOCX → docxlike LaTeX 转换器。文件在本地 WASM 沙箱中解析，不会上传。
转换结果是一个 ZIP：`main.tex`、图片目录，以及可与最新版 docxlike 配套使用的
`docxlike.sty` 和 `docxlike.lua`。

## 在线使用

<https://schrodingerblume.github.io/docxlike-converter-test/>

## 使用

1. 打开站点，拖入 `.docx`。
2. 点击“开始转换”。首次会加载约 12 MB 的 Pyodide（CPython/WASM）引擎。
3. 下载 ZIP，解压后上传到 Overleaf，把编译器设为 **LuaLaTeX**；或在本地运行
   `lualatex main.tex`。

ZIP 不附带字体。转换时把 Word 常用字体映射到 TeX Live 自带字体，因此在
Overleaf 和完整 TeX Live 安装上可直接编译：

| Word 字体 | 替代字体 |
| --- | --- |
| Times New Roman、Cambria | TeX Gyre Termes |
| Arial、Calibri、Segoe UI、Aptos | TeX Gyre Heros |
| Courier New、Consolas | TeX Gyre Cursor |
| 宋体、SimSun、NSimSun | FandolSong |
| 黑体、SimHei、微软雅黑、等线 | FandolHei |
| 楷体、KaiTi | FandolKai |
| 仿宋、FangSong | FandolFang |

替代字体与 Windows 原字体的字形细节不同；版式推进由 docxlike 的 Word 度量规则
处理，但这不是“嵌入原字体”的一比一复刻。

## 开发

```sh
npm install
npm run assets     # 从本地 docxlike 检出版本重新生成 public/assets
npm run dev
npm run build      # 输出 dist/，可直接静态托管
```

`npm run assets` 默认读取 `/Users/wujunhao/latex-docxlike`，可用
`python3 scripts/build-assets.py --docxlike <目录>` 指定其他最新源码。

### 目录

```text
index.html              页面
src/main.js             上传、进度、下载
src/style.css
public/worker.js        Pyodide 模块 worker
public/assets/          docx2docxlike.py、字体映射、去注释运行文件、转换胶水
public/pyodide/         Pyodide 运行时（npm install 后自动同步）
scripts/build-assets.py 生成发布资源，剥离 TeX/Lua 注释
scripts/e2e-convert.mjs Node 内跑完整转换、解压并用 LuaLaTeX 编译
scripts/browser-test.mjs 无头 Chromium 跑真实页面与下载
```

### 运行文件处理

`scripts/build-assets.py` 只保留三行署名/许可注释，其余 TeX 与 Lua 注释全部移除：

```text
docxlike — Word-compatible page, paragraph and line layout
Author: 吴俊豪 <andrew.junhao.wu@gmail.com>
License: LaTeX Project Public License 1.3c or later
```

Lua 注释由词法扫描移除，跳过短字符串、长字符串和长注释，避免误删
`--output-directory` 之类的字符串内容。TeX 注释按 TeX 的吞行规则删除，
不会在控制词和下一行之间插入空格。

保留许可行是因为 docxlike 以 LPPL 1.3c 发布；去掉许可与作者信息不符合其分发条件。

### 验证

```sh
npm test                 # 三份 DOCX：Pyodide 转换、ZIP 解压、LuaLaTeX 编译
                         # 并用未去注释运行文件重编同一文档，逐页比较文字轨迹和线框
npm run test:browser     # 无头 Chromium：真实页面加载、转换、下载 ZIP
```

已验证：

- CJK 字体/字号控制、含图片的浮动文档、真实 27 KB Word 文档均可转换并编译。
- 去注释运行文件与源运行文件绘制出的文字轨迹、规则线和页面尺寸逐页完全相同。
- 浏览器内的模块 worker 能加载本地 Pyodide、完成转换并生成可下载 ZIP。
- ZIP 只含 `main.tex`、`main-media/`（若有图片）、`docxlike.sty`、`docxlike.lua`。

## 限制

- **仅支持 `.docx`。** 旧版二进制 `.doc` 需要先在 Word 中另存为 `.docx`。
  浏览器内做 `.doc` 版式解析需要完整的办公套件 WASM 运行时，当前版本不包含。
- 转换器不能表达的对象（部分 VML 图形、主题色之外的复杂对象等）会在页面上的
  转换报告中列出，并以占位或降级方式保留版面。
- 不解析文档语义，不做论文结构识别；输出是通用 `article` 工程，而不是学校模板。
- 不保证逐字断行与 Word 完全一致；复杂中西文混排、字符缩放和临界换行仍可能有差异。
- 不支持旧版 Internet Explorer；需要支持 WebAssembly、模块 Worker 和现代 JavaScript 的浏览器。

## 许可

站点代码：按项目需要自行选择许可。docxlike 运行文件遵循 LPPL 1.3c 或更新版本，
作者吴俊豪。Pyodide 遵循 MPL-2.0。
