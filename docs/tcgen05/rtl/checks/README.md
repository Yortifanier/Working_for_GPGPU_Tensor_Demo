# tcgen05 验证证据索引

当前交付以 [`final/results_all.json`](final/results_all.json) 为准。该报告由实际 central runner 生成，记录工具、参数、seed、全部受测源码 SHA256、非零执行计数及日志 SHA256。`final/` 内保留各配置的 lint/编译/运行日志；`archived_log` 字段给出仓库中的归档位置，原 `log` 字段保留构建时路径。

执行入口：

```bash
python3 verif/core/flow/rtl/sp/eu/tensor/tcgen05/run_tcgen05.py --suite all --jobs 2
```

[`resources/resources.json`](resources/resources.json) 是独立的 elaboration 资源审计，附两种 FP64 配置的原始 XML gzip 和日志。XML 解压后的 SHA256 对应报告，复现入口为 `python3 tools/tcgen05_resource_audit.py`。它核对实际 MALU 实例与共享乘法／累加路径，不是综合或 PPA 签核。

同目录早期 `layout_unit.json`、`legalize_unit.json`、`move_unit_results.json`、`commit_fanout_results.json` 及其日志保留阶段快照。它们只对各自记录的源码 hash 和当时的测试范围有效。例如合法化测试由97项扩充为166项，最终数字使用central报告，不能把旧文件直接解释为当前源码的全套验证。

数值／布局测试、endpoint 测试和双端 cluster 测试是不同证据层级。layout 的409600个输出地址不是409600条已运行MMA；各 suite 的检查数也不能合成PTX指令覆盖率。106个SM指令发生器testplan用例并未由本次tcgen05回归执行。

项目模式、有限native用例、Ti16 decoded transport、shift消歧和设备对应边界见 [RTL实现说明](../RTL_IMPLEMENTATION.md)。独立终审见 [ISA](../review_final_isa.md)、[控制／资源](../review_final_control.md)、[MMA](../review_final_mma.md)。
