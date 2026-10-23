# Working_for_GPGPU_Tensor_Demo
Tensor

## MALU 设计与工程骨架

当前发布设计评审文档与目录骨架，尚未实现 MALU RTL。MALU 只提供向量点积 `D=C+Dot(A,B)`。

- [设计文档（Markdown）](docs/malu/MALU_design.md)
- [带图 DOCX](docs/malu/MALU_design_v1.1.docx) · [PDF 预览](docs/malu/MALU_design_v1.1.pdf)
- [环境初始化说明](docs/ENVIRONMENT.md) · [文档生成](docs/malu/BUILDING.md)
- [PTX 核验](docs/malu/research/ptx_findings.md) · [论文和专利核验](docs/malu/research/literature_findings.md)

`design`、`verif` 下分别包含 `core/soc`，继续分为 `filelist/flow/src`。`src` 与 `filelist` 含 `if/common/rtl`；`rtl` 含 `sp/cp/mss`；MALU 位于 `sp/eu/tensor/malu`。空目录用 `.gitkeep` 保留。

在 tcsh 中从根目录执行 `source ./setup.csh`；默认只初始化目录，不要求安装 EDA。站点工具及版本写入本地、未跟踪的 `setup.local.csh`，可参考示例文件。

Rubin 单 GPU dense 参考：TF32 : FP16/BF16 : FP8/FP6 Training : NVFP4 Training = **0.5 : 1 : 4.375 : 8.75**。50 PFLOPS NVFP4 inference 为 sparse，独立登记；逐合法 tuple 的性能仍需映射。
