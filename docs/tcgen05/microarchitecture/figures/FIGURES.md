# Tensor 微架构图说明

五图均为**项目拟议微架构**，不是 NVIDIA 芯片结构图。队列、上下文、存储和通道数量为项目设计选择；REF 的现有 RTL 与 PERF 的未实现提案分别标注。

每张 PNG 为 2400×1608，附文字转路径的 SVG。以17 cm宽嵌入文档时，最小13.5 pt源字号等效约9.04 pt。生成器会检查框内文字边界，不通过缩小字号隐藏溢出。

| 文件 | 图意与边界 |
|---|---|
| `01_tensor_subsystem` | normalCQ24/escapeCQ8 经合法化、64项 OpTable/region scoreboard、8项 tile context、operand buffers、MALU、WBQ到TMEM。标出外部core、SMEM/TMA、barrier、peer；侧向连接表示资源/完成责任。 |
| `02_dispatch_and_issue` | S0–S5为可停顿阶段而非固定6周期。等待alloc的命令进入8项waitQ；escape/completion/release进度不依赖阻塞队首。 |
| `03_operand_and_tmem` | 每endpoint的32 banks×32bit 1R1W、bank/row映射、576列/288KiB及双向端口预算。operand暂存预算单列；CTA pair按两个endpoint事务式授予，allocation records为每endpoint 18项、pair合计36项，不按CTA复制容量。 |
| `04_async_tracking` | 每active issuer的normal MCS/full-done与SMEM-A MMA A-read序列及prefix分别跟踪，按commit类别快照，再经8项commit wait、16项eventQ与barrier ack。ARead通知不提前释放token/lease；ld/st另设per-warp完成域。 |
| `05_malu_adapter` | REF现有共享53/24乘法核与132/20字RAM；PERF分区为拟议8个base groups、每组2个11×11通道和6个booster。8/16/70/140 terms/cycle只属于PERF入口预算。FP8/6采用LSB为−32的80b局部和；FP4 signed9乘积归为signed14局部和，再经9条14b绝对值×unsigned8缩放后端汇入640b exact CSA。44项dot context、3个目标II=1 finalizer与159个4×4等价砖均是尚未实现的资源提案。 |

每个文件均有 `.png` / `.svg`。主文应各引用一次；文件名编号保持稳定，画面与图注按正文阅读顺序编号，因此 `05_malu_adapter` 显示图4，`04_async_tracking` 显示图5。适配图的直接汇入与fractional-scale分支只表达拟议路由，不将所有格式强制送入FP4后端。微架构阶段、时序、功耗和工艺面积须由后续实现与验证闭合，图中不作端到端性能保证。

从仓库根重新生成：

```bash
python3 docs/tcgen05/microarchitecture/figures/generate_figures.py
```

依赖 matplotlib、fontconfig 与 Noto Sans CJK 字体；字体和缓存均通过生成器显式选择。
