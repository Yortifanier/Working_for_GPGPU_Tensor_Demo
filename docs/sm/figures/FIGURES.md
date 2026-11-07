# SM 架构图说明

七图是**项目拟议 SM 组织图**，不是 NVIDIA 结构图。每图提供 `.png` 与文字转路径的 `.svg`；物理参数为项目选择，不从 Rubin 峰值算力反推。现有点积 MALU 与未实现的外围 SM、PERF 方案分开标注。

计量采用 SM-ARCH-S0：`1 core = 1 SM`，sp 为内部组织；每 SM 1 个逻辑 Tensor endpoint，最多 64 warp、8 CTA、32 threads/warp。SMEM 256 KiB 与 TMEM 最大 288 KiB 均按每 SM 计量，RF 容量继续参数化。

| 文件名 | 图意与边界 |
|---|---|
| `01_sm_overview` | CTA admission、warp 控制、指令前端、issue/scoreboard、GPR/collector、SIMT 与 Tensor 执行域、LSU、L1、共享 SMEM 和 Tensor TMEM 的总体职责；另列 warp 通信、texture/surface、Fabric、调试及运行时服务。逻辑框数不表示物理实例数。 |
| `02_warp_cta_control` | 驻留资格、发射条件、分歧/汇合、barrier 等待、完成唤醒与退出 drain 的关系。图不指定 NVIDIA 的调度策略、流水周期或重汇合电路。 |
| `03_register_execution` | GPR/operand collector 到 INT、FP/FMA、SFU、LSU 的功能域与返回路径。Tensor 从 GPR 取得描述符/标量控制，矩阵 payload 通过 SMEM/TMEM，结果写 TMEM；tcgen05.ld 另走寄存器返回。 |
| `04_memory_hierarchy` | global/local 经 LSU/L1 通向外部 L2；shared 字节对象在 core 共享 SMEM；Tensor lane/column 在独立 TMEM。每 SM 的 SMEM 为 256 KiB/64 banks，TMEM 配置上限为 288 KiB/32 banks；每 SM 1 个逻辑 Tensor endpoint，两池分开计量。 |
| `05_memory_async_sync` | 上半为 SMEM bank commit、collector 失效实际生效与 proxy cutoff/publish；下半为 normal MCS/full、SMEM-A MMA A-read、commit 与真实 SMEM barrier 对象的原子更新 ack。ld/st 完成域独立。 |
| `06_tensor_malu_integration` | tcgen05 legalizer/资源保护、tile planner、不可变源快照与 descriptor+C/operand-beat/response 的 dot 合同。A/B 与 scale 格式、BLOCK16/32 独立；C 的 `c_scale_shift` 另列配置。MALU 只做 dot，标量 FMA/SFU 属其他执行域；PROJECT_EXACT 不声称设备 bitfit。 |
| `07_instruction_lowering` | PTX 虚拟 ISA 的类型/target 合法组合核查、编译 lowering、项目 ISA/IR 合同和 SM 硬件译码分开。覆盖状态必须逐族标注，不能把所有格式×opcode 当作合法 ISA。 |

PNG 为 2400×1608。最小源字号 13.5 pt，在 17 cm 宽文档中等效约 9.04 pt；生成器实际检查框内文字边界。图注应按 1–7 阅读顺序引用，每图一次。

从仓库根生成：

```bash
python3 docs/sm/figures/generate_figures.py
```

只生成指定图可增加 `--only` 与文件名（不含后缀）。生成依赖 matplotlib、fontconfig 和 Noto Sans CJK SC。SVG 去除行尾空白，文字转路径，便于移植。
