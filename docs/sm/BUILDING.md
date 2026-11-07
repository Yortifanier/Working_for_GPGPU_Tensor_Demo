# 构建 SM 架构设计文档

主文是 `SM_ARCHITECTURE.md`。中文标题为“SM架构设计”，英文为“Streaming Multiprocessor Architecture”。本目录只构建独立 SM 文档及图稿，不修改已有 tcgen05/MALU 文档或 RTL。

在仓库根运行：

```bash
python3 docs/sm/build_doc.py --version 1.0 --date 2026-11-07 --render-check
```

输出 `SM_Architecture_v1.0.docx` 与同名 PDF。`--version` 默认 `1.0`；日期省略时使用 Asia/Shanghai 当日日期，正式发布应显式给定日期。`--docx-only` 只生成 DOCX，`--soffice /path/to/soffice` 可指定 LibreOffice。外部工具的元数据可能随构建变化，固定日期不保证二进制逐字节可重复。

构建缓存、原生 AST、LibreOffice 专用 profile、导出日志、页面抽样图和软件 QA 位于忽略目录 `build/sm_architecture/v1.0/`。脚本不安装依赖，不运行 Git add、commit 或 push。

## 依赖与图稿

- Python 3.9+、python-docx、Pandoc、LibreOffice headless。
- Noto Sans CJK SC、DejaVu Sans Mono、DejaVu Math TeX Gyre 字体。
- Poppler 的 pdfinfo、pdftotext；`--render-check` 另用 pdftoppm。
- 可选 PyMuPDF，用于核对 PDF 内部链接、图片数量与文字页面边界；未安装时软件 QA 明示该项未运行。
- 图稿生成另需 matplotlib、fontconfig、Noto Sans CJK 字体。

七图重新生成命令：

```bash
python3 docs/sm/figures/generate_figures.py
```

可用 `--only 04_memory_hierarchy` 只重建指定图。PNG 为 2400×1608，用于 DOCX/PDF；SVG 文字已转路径并规范化行尾空白。图以白底、深蓝、青色和橙色区分职责，生成器检查框内文字是否溢出。17 cm 宽嵌图时最小源字号 13.5 pt 等效约 9 pt。

七张图的文件名与阅读顺序见 [figures/FIGURES.md](figures/FIGURES.md)。主文须显式引用每图各一次；构建器按清单检查，不补造缺失图，不将逻辑框数量解释成硬件数量。

## 排版与 QA

Pandoc 从 GFM 转换原生表格、链接和 OMML 公式，公式源使用 `$...$` 或 `$$...$$`。首个一级标题转为封面标题，正文章节编号由源文提供，不再次自动编号。采用 A4 竖版、中文字体、可点击章节导航、重复表头及表格行不拆页，图片宽度不超过 17 cm。极长表格行仍需编辑合理拆分，不能依靠持续缩小字号解决。

转换前核对七图清单，转换后核对原生表格/公式数量、嵌图字节与章节导航；正文、图源 PNG 和输出文件均记录 SHA256。正文或图片在构建期间变化会使检查失败。PDF 在新的临时导出目录生成，不能拿旧 PDF 代替新构建。软件 QA 写入 `build/sm_architecture/v1.0/document_qa.json`，只有完成检查才标 `passed=true`。

`--render-check` 渲染封面、末页和各图注所在页，供实际目检。它不自动证明全部页面可读，更不证明 PTX 全覆盖、RTL 正确性、NVIDIA 设备数值等价或端到端吞吐。交付时将软件结果和实际抽页目检范围归档为 `research/document_qa.json`，明确未检查的范围。

SM-ARCH-S0 项目边界为 `1 core = 1 SM`，sp 为其内部组织；每 SM 对应 1 个逻辑 Tensor endpoint，最多 64 个 warp、8 个 CTA，每 warp 32 个线程。每 SM 的 core 共享 SMEM 为 256 KiB，独立 TMEM 的配置上限为 288 KiB；RF 容量保留为参数。这些物理数量与组织属于项目方案，不是反推的 Rubin 实现事实。

MALU 仅做 dot。现有 MALU 数值核心与拟议 SM 的实现状态不同，构建与排版 QA 不能用来证明 SM RTL 已实现。PTX 语义、项目编译/lowering 合同、拟议 SM 与现有 RTL 实现状态须在主文分别标注。
