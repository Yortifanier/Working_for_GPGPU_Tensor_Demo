# tcgen05 Tensor 项目微架构

v1.0，2026-10-26。依据上位 [架构文档](../TCGEN05_TENSOR_ARCHITECTURE.md) 制定；新增硬件是项目拟议方案，未宣称复原 NVIDIA RTL 或完成 Tensor/PERF 验证。

- [微架构正文](TCGEN05_TENSOR_MICROARCHITECTURE.md)：26 章，包含 REF/PERF、TMEM、流水、队列、scoreboard、供数、scale、同步与 peer。
- [DOCX](TCGEN05_Tensor_Microarchitecture_v1.0.docx) · [PDF](TCGEN05_Tensor_Microarchitecture_v1.0.pdf)：带五张微架构图的阅读版。
- [设计预算](research/design_budget.json)：实际重算 bank 映射、159-brick 复用预算、数值位宽及服务率下界；不是硬件仿真。
- [审查与修正](research/review_resolutions.md)：独立审查意见及合并结果。
- [构建说明](BUILDING.md)：图源、文档与预算的复现方式。

REF 复用现有 MALU。PERF-S1 的 8/16/70/140 terms/cycle 是原始乘积入口预算；scale、累加、finalizer、bank 和写回需要分别验证，不能当作已测得的端到端吞吐。
