# 构建 tcgen05 Tensor 微架构文档

主文为 `TCGEN05_TENSOR_MICROARCHITECTURE.md`。本目录描述**项目拟议微架构及现有 RTL 的适配**；封面、图和正文区分现有实现与待实现部分，不把项目方案描述成已实施的 NVIDIA 微架构。

在仓库根运行：

```bash
python3 docs/tcgen05/microarchitecture/build_doc.py --version 1.1 --date 2026-10-27 --render-check
```

本目录生成 `TCGEN05_Tensor_Microarchitecture_v1.1.docx` 和同名 PDF，保留已发布的 v1.0 产物。`--version` 默认为 `1.1`，并用于输出文件名、封面、页脚和独立缓存目录。省略日期时使用当日 Asia/Shanghai 日期；`--docx-only` 可只生成 DOCX，`--soffice /path/to/soffice` 可指定 LibreOffice。固定日期不保证外部工具生成的二进制文件逐字节相同。

`--version 1.0` 仅用于显式重建历史五图版，须配合历史 Markdown 与对应历史图源；它会写同名 v1.0 输出，不能拿新增 SMEM 的六图主文冒充旧版。日常构建使用 v1.1，不覆盖历史产物。

生成器复用已验证的排版逻辑，但使用独立的标题、封面、元数据、书签前缀与输出路径，不修改上一级架构文档及其生成器。缓存、专用 LibreOffice profile、转换日志、原生 AST、页面抽检图片及 QA 按版本位于被忽略的 `build/tcgen05_microarchitecture/v1.1/`。

## 依赖与图源

- Python 3.9+、python-docx、Pandoc、LibreOffice headless。
- Noto Sans CJK SC、DejaVu Sans Mono 与 DejaVu Math TeX Gyre 字体。
- Poppler 的 pdfinfo、pdftotext；`--render-check` 还使用 pdftoppm。
- 可选 PyMuPDF，用于检查 PDF 导航、独立图像数量和文本边界；未安装时 QA 明示未运行该项。
- 六张逻辑微架构图的生成器位于 `figures/generate_figures.py`。运行 `python3 docs/tcgen05/microarchitecture/figures/generate_figures.py` 需要 matplotlib、fontconfig 与 Noto CJK。可用 `--only 06_smem_subsystem` 仅重建指定图。PNG 用于文档嵌图；SVG 文字转路径便于移植，并去除行尾空格。图源内容由对应主文确定，不由构建脚本补造。

脚本不安装依赖，不修改 RTL 或主文，不执行 Git add、commit 或 push。当前云环境可自动定位 `/opt/codex/runtimes/codex-primary-runtime/dependencies/bin/override/soffice`。

正文中的容量、砖数、局部数值界和理想 raw-product 预算可单独重算：

```bash
python3 docs/tcgen05/microarchitecture/check_design_budget.py
```

结果写入 `research/design_budget.json`。这项检查只验证项目预算的算术关系，不是 RTL 仿真、综合、时序或端到端吞吐验证。

## 排版与检查

正文首个一级标题用作封面标题；章节编号由源文提供，不由 Pandoc 再编号。原生表格、超链接、行内与独立公式由 Pandoc 转换；公式使用 `$...$`、`$$...$$` 并保留为 OMML。A4 竖版，中文字体、可点击导航、重复表头和行不拆页；图片宽度不超过17 cm。

v1.1 正文应明确引用本目录的六张指定图各一次（v1.0 为五张）。生成器按该版本所需图清单核对数量，不静默添加缺图，SVG 引用在同名 PNG 存在时使用 PNG。独立图片、表格、原生公式和导航数量会与 Markdown AST 核对；图像原始字节、正文和输出文件记录 SHA256。构建期间正文或图片发生变化会报错，需冻结后重建。

PDF 通过独立临时目录导出，不拿旧 PDF 冒充新结果。QA 位于 `build/tcgen05_microarchitecture/v1.1/document_qa.json`；只有完成检查才写 `passed=true`。`--render-check` 渲染封面、末页和各图注所在页，供实际目检；它不等于自动确认全部页面或技术结论。交付 QA 归档在 `research/document_qa_v1.1.json`，`research/document_qa.json` 指向最新记录；历史 v1.0 QA 单独保留。

大型表格应在源文合理拆分。极长表格单行若超过一页，不能仅靠“不拆行”设置解决；需要编辑结构而不是无限缩小文字。
