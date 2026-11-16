# tcgen05 MMA 最终独立审查

日期：2026-11-16。范围仅为当前 `tcgen05_mma.sv`、对应 TB 和已完成 MMA 专用回归证据。审查期间未修改 RTL、TB、filelist 或 runner。

## 结论

共享 deferred result tile 的 context/tag 映射、先消费全部输入再写 D、D 写使能及响应等待、完整 M 行 ashift 路径未发现确定阻断。此前发现的项目组合 `a_from_tmem + transpose_a + ashift` 已在 legalizer 和 MMA 的验证阶段拒绝，TB 检查拒绝前不发生 A/TMEM 读取。

## 源码核对

| 核对项 | 当前实现与结论 |
|---|---|
| result index | 创建 dot 时将单调递增的 `total_dots` 保存为 `context_result_index`；M/N 创建为 row-major 顺序。context 槽复用不会重新解释已保存的结果索引。 |
| 返回映射 | array response tag 指向仍存活的 context；验证状态和逻辑 K 完整后，按该 context 的固定索引写共享 tile，并关闭 context。 |
| 输入保护 | 只有 `all_created && completed_dots == total_dots` 才进入 `M_WRITEBACK_FETCH`。因此 A/B、旧 C、metadata、scale、LUT 的后续读取不会被此前 dot 的 D 写回污染。 |
| RAM 读写次序 | 每个索引先被对应成功 response 写入，全部完成之后才开始读；RAM 不复位不构成未初始化读取。writeback 的 M/N/index 游标独立于复用中的算术 context。 |
| D mask | 按 writeback 的实际物理 lane/peer 取 `disable_d_lanes`；跳过写入仍推进相同输出游标，不改变后续结果位置。 |
| 写 strobe | native/canonical F16/BF16 使用低两 byte；普通32-bit结果写全 word。F64 项目扩展依次写 low/high 两 word，两者完成后才前进。 |
| 完成点 | `M_MEM_WAIT` 匹配响应事务号，成功后才进入后继状态。最后 D ack 之后才进入 ashift/finish；外部写失败按错误终结，不承诺已提交 word 回滚。 |
| ashift | 对整个 M128/256 的 stored-K 行移动；不是每32行重启的 standalone quarter shift。保留 tail；native pair M128 的重复 A 布局分别处理两份副本。 |
| transpose + ashift | 当前拒绝，避免把转置／packed A 的非连续逻辑行当成连续 word 进行覆盖；对应 TB 明确断言无读取副作用。 |
| A-read | 仍按最后一个 SMEM-A dot 的最终 A 捕获推进，区别于 deferred D/full 完成；TMEM-A 不虚构 SMEM-A 通知。 |

默认 MAX_M/MAX_N 为256时，共享结果低 plane 为256 KiB；FP64启用时增加256 KiB高 plane。多个 MALU 共用该 tile，不按引擎数复制。此容量不属于已有 TMEM RAM，也不是综合后 SRAM 宏／PPA 结果。LANES 是 beat 槽数，不能解释为每个 MALU 的乘法器数量。

## 已核实的动态证据

证据文件：`build/tcgen05/rtl/results_mma.json`。记录工具为 Verilator 5.032，启用 SVA，报告时间 `2026-11-15T15:18:10.223074+00:00`。以下为实际完成的三次运行，不能替代随后 central `all` 的最终报告。

| 配置 | commands | checks | max_contexts | cycles |
|---|---:|---:|---:|---:|
| DOT_ENGINES4 / LANES4 / FP64 extension on | 69 | 12168 | 4 | 6151748 |
| DOT_ENGINES1 / LANES4 / FP64 extension on | 69 | 12164 | 1 | 14718768 |
| DOT_ENGINES3 / LANES1 / FP64 off | 66 | 12145 | 3 | 8255906 |

当前 MMA DUT SHA256：`49ae64342febc02ae28d03a79c4a02adac54b41da8c2d46437f0324297d32732`。

当前 MMA TB SHA256：`e52771bf8a54b1e348113a5c500f24e65d9fce012a99acb431780c7ce8fb0913`。

上述两个文件与报告逐项匹配，三份运行日志也分别匹配报告记录的 SHA256。主 agent 此后补充其他单元测试时，全仓源码签名可能改变；因此本审查只确认这两个受审文件与本次 MMA 专用证据对应，不将旧报告签名声明为最终全仓签名。

TB包含超过算术引擎数的 metadata/D alias、native A/D 共享列、原生 MXFP8/NVFP4 scale、structured sparse、LUT、WS/collector、input-D/Cshift、全 M ashift、转置 ashift 拒绝、旧事务号及错误恢复等真实数据检查。不同配置的 cycle 数是该功能测试负载的执行结果，不是 Rubin 吞吐比或物理阵列复原证据。

## 保留边界

本审查未进行原生 GPU oracle、穷举所有合法 tuple、形式证明、综合或时序签核。数值采用 PROJECT_EXACT；Ti16 decoded transport、shift 方向消歧及其他规范边界仍以 `RTL_IMPLEMENTATION.md` 和 `LAYOUT_IMPLEMENTATION.md` 为准。外部 SM/cluster 仍须保证 owner 生命周期、源对象保护和真实写入/事件责任，不得把仅返回 tag 的空服务当成设备功能完成。
