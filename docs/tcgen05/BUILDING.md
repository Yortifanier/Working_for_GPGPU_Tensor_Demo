# 构建 tcgen05 架构文档

正文源文件为 `TCGEN05_TENSOR_ARCHITECTURE.md`。构建脚本独立生成 tcgen05 文档，不读取其他设计文档的封面、元数据、历史声明或测试结果。

在仓库根目录运行：

```bash
python3 docs/tcgen05/build_doc.py --date 2026-10-26 --render-check
```

产物为本目录下的 `TCGEN05_Tensor_Architecture_v1.0.docx` 和 `.pdf`。省略 `--date` 时，封面使用构建当日的 Asia/Shanghai 日期；固定该参数有助于保持显示日期一致，但外部工具仍可能写入生成时间，故不保证二进制完全相同。仅需 DOCX 时使用 `--docx-only`。

## 依赖

- Python 3.9+ 与 `python-docx`。
- Pandoc，支持 GFM、DOCX 和 Office Math 转换。
- LibreOffice headless：默认查找 `soffice`；本云环境也支持 `/opt/codex/runtimes/codex-primary-runtime/dependencies/bin/override/soffice`，或使用 `--soffice /path/to/soffice`。
- Noto Sans CJK SC、DejaVu Sans Mono、DejaVu Math TeX Gyre 字体。
- Poppler 的 `pdfinfo`、`pdftotext`；`--render-check` 还需要 `pdftoppm`。
- 可选 PyMuPDF：存在时额外核验 PDF 内部导航链接、五个独立图片对象及文本页面边界；缺少时 QA 会记录该项未运行。

脚本不安装工具或字体。缺少依赖会明确失败，不会把旧 PDF 当作新生成结果。LibreOffice 使用 `build/tcgen05/libreoffice-profile` 下的专用配置；缓存与中间文件也放在被忽略的 `build/tcgen05/`。

五张图的可编辑源生成器也随文档提供。需要更新图时，在仓库根运行 `python3 docs/tcgen05/figures/generate_figures.py`，依赖 matplotlib、fontconfig 和 Noto CJK 字体。它同时生成 PNG/SVG；SVG 的文字已转为路径，可在未安装原字体的阅读环境中保持外观。更新图后再运行本节文档构建命令。

## 正文约定与排版

- 首个一级标题作为封面标题，不在正文重复；正文其余章节自动规范为 Word Heading 1 起始，并生成可点击的阅读导航。
- 正文必须明确引用 `figures/` 下五张架构图，每张一次。SVG 引用在同名 PNG 存在时改用 PNG，保证 DOCX/PDF 的图像兼容性；脚本不会静默补图。
- 表格、超链接和公式由 Pandoc 原生转换。行内数学写 `$...$`，独立公式写 `$$...$$`；公式保留为 OMML，不以删反斜杠等方式转成伪公式。
- A4 竖版、左右各2 cm，图片最大宽17 cm；表格固定总宽17 cm，重复表头、行不拆页。中文使用 Noto Sans CJK SC；章节标题与后续内容保持在一起。
- 表格单行仍应控制长度。极长单元格无法在“不拆行”和“一页容纳”之间同时满足，需要编辑正文合理拆表，而不是继续缩小字体。

## 实际质量检查

`build/tcgen05/document_qa.json` 记录本次源文件和五张图的 SHA256、工具版本、DOCX/PDF SHA256、实际嵌图数量、原生表格/公式数量、导航数和 PDF 页数。开始构建先标记为未完成，成功后才写入 `passed=true`。构建会检查：

1. 正文正好引用五张指定图，DOCX 中实际嵌入五份媒体。
2. Markdown AST 与 DOCX 的原生 table / OMML 数量一致。
3. 源文、DOCX、PDF 文本无 Unicode replacement character，PDF 中能找到全部章节标题。
4. PDF 来自本次独立临时输出目录，导出失败不以旧文件充当成功。
5. 构建期间正文和图片未被改写，DOCX 中五张 PNG 的原始字节哈希与输入一致。

`--render-check` 会将封面、末页及可定位的五个图注所在页渲染为 PNG，路径记入 QA JSON，供实际目检。渲染本身不等于已人工确认排版。构建日志及大中间文件保留在 build，不进入文档目录。

本脚本不修改 Markdown 正文，不执行 Git add、commit 或 push，也不运行任何 RTL 验证流程。
