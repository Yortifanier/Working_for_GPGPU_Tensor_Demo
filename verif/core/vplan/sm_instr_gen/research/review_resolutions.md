# SM指令发生器vPlan审查闭合

日期：2026-11-08（Asia/Shanghai）。范围是验证计划、追踪数据与阅读版，不是发生器/SM RTL功能验收。

## 冻结基线

| 产物 | SHA-256 |
|---|---|
| SM_INSTR_GEN_VPLAN.md | 71cd695ebdfbba906d17233c975762cec863187d2e4e96afc723a5d4e40915c9 |
| vplan_features.json | 8ee62fb376abac123d8704fad8d12c03b681e5736890373436b29a585f67a17d |
| testpoints.json | 9a230465115ed9e01b8edf64da32aba41af7a2da80b12275e28a8894792018c3 |

25个feature、106个计划testpoint、75个CV；50/27/23/6个case分别属于P1/P2/P3/P4。所有case为PLANNED/NOT_RUN。P0静态检查与checker自身负向校验使用单独报告，动态testpoint执行数为0。

## 第一轮：规范与数据追踪

固定PTX9.4源清单的217条指令/语法说明和35节特殊寄存器在CSV/JSON逐值回读中一致，共252个唯一源节。215实际指令说明与2控制语法分开；第11章34directive不计opcode。源hash、完整标题、页码、domain与primary/related feature引用分别检查。

发现并修复初始共享模板过宽：8个warp矩阵说明节和2个WGMMA计算说明节误关联GEN-TMEM-01。修正后该feature仅关联tcgen05本身12个说明节/14个标题名称；旧矩阵前端仍保留GEN-MATRIX及合法参与/async关联。

## 第二轮：方法与有状态资源

| 问题 | 修正与证据位置 |
|---|---|
| unspecified被一概归UB | §5只隔离原文明示UB；另立SPEC_UNDERSPECIFIED/ALLOWED_SET，有profile/关系可检，oracle未闭合为BLOCKED |
| race-free被写为结果唯一 | §9/15、SIG-MEM-003及GEN-MEM同步改为允许集合已证明单例才逐值，其余并发atomic/litmus按allowed-outcome或线性化关系 |
| Fabric期望登记时序含糊 | SIG-FABRIC-002、GEN-FABRIC及§10改原子arrive.expect_tx，或先expect且保留arrival；覆盖complete早/晚到防phase提前结束 |
| source hazard冒充DUT hazard | §7保留source→lowered/native→动态实例provenance，仅实际形成的依赖计DUT覆盖；CC/clobber按ABI |
| P1合成日志可能混入执行计数 | SIG-COV-001标SYNTHETIC，只测聚合器，不填真实DUT/run计数 |
| LEGALIZED阶段不能采reject bins | 25个第二CV改GENERATOR/CHECKED，独立audit完成后分类；保留accept/reject decision counters，明确不是DUT CHECKED |
| CTA group随机跨kernel切换 | §12要求同kernel带cta_group的相关tcgen05操作保持规范一致性 |

独立方法审查已复读最终主文和两个catalogue的增量；资源审查确认planned/issued/observed、CFG merge、typed units、TMEM/permit/group2、Cshift/rawTi16、cleanup及coverage scope范围内无剩余确定阻断。审查范围/读入快照在各自review中保留，不宣称全部合法tuple或动态执行已验收。

## 第三轮：静态计划与阅读版

[静态检查报告](../reports/vplan_static_check.json)核对JSON Schema、GEN↔SIG↔CV、phase/scope、source hash、CSV逐值和正文ID。P0 PASS仅为计划完整性；UNRESOLVED合法形式库、发生器、oracle、SM/SoC后端仍需后续实施。

阅读版由独立封面/页眉的vPlan builder生成，复用SM排版函数但不改旧SM文档。实际页数、原生表格/公式、两图、字体、边界及实际抽页目检以[最终QA](../reports/document_qa.json)为准；自动页界和抽样目检不代表人工逐页审校。

本轮仅修改verif/core/vplan及仓库README，不修改design RTL、已有tb/filelist/flow或既有MALU回归，不新增或伪造generator/SM测试执行证据。

最终集成仅规范主文EOF为单换行，技术内容、计划JSON和追踪数据不变；阅读版重新构建，P0报告与最终源hash同步。
