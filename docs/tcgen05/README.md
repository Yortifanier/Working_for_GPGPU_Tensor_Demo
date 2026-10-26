# tcgen05 Tensor 架构

v1.0，2026-10-26。规范基准为用户提供的 PTX ISA Release 9.4；这是一份架构文档，不设计微架构。

- [正文](TCGEN05_TENSOR_ARCHITECTURE.md)：20 章，涵盖对象、指令、资源、布局、数值类型、block scaling、稀疏、复用和同步契约。
- [DOCX](TCGEN05_Tensor_Architecture_v1.0.docx) · [PDF](TCGEN05_Tensor_Architecture_v1.0.pdf)：带 5 张架构图的阅读版。
- [规范核查](research/ptx94_architecture_audit.md) · [公开来源审查](research/architecture_source_review.md)：页码、target 条件和证据边界。
- [构建说明](BUILDING.md)：正文、SVG/PNG 和文档生成器均随仓库保存。

原生 tcgen05 能力与项目 MALU 的 PROJECT_EXACT 功能分开记录；未证明的 Ti16 raw 编码、target 与 Rubin 的映射，以及具体数值实现保留明确边界。原始用户 PDF 不复制入仓库。
