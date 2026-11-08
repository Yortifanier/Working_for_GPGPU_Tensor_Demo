# SM 指令发生器 vPlan

日期：2026-11-08；版本v1.0。这里的发生器指**验证端受约束指令／整程序生成器**，包含控制流、依赖、地址与资源状态、异步收尾和可复现刺激；不是SM的instruction fetch。

- [完整vPlan](SM_INSTR_GEN_VPLAN.md)
- [带图DOCX](SM_Instruction_Generator_Vplan_v1.0.docx) · [PDF](SM_Instruction_Generator_Vplan_v1.0.pdf)
- [25个验证特性／75个覆盖点](vplan_features.json) · [106个计划测试点](testpoints.json)
- [217条指令／语法追踪CSV](instruction_traceability.csv) · [JSON](instruction_traceability.json)
- [35节特殊寄存器追踪CSV](special_register_traceability.csv) · [JSON](special_register_traceability.json)
- [静态计划检查结果](reports/vplan_static_check.json) · [构建方法](BUILDING.md)
- [ISA审查](research/isa_review.md) · [发生器方法审查](research/generator_method_review.md) · [有状态资源审查](research/stateful_resource_review.md)

25个特性覆盖capability/IR、寄存器依赖、整数/浮点/转换、CFG/ITS/warp通信、LSU/SMEM、mbarrier/proxy、异步复制/TMA、**独立TMEM生命周期**、矩阵/MALU的AB格式／scale格式／BLOCK16/32／Cshift、cluster/DSM/Fabric、texture/surface、stack/ABI/sreg、负例、环境、cleanup、覆盖、回放和缩减。

源基准为固定PTX9.4及[SM架构](../../../../docs/sm/SM_ARCHITECTURE.md)。217条为215个实际指令说明节加2个控制语法节，不是217个独立opcode或全部合法tuple数量。CSV是通用追踪表，特定EDA导入格式后续另约定。

从仓库根执行计划静态检查：

```bash
python3 verif/core/vplan/sm_instr_gen/check_vplan.py
```

该命令检查source hash、217+35行、CSV/JSON一致性、GEN↔SIG↔CV关联、阶段/scope与状态。它不生成或执行指令。**当前106个功能测试全部PLANNED / NOT_RUN，动态执行数为0**；完整generator、独立oracle、SM/SoC环境仍待实现。P0静态PASS仅表示计划一致，不修改功能测试状态。
