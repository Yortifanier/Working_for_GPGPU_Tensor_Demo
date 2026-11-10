# Working_for_GPGPU_Tensor_Demo
Tensor

## SM 指令发生器 Testplan

[执行计划位于verif/core/testplan/sm_instr_gen](verif/core/testplan/sm_instr_gen/README.md)，将106个vPlan测试点细化为参数、初始化、步骤、检查点、通过/失败条件和证据；附8个profile、6类suite及873条固定seed计划运行矩阵。TMEM与矩阵格式/scale/BLOCK/Cshift单独展开。当前功能用例均NOT_RUN，动态配置关闭，P0静态检查单独记录。

## SM 指令发生器验证计划

[vPlan位于verif/core/vplan/sm_instr_gen](verif/core/vplan/sm_instr_gen/README.md)，包含25个验证特性、106个计划测试点、75个覆盖点，以及217条指令／语法和35节特殊寄存器追踪。覆盖发生器自身合法性、依赖/控制流、存储同步、完整TMEM生命周期、矩阵格式/scale/BLOCK、系统服务、覆盖、回放及缩减。当前功能测试均为PLANNED / NOT_RUN，静态计划检查单独记录。

## SM 架构与 PTX 9.4 全指令审查

覆盖全部21个指令大类、215个实际指令说明节及2个控制语法节，附217行架构映射和35节特殊寄存器索引。正文包括SIMT/ITS、SALU/VALU/FPU/SFU、寄存器、LSU/L1、完整SMEM、同步/原子/proxy、TMA、各代Tensor/TMEM/MALU、cluster/DSM、Fabric、texture/surface和系统服务。

- [SM架构正文](docs/sm/SM_ARCHITECTURE.md) · [带七图DOCX](docs/sm/SM_Architecture_v1.0.docx) · [PDF](docs/sm/SM_Architecture_v1.0.pdf)
- [全量指令证据与构建入口](docs/sm/README.md)

SM-ARCH-S0是项目架构方案；已实现RTL仍限于下述dot-only MALU，完整指令清点不代表全SM已经实现或验证。

## tcgen05 Tensor 架构

以用户提供的 PTX ISA 9.4 为基准，涵盖 Tensor 功能边界、TMEM、全部指令家族、格式/shape/scale、稀疏与复用、CTA pair、异步完成和内存顺序。文档限定为架构层，不规定物理阵列、流水线、端口或 RTL 微架构。

- [完整架构文档（Markdown）](docs/tcgen05/TCGEN05_TENSOR_ARCHITECTURE.md)
- [带图 DOCX](docs/tcgen05/TCGEN05_Tensor_Architecture_v1.0.docx) · [PDF](docs/tcgen05/TCGEN05_Tensor_Architecture_v1.0.pdf)
- [规范逐页核查](docs/tcgen05/research/ptx94_architecture_audit.md) · [来源审查](docs/tcgen05/research/architecture_source_review.md) · [构建方法](docs/tcgen05/BUILDING.md)

项目微架构已单独成文，v1.1 补齐 core 共享 SMEM 的 banks、LSU/TMA/Tensor 仲裁、RMW/barrier、proxy 与返回信用，连同 REF 集成、PERF-S1、TMEM、scale、完成跟踪及 peer 协议：

- [微架构正文](docs/tcgen05/microarchitecture/TCGEN05_TENSOR_MICROARCHITECTURE.md)
- [微架构 DOCX](docs/tcgen05/microarchitecture/TCGEN05_Tensor_Microarchitecture_v1.1.docx) · [PDF](docs/tcgen05/microarchitecture/TCGEN05_Tensor_Microarchitecture_v1.1.pdf)

微架构是项目拟议方案；新增 Tensor/PERF 硬件仍待实现及验证，算力比例表给出入口预算。

## MALU 设计与工程骨架

当前包含可综合的 PROJECT_EXACT MALU 功能 RTL、专用接口和可复现验证。MALU 只提供向量点积 `D=C+Dot(A,B)`；精确乘积/归约及最终舍入为本项目数值约定，不是 NVIDIA 设备拟合。

- [RTL 实现与三轮检查记录](docs/malu/RTL_IMPLEMENTATION.md)
- [编码前设计评审稿（Markdown）](docs/malu/MALU_design.md)
- [带图 DOCX](docs/malu/MALU_design_v1.1.docx) · [PDF 预览](docs/malu/MALU_design_v1.1.pdf)
- [环境初始化说明](docs/ENVIRONMENT.md) · [文档生成](docs/malu/BUILDING.md)
- [PTX 核验](docs/malu/research/ptx_findings.md) · [论文和专利核验](docs/malu/research/literature_findings.md)

`design`、`verif` 下分别包含 `core/soc`，继续分为 `filelist/flow/src`。`src` 与 `filelist` 含 `if/common/rtl`；`rtl` 含 `sp/cp/mss`；MALU 位于 `sp/eu/tensor/malu`。空目录用 `.gitkeep` 保留。

在 tcsh 中从根目录执行 `source ./setup.csh`；默认只初始化目录，不要求安装 EDA。站点工具及版本写入本地、未跟踪的 `setup.local.csh`，可参考示例文件。

Rubin 单 GPU dense 参考：TF32 : FP16/BF16 : FP8/FP6 Training : NVFP4 Training = **0.5 : 1 : 4.375 : 8.75**。50 PFLOPS NVFP4 inference 为 sparse，独立登记；逐合法 tuple 的性能仍需映射。

[Rubin 来源交叉核验与替代检索记录](docs/malu/research/rubin_source_crosscheck.md)

## 编译与验证

```sh
python3 tools/bootstrap_verilator.py
make -f verif/core/flow/malu/Makefile check
```

引导工具校验官方包 SHA-256；首次元数据发现验证 Debian 签名，已锁定测试版本 Verilator 5.032。无需 root 或商业 EDA。生成物和测试向量位于被忽略的 `build/`。三轮检查由同一稳定源码快照执行，实际计数与复核证据见实现说明。

共享乘法器及32位逐字加减通路服务浮点、整数和scale。开启FP64时使用53×53乘法和132×32累加存储；关闭时缩为24×24和20×32。`LANES`只表示输入缓存槽数，数值运算按资源复用顺序执行。当前未实现Rubin峰值吞吐配比；Ti16只支持显式decoded项目传输，raw编码请求被拒绝。

原33页v1.1 DOCX/PDF是2026-10-23的编码前设计快照，当前代码能力、接口和验证状态以`RTL_IMPLEMENTATION.md`为准。
