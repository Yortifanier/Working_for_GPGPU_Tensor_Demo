# tcgen05 Tensor 项目微架构

v1.1，2026-10-27。依据上位 [架构文档](../TCGEN05_TENSOR_ARCHITECTURE.md) 制定；新增硬件是项目拟议方案，未宣称复原 NVIDIA RTL 或完成 Tensor/PERF 验证。此版补齐 core 共享 SMEM 本体，见正文 §7.2–7.9。

- [微架构正文](TCGEN05_TENSOR_MICROARCHITECTURE.md)：26 章，包含 SMEM/TMEM、REF/PERF、流水、队列、scoreboard、scale、同步与 peer。
- [DOCX](TCGEN05_Tensor_Microarchitecture_v1.1.docx) · [PDF](TCGEN05_Tensor_Microarchitecture_v1.1.pdf)：带六张微架构图的阅读版。
- [设计预算](research/design_budget.json)：实际重算 SMEM/TMEM 映射、共享带宽、ECC、返回信用、159-brick 复用及数值位宽；不是硬件仿真。
- [审查与修正](research/review_resolutions.md)：独立审查意见及合并结果。
- [构建说明](BUILDING.md)：图源、文档与预算的复现方式。

REF 复用现有 MALU。PERF-S1 的 8/16/70/140 terms/cycle 是原始乘积入口预算；scale、累加、finalizer、bank 和写回需要分别验证，不能当作已测得的端到端吞吐。

历史 v1.0：[DOCX](TCGEN05_Tensor_Microarchitecture_v1.0.docx) · [PDF](TCGEN05_Tensor_Microarchitecture_v1.0.pdf) · [QA](research/document_qa_v1.0.json)。v1.0 正文/图源对应 [dd031c8 快照](https://github.com/Yortifanier/Working_for_GPGPU_Tensor_Demo/tree/dd031c8581a21eeca318f8568ed874015e6061f5/docs/tcgen05/microarchitecture)，其旧哈希不用于核验当前 v1.1 源文件。
