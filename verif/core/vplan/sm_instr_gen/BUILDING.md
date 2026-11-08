# 构建与静态检查

Markdown、JSON 和 CSV 是验证计划的可审查源文件。DOCX/PDF 是阅读版。
本目录不包含指令发生器、独立参考模型、adapter 或 SM DUT 的实现。
所有 106 个动态 testpoint 均为 `PLANNED / NOT_RUN`；P0 的计划静态检查通过不代表执行了这些测试，也不产生动态覆盖。

从仓库根目录运行：

```bash
python3 verif/core/vplan/sm_instr_gen/check_vplan.py
python3 verif/core/vplan/sm_instr_gen/build_doc.py --version 1.0 --date 2026-11-08 --render-check
```

静态检查生成 `reports/vplan_static_check.json`，有错误时返回非零退出码。检查范围为：

- 三份本地 JSON schema、五个阶段和 `PLANNED / NOT_RUN` 状态；
- 217 条指令说明/控制语法与 35 条特殊寄存器条目的源文件 SHA-256、节号、名称、页码和分类；
- 两对 trace CSV/JSON 的逐单元格一致性；
- feature、testpoint、coverage 的唯一 ID、双向关联、阶段与覆盖命名空间；
- P1/P2 只能引用 `GENERATOR` 覆盖；`DUT_SCENARIO` 只能由 P3/P4 的真实 adapter/DUT 事件采样；
- 主文中的全部 25 个 feature ID、106 个 test ID、75 个 coverage ID，以及源引用文件存在性。

通用 `path#anchor` 引用检查文件存在和非空锚点；trace 到 inventory 的 `#section` 另做精确比对。静态工具不证明每个自然语言检查条件正确，不执行 PTX 合法性判定或数值 oracle。

输出阅读版：

- `SM_Instruction_Generator_Vplan_v1.0.docx`
- `SM_Instruction_Generator_Vplan_v1.0.pdf`

构建器复用 `docs/sm/build_doc.py` 的字体、原生表格、公式和图片排版函数，通过独立模块实例设置本计划专属封面、页眉和元数据，不修改或生成 SM 架构文档。该模块的 SHA-256 写入构建 QA。
`<br>` 转为原生换行；表格段落左对齐，代码标识保留等宽字体。
构建器核对原生表格/公式/图片/导航数量、图片身份、全部标题文本和全 PDF 文字页面边界；`--render-check` 额外渲染封面、图页和末页供人工抽检。
中间文件位于被忽略的 `build/sm_instr_gen_vplan/v1.0/`。若主文、图片或共享排版依赖在构建期间变化，构建失败。

最终小型 QA 归档为 `reports/document_qa.json` 和 `reports/document_qa_v1.0.json`，记录实际人工抽检页；软件结构检查不等同于逐页目检。`reports/checker_selftest.json` 仅记录静态检查器对 8 种合成错误元数据的拒绝检查，不计入 106 个计划测试的执行。

## 依赖

需要 Python 3.10+、`jsonschema`、`python-docx`、`PyMuPDF`，以及 PATH 中的 `pandoc`、`soffice`、`pdfinfo`、`pdftotext`、`pdftoppm`。字体需要 Noto Sans CJK SC 和 DejaVu Sans Mono。
可用 `--soffice /absolute/path/to/soffice` 指定 LibreOffice；构建使用独立用户配置目录和新建导出目录。

重绘两张流程图另需 `matplotlib`、`fontconfig` 和 Noto CJK 字体：

```bash
python3 verif/core/vplan/sm_instr_gen/figures/generate_figures.py
```

图源复用 `docs/sm/figures/generate_figures.py` 的绘图辅助函数，只写本目录的两对 PNG/SVG。PNG 为 2400 × 1608；SVG 中字体转为 path 以便跨环境阅读。
重绘图片后须重新构建阅读版并更新 QA。图片描述计划责任链，不表示任何组件已经实现或测试已经运行。
