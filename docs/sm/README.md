# SM 架构与全指令审查

以用户上传的 PTX ISA Release 9.4（2026-07-17）为固定基准，覆盖全部 21 个指令大类：215 个实际指令说明节、2 个控制语法节，共217个 Syntax 块；另核对35个特殊寄存器说明节和34个第11章directive说明叶子。统计为规范说明节，不是SASS opcode数量或所有合法tuple数量。

- [完整架构正文与逐项映射](SM_ARCHITECTURE.md)
- [带七图的 DOCX](SM_Architecture_v1.0.docx) · [PDF](SM_Architecture_v1.0.pdf)
- [全部指令清单](research/ptx94_instruction_inventory.md) · [Syntax/ISA/Target机器证据](research/ptx94_instruction_inventory.json)
- [特殊寄存器完整索引](research/ptx94_special_register_inventory.md)
- [执行域审查](research/sm_execution_architecture_review.md) · [SM集成审查](research/sm_integration_review.md)
- [指令覆盖检查结果](research/instruction_coverage_check.json) · [文档产物QA](research/document_qa.json)
- [构建方法](BUILDING.md) · [七图说明](figures/FIGURES.md)

正文为架构层：SM与SoC边界、线程/warp/CTA/cluster、ITS、寄存器与CC、SALU/VALU/FPU/SFU、LSU/L1/SMEM、顺序/proxy、原子与mbarrier、TMA、各代矩阵、TMEM/MALU、DSM、Fabric、多位置内存、texture/surface、ABI/stack、系统/调试和能力验收。SM-ARCH-S0是项目方案，不声称复原NVIDIA未公开微架构。

项目统一1 core=1 SM，`sp`为core内部执行组织；每SM逻辑对接1个Tensor endpoint。≤64warp/≤8CTA、SMEM256KiB、TMEM最高288KiB为项目集成预算；RF物理容量保持参数，联合资源分配决定实际驻留。MALU保持dot-only，A/B格式、scale格式、BLOCK16/32与C缩放分别描述。

**完整审查不等于完整实现。** 现有功能RTL仍只有PROJECT_EXACT MALU及其测试。SM控制、普通执行域、SMEM/TMEM/Tensor外围、TMA/cluster/Fabric等没有本项目实现证据；未实现能力保持关闭。texture/surface与legacy matrix等保留明确兼容扩展边界，不吞成no-op。

源码审查脚本需要PyMuPDF以及同一份上传PDF：

```bash
python3 docs/sm/check_instruction_inventory.py --pdf /path/to/ptx_isa_9.4.pdf --require-document --require-special-registers
```

脚本核对固定PDF哈希、目录/正文编号、217个Syntax、651份Syntax/ISA/Target原文摘录及正文217+35行映射。它不解析所有合法修饰符组合，也不是汇编器或SM RTL验证。公开资料本轮访问失败，使用已保存的2026-10-26来源记录，见[本轮记录](research/public_source_evidence.json)与[历史快照hash](research/source_snapshot_manifest.json)。
