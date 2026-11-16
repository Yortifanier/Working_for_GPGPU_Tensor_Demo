# tcgen05 控制、生命周期及资源复用终审

本记录为代码只读审查。审查对象为 `tcgen05.sv`、allocator/hub、pair、memory/lane/word_arbiter、commit fanout、MMA deferred writeback 及 dot array；不替代实际仿真、形式验证或综合。最终执行结果以本目录归档的、与源码 hash 对应的回归报告为准。

## 发现与处置要求

### 生命周期：延迟 RELEASE 响应不得清理新一代 owner

审查时发现顶层在接受 `CTX_INIT` 时写 `owner_pair`，而在 `CTX_RELEASE` 的响应经 allocation-return 路径返回时，无条件清该 owner 的 `owner_pair`、`owner_fault` 和所有同 owner 的 `ctx_live`。allocator 内部释放 owner 的时点早于这个响应，因此提前提交同 owner、较新 generation 的 INIT 可能与旧 RELEASE 响应重叠。

主 agent 已实施最小修正：保留 `owner_pair` 到下次 INIT 覆盖；RELEASE 清理 ctx 时同时匹配 owner 和 generation；清 owner fault 时检查当前 owner generation 仍等于 RELEASE generation，并保护同拍新 INIT；新 INIT 接纳时清除旧代故障。allocation-return 的 MEM_ERROR 也只标记当前匹配 generation 的 owner。终审只复核这些源码，没有编辑 RTL。

`tb_tcgen05.sv` 新增了定向反例：先阻塞 core 响应，使 owner3 的旧 RELEASE 已在 allocator 执行而响应尚未送达；随后启动 owner3/generation2，改为 group2，并登记该新代的 FENCE/issuer context；放开反压后检查旧响应没有清除新 group 或新 issuer，再用 group2 COMMIT 验证准入和完成。此用例检验真实重叠，不是把依次 RELEASE→等待→INIT 当作反例。

实际 `build/tcgen05/rtl/results_integration.json` 的运行时间为 `2026-11-15T15:15:30.881649+00:00`，源码签名为 `d15352b7d7c7501ec2da1803dd85a6c96996ef8603abbc9cdb3309ac2a46a796`。本次复核确认报告记录的 top 与 TB SHA256 分别为 `62211b18723f20aad8bf38c22c221761226472654218b8fe0b35de2b30a2f684`、`9a29de3f8db7e2ce864d17cd61501a45d258eedfb3691ced4c88cfc3fa78a6e1`，与当前文件一致。三次实际 endpoint 仿真均通过：

| 参数与 seed | 检查 | 响应／事件 | 周期 |
|---|---:|---:|---:|
| COLS576 / LANES4 / FP64扩展开启，1907 | 1744 | 139／13 | 77775 |
| 同上，1908 | 1744 | 139／13 | 77935 |
| COLS64 / LANES1 / FP64关闭，1909 | 1770 | 130／13 | 79542 |

本次复核时，该报告列出的63项源码 SHA256 全部匹配当前文件；运行日志路径正在被最终 all-suite 重跑复用，旧 integration 报告的日志 hash 已不能校验这些覆盖后的文件。因此这里引用的是旧报告记录的执行结果；最终归档必须采用新报告及配套日志，不能将旧 JSON 和新日志拼接成一份证据。

该 lifecycle 问题在上述源码快照与定向用例范围内已关闭；这些是 endpoint 回归计数，不是全部 PTX tuple 或最终 all-suite 回归的替代。发布时仍以归档 central 报告和对应源码 hash 为准。

即使实现允许上述重叠，未来 SM 仍应对每个 owner 的启动、退出、重新分配建立明确的 scoreboard 依赖；释放后的地址不能再被新指令引用。

## 已核对的结构不变量

| 路径 | 审查结论及条件 |
|---|---|
| queued/active execution | 入队时增加对应 issuer 的 issued 计数；未完成计数、active 引用、wait/commit 引用阻止 owner 退出。单 parent 执行，parent 内有多个独立 dot context。 |
| allocation hub | 注册的单请求槽固定对 allocator 的请求；路由槽记录原 tag/client。等待容量的 ALLOC 保留路由和命令，不持有整个命令端口。 |
| paired ALLOC | 两端均按 even-first 准备；第二端冲突时回滚第一端；第一阶段 publish 失败也进入清理。provisional record 不允许普通 TMEM 访问。 |
| paired DEALLOC | FREE_PREPARE 将 record 标为 release_pending；普通访问拒绝该 record；两端 prepare 完成后再 commit。commit 是释放边界，链路 reset/丢包恢复须由集成协议处理。 |
| peer owner hold | parent 先 PIN 远端 owner，完成远端访问后 UNPIN；child token、memory hold、allocation-return 与 fanout busy 参加 owner busy。 |
| peer memory progress | 普通执行/outbound 与 inbound service 分别拥有独立 lane，避免双方各自等待对端服务导致闭环等待；本地 RAM 与 SMEM 再做仲裁。 |
| transaction identity | 外部内存事务使用 `{reset_epoch, sequence[30:0], lane}`；私有 engine txn ID 在返回端恢复。错 ID 响应被丢弃，不能完成另一请求。 |
| arbitration stability | allocator hub、control mux、word arbiter、dot result mux 均提供保持路径。输出反压时不重新选择载荷。 |
| multicast completion | fanout busy 覆盖最后一次输出与中间空拍；每个 mask bit 一次目的事件。错误事件 arrive_count=0，不能冒充 barrier arrive 成功。 |
| deferred MMA D write | 创建 dot 时分配固定 result index；各 core 完成顺序不改变结果位置；全部 dot 和源读取完成后才开始 D 写回。shared tile RAM 读取之前已写入对应条目，不依赖 RAM reset。 |

以上结论基于现有状态机与赋值顺序，不等同于所有并发序列的穷尽证明。

## 资源与性能表述

默认 `DOT_ENGINES=4`，每个 engine 实例化一个 `malu_core`。每个 core 复用一条乘法路径、一条逐字精确累加路径及解码/规格化/舍入状态机。`LANES=4` 是每个 beat 的输入缓存容量，不表示单 core 有四个乘法器。

| 存储/算术 | 默认配置 | 可选配置及说明 |
|---|---:|---|
| 共享乘法路径 | 4 组 24×24 | ENABLE_FP64=1 时为 4 组 53×53；不是每格式各复制一套 |
| 每 MALU 精确累加 RAM | 20×32 bit = 80 B | FP64 扩展时 132×32 bit = 528 B；另外有寄存器及输入缓存 |
| shared MMA result tile | 256×256×32 bit = 256 KiB | FP64 扩展多一个高 32-bit plane，总计 512 KiB；低精度结果仍使用 32-bit 存储槽 |
| project TMEM | 128×576×32 bit = 288 KiB | 随 COLS 线性缩放；32 个 bank，每 bank 4×COLS 行 |
| operand/meta/scale/LUT 读取 | 一个共享读取状态机 | 多 dot 算术可并发，输入读取和写回带宽仍受共享服务端口约束 |

deferred result tile 保护输入 A、metadata、scale、LUT 与 D 的物理地址重叠，但增加了显著片上存储。它是当前功能性实现的成本，不是从 Rubin 公开资料推断出的硬件结构，也没有获得 PPA 或目标频率结论。

不能由 `DOT_ENGINES`、`LANES` 或某个 TB 的周期比推导 Rubin 不同格式的峰值算力配比；当前 RTL 未声明实现 Rubin 的物理 MALU 数、内部几何尺寸或峰值吞吐。

## 集成时必须保留的条件

1. reset 必须协同取消/排空控制请求、响应、RF fragment、memory response 和 completion event；新 epoch 应与旧 epoch 不同，运行中保持 epoch 稳定。
2. cluster fabric 必须保持端点及 owner/generation/tag 身份，不能丢失已接纳的控制响应。当前控制状态机不承诺在任意丢包或伪造响应下自动恢复。
3. event_ready 表示 SM/barrier agent 已接管该目标的 arrive-one 责任，已实际更新或持有独立目的 owner 引用；仅缓存事件却允许目的资源释放不满足此条件。
4. core admission 应将 BUSY 作为重试/背压诊断，不能翻译成 PTX 规定的异常。普通寄存器、SMEM、mbarrier 的线程同步与 generic-proxy 操作仍由 SM 完成。
5. native/canonical/WORD32_REF 是不同输入运输协议；canonical 和 WORD32_REF 的功能通过不构成 NVIDIA 原始指令编码或所有 native 地址组合的验证。
