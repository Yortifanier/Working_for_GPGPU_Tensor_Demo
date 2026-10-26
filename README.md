# Working_for_GPGPU_Tensor_Demo
Tensor

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
