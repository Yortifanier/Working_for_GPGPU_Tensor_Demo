# 构建与静态检查

这是执行级测试计划。Markdown、JSON 和 CSV 是可审查源文件；DOCX/PDF 是阅读版。
本目录不实现 runner、指令发生器、独立语义模型、adapter 或 SM RTL。
全部动态 case 和 planned run 保持 `NOT_RUN / BLOCKED_MISSING_IMPLEMENTATION`，动态 profile 保持关闭。
P0 只验证计划静态一致性，其 PASS 不证明任何 Generator/SM 测试已运行或产生覆盖。

从仓库根目录运行：

```bash
python3 verif/core/testplan/sm_instr_gen/check_testplan.py
python3 verif/core/testplan/sm_instr_gen/selftest_check_testplan.py
python3 verif/core/testplan/sm_instr_gen/build_doc.py --version 1.0 --date 2026-11-09 --render-check
```

上述命令是真实静态工具和文档构建命令。计划中的 suite 目前没有执行命令，不应把这些命令当成动态测试 runner。
检查器自检只在临时副本中注入 14 种错误元数据，并确认相应诊断；报告为 `reports/checker_selftest.json`，不计入 106 个动态 case 的执行。

## P0 检查范围

`check_testplan.py` 使用 `schemas/` 中的本地 JSON Schema，输出 `reports/testplan_static_check.json`，失败返回非零退出码。检查包括：

- 四份 `source_files` 引用的仓库相对路径、实际 SHA-256 和跨文件一致性；
- 106 个唯一 TC 与源 Vplan 的 106 个 SIG 精确对应，保留源标题、阶段、feature 和 coverage 关联；
- 参数、初始化、前置条件、至少 3 步、至少 2 个检查点、通过/失败条件和预期 artifacts；
- 全部 75 个源 CV；P1/P2 不得引用真实 DUT 覆盖，DUT 场景限 P3/P4；
- 8 个 profile 的阶段和 kind；只允许 P0 静态 profile 开启，7 个动态 profile 均关闭；
- 六类 suite 的精确 TC 名单、双向归属、预算和无隐式 profile override；
- 四类 timeout policy 与 case 阶段对应；
- `planned_runs.json` 对 suite 名单与 repetitions 的精确展开，以及输入 JSON 哈希；
- `run_matrix.csv` 列顺序、行顺序和全部单元格与 JSON 一致；
- 固定 seed 和所有 planned-run seed 唯一、未溢出且符合规定公式；
- 主文中完整 TC、source SIG、CV ID 集合，以及明确的 `NOT_RUN` 和实现门禁。

固定种子使用源 `testpoints` 数组的 **0-based** index：

```text
fixed_seed = 0x534D0000 + source_index
suiteIndex: SMOKE=0, DIRECTED=1, NEGATIVE=2, RANDOM=3, STRESS=4, REPLAY=5
seed = fixed_seed + suiteIndex * 0x100000 + repeat_index * 0x10000
```

不取模，不允许碰撞。`repeat_index` 从 0 开始；REPLAY suite 的两个基线 run 与 case 内对同一个 manifest 的真实重放是不同层次，内部重放不重新派生 seed。
预期 artifacts 是将来执行应产出的制品名，静态工具不要求这些制品当前存在，也不把声明等同于证据。
步骤和检查点为自然语言计划；schema 检查存在性与数量，不证明 oracle、活性或每条规则的语义正确。

## 阅读版

输出为 `SM_Instruction_Generator_Testplan_v1.0.docx` 和同名 PDF。
构建器通过私有模块实例复用 `verif/core/vplan/sm_instr_gen/build_doc.py` 与 `docs/sm/build_doc.py` 的排版函数，设置本计划专属封面、标题、页眉与元数据；不修改旧文档或其构建器。
两层依赖的 SHA-256 写入 QA。

表格使用原生 Word 表格，重复表头、行不拆分、段落左对齐；代码标识保留 DejaVu Sans Mono。HTML `<br>` 转为原生换行；公式保留原生 OMML。
106 个 case 的二列表使用 3.7cm 标签列和 13.3cm 内容列，保留 9pt 字号，避免长 TC 表头拆出单字。
构建核对表格、公式、导航、图片数量及图片身份，检查所有标题文本和全 PDF 文字页面边界。
`--render-check` 渲染封面、图页和末页供人工抽检；软件检查不等同于全页目检。
中间文件位于被忽略的 `build/sm_instr_gen_testplan/v1.0/`；最终小型 QA 在 `reports/document_qa.json` 和 `reports/document_qa_v1.0.json`，实际抽检范围单独记录。

需要 Python 3.10+、`jsonschema`、`python-docx`、`PyMuPDF`，以及 `pandoc`、`soffice`、`pdfinfo`、`pdftotext`、`pdftoppm`。
字体为 Noto Sans CJK SC、DejaVu Sans Mono。可用 `--soffice /absolute/path/to/soffice` 指定 LibreOffice；导出使用独立用户配置和新建输出目录。

## 两张流程图

```bash
python3 verif/core/testplan/sm_instr_gen/figures/generate_figures.py
```

重绘另需 `matplotlib`、`fontconfig` 和 Noto CJK。图源私有导入 `docs/sm/figures/generate_figures.py` 的辅助函数，只写本目录的两对 PNG/SVG。
PNG 为 2400 × 1608；SVG 字体转为 path。图描述计划责任链，不表示动态实现或执行已完成。重绘后须重建阅读版并刷新 QA。
