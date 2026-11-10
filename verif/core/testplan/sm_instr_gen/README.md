# SM 指令发生器 Testplan

版本v1.0，计划日期2026-11-09，承接[SM指令发生器vPlan](../../vplan/sm_instr_gen/README.md)。每个SIG一对一对应TC，source阶段与覆盖关联保持不变。

- [完整Testplan](SM_INSTR_GEN_TESTPLAN.md)
- [DOCX](SM_Instruction_Generator_Testplan_v1.0.docx) · [PDF](SM_Instruction_Generator_Testplan_v1.0.pdf)
- [106个完整用例](testcases.json)：前置、参数、初始化、步骤、检查点、通过/失败和产物。
- [8个配置Profile](config_profiles.json) · [6类回归Suite](campaigns.json)
- [873条计划运行CSV](run_matrix.csv) · [同内容JSON](planned_runs.json)
- [静态检查结果](reports/testplan_static_check.json) · [文档QA](reports/document_qa.json) · [构建与检查方法](BUILDING.md)

SMOKE、DIRECTED、NEGATIVE、RANDOM、STRESS、REPLAY分别展开25、106、104、392、136、110条记录，873个计划seed唯一且可重算。REPLAY的repeat是独立基线，case内部对同一manifest的回放保持原seed；CSV行序不代表启动依赖顺序。

TMEM在第10章及TC-TMEM-001..006独立展开；MALU的AB格式、scale格式、BLOCK16/32、Cshift与Ti16 decoded控制分别描述。正文包含与JSON一致的命名数值/切拍见证。回归闭合TC-REGRESS-004只消费已完成的上游证据，禁止递归调用自身。

**当前106个功能用例和873条计划记录均为NOT_RUN，7个动态Profile均关闭。** 缺generator、oracle、SM/SoC后端或必需配置时保持BLOCKED；不把P0或旧MALU测试结果当成本计划动态执行证据。

从仓库根运行实际P0检查：

```bash
python3 verif/core/testplan/sm_instr_gen/check_testplan.py
```

它检查源hash、SIG→TC、phase/CV、配置与suite、seed展开、CSV/JSON及状态，不执行runner/发生器/模型/SM。`selftest_check_testplan.py`仅验证静态工具对合成错误的诊断。

`research/cases_*.json`为分工细化输入的历史快照，不是最终执行源；合并修正与审查以`testcases.json`和[审查闭合记录](research/review_resolutions.md)为准。
