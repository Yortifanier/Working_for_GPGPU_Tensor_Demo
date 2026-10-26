# MALU 检查证据归档（2026-10-26）

本目录保存实际完成的三轮检查及独立审查的小型证据；报告原样复制，不重新运行仿真，不保存 XML、C++、向量全集或工具链。原始回归完成时间为各 JSON 记录的 2026-10-25（Asia/Shanghai）；2026-10-26 为归档日期。

最终稳定源码/filelist 聚合签名：

`197395785750354d3e1acf59dbba4542894062cfe66390eb952ed6d9022f96fd`

三份 results 的 11 项源码 SHA256 已与当前文件重新核对，并重新计算聚合签名。四份日志的真实 MALU_PASS 行、计数与 cycles 已逐项对照 JSON；日志原始 SHA256 与独立最终 audit 一致。

| 轮次 | 配置 | 数值执行次数 | 协议执行次数 | cycles | 结果 |
|---|---|---:|---:|---:|---|
| 1 | LANES=4，FP64 on | 228 | 14 | 84,271 | PASS |
| 2 | LANES=4，FP64 on | 1,228 | 14 | 780,411 | PASS |
| 3 | LANES=4，FP64 on | 9,177 | 14 | 2,194,731 | PASS |
| 3 参数配置 | LANES=1，FP64 off | 228 | 13 | 61,616 | PASS |
| 累计 | 含重复定向回归 | **10,861** | **55** | — | 全部通过 |

另有 decoder-only 独立检查 **66,999 次、0 mismatch**，单列于 `decode_review_result.json`，不与主回归混计。主执行量包含跨轮重复，不能称为同数量互异数学输入；exhaustive 只覆盖所述 FP4/FP6 原始编码 pair，不表示穷尽全部格式、K 或协议空间。

## 文件对应

- `round1_results.json`、`round2_results.json`、`round3_results.json`：原始轮次报告，包括工具、配置、seed、源码哈希和实际计数。
- `round1_run_l4_f1.log`、`round2_run_l4_f1.log`、`round3_run_l4_f1.log`、`round3_run_l1_f0.log`：四份完整短仿真日志，按原始字节保留。
- `resource_inventory.json`：第三轮实际 elaboration 清单。FP64 on 为单个 53×53→106 变量乘法节点和 132×32 RAM；FP64 off 为单个 24×24→48 节点和 20×32 RAM；共享 word 加法结果均为33位（32位加 carry）。
- `decode_review_result.json`、`final_independent_audit.json`：agent1 独立解码结果和最终源码/日志/资源总评。
- `rtl_review_spec.md`、`rtl_review_arithmetic.md`：真实多轮规格与算术审查记录，保留早期等待状态及最终更新，不改写历史。
- `archive_manifest.json`：归档文件的来源、大小与 SHA256，以及本次轻量检查结果；不替代实际仿真报告。

## 假设和结论边界

实现及参考模型采用 **PROJECT_EXACT**，不是 Rubin/Blackwell 内部数值行为、原生完整 PTX/tcgen05 前端或设备 bit-match。混合浮点 tuple、BF16 输出、TF32 低13位清零载体及 decoded-Ti16 均按项目明示协议。Ti16 raw 编码有意拒绝；FP64-off 的 F64 请求按 UNSUPPORTED 验证，不计为该配置执行了 F64 算术。

资源证据来自 Verilator RTL elaboration，不是工艺映射、DSP 数量、SRAM/BRAM 宏推断、PPA 或 Rubin 吞吐签核。功能仿真、源码审查和当前工具语法检查不构成形式证明。

本次归档检查：所有 `tools/*.py` 通过 Python AST 语法解析；`git diff --check` 通过。未修改 RTL、主 README 或主设计文档；未提交或推送。

复现完整三轮可从仓库根运行 `python3 tools/run_malu_checks.py --round all`，工具准备见项目环境文档。该命令不是本次归档重复执行的动作。
