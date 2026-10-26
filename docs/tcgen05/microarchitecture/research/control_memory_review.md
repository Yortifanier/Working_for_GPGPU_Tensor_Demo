# tcgen05 控制与 TMEM 子系统微架构审查建议

日期：2026-10-26。负责人：agent3。状态：项目拟议，未实现或综合。第 1—10 节为成文前评议，主文最终只读审查与组织单位澄清见第 11 节。

本文不修改主微架构文档或既有 RTL。队列、bank、buffer、端口及仲裁数值均是本项目建议，不能称为 NVIDIA 已公开实现。规范边界以 [架构文档](../../TCGEN05_TENSOR_ARCHITECTURE.md)、[PTX 核查](../../research/ptx94_architecture_audit.md)和[来源审查](../../research/architecture_source_review.md)为准。

## 1. 已对齐的参数与审查结论

以下基线与主 agent 对齐：

| 项目 | 建议配置 | 边界 |
|---|---|---|
| endpoint / pair | 2 | 内部资源映射，不宣称 NVIDIA 的物理 SM 配对 |
| TMEM / endpoint | 576 列×128 rows×32 bit | 288 KiB raw；基础 profile 只暴露 512 列 |
| TMEM bank | 32×1R1W×32 bit | bank=lane[4:0]，row=4×column+lane[6:5] |
| resident CTA owner | 8 slots / pair | 执行环境预留 admission credit |
| issuer context | 32，动态分配 | 无活动引用时可回收 |
| per-issuer outstanding window | 8 | 必须限制未退休序号跨度，不能只数 active 数量 |
| async OpTable | 64 tokens | 不是 normalCQ 的另一种写法 |
| normalCQ / escapeCQ | 24 / 8 | 等待条件不得长期占 issue port |
| MMA tile contexts | 8 | 数值资源由独立数据通路方案提供 |
| CommitWait / eventQ | 8 / 16 | commit 接受时为将来通知预留 event credit |
| alloc waitQ | 8 | 阻塞申请脱离共享发射端口 |
| allocation records | 每 endpoint 18，pair 共 36 | 不人为限制每个 CTA 只能申请 4 块 |
| register load/store scoreboard | 64×160 bit | 独立于 MCS／A-read 完成窗口 |
| ARF 返回 staging | 8×128 B credits | streaming 最大合法片段，非全片段缓冲 |
| immutable A snapshots | 2×16 KiB | active 引用不受未来 reuse invalidate 破坏 |
| B opportunistic chunk cache | 4×8 KiB | 命中许可与源保持仍独立 |
| scale／metadata cache | 8 KiB | 不改变原生 TMEM 对象布局 |

**已解决的审查发现：**原先“18 个 allocation entries”若解释为整个双 endpoint pair 的唯一总数，会不足；现与主 agent 统一为每 endpoint 18 项、pair 共 36 项。8 个 CTA owner slots 不足以推导每 CTA 只允许少量 alloc，详见第 3 节反例。

## 2. TMEM 容量、bank 与 region lease

### 2.1 可逆物理映射

对合法坐标 lane=0..127、column=0..575：

    bank = lane & 31
    bank_row = 4 × column + (lane >> 5)

每 bank 2304×32 bit；32 banks 合计 288 KiB。pair 两端合计 576 KiB raw TMEM。该映射可逆，不会让同列不同 quarter 别名。

同一对齐 32-row quarter 的同列访问会分散至 32 banks；完整 128-row column 分四个 quarter 请求。每 endpoint 的原始读／写峰值各为 128 B/cycle，碰撞、布局、仲裁和依赖会降低实际值，不能直接换成 Tensor FLOPS。

1R1W 不代表同地址读写语义自动正确；建议同 cell 的冲突由 lease 排序，避免依赖 SRAM read-first/write-first 的默认行为。宏 padding、ECC 和外围面积不计入 raw 位数。

### 2.2 地址与返回身份

内部 bank packet 携带 endpoint、allocation_id、generation、op_id、cell 坐标、mask 及 return sink。更大架构 shape 分成 packet，但保持寄存器片段映射。TMEM lane 不能改称物理乘法 lane。

数据返回按原 op_id/generation 路由，不读取“当前 request 配置”解释延迟数据。allocation 被释放并重新使用后，旧 generation 的包不能写新 owner。

### 2.3 原子取得全部 ranges

region scoreboard 与主方案统一为 64 ops×8 ranges×64 bit=4 KiB，记录每个在途 op 的规范化范围、模式及 endpoint 掩码，generation 在对应 OpTable／allocation 引用中校验。新操作对已有 ranges 作重叠检测，读可共享、写冲突等待。

读可共享，写排他。MMA 对 D 为 read-modify-write lease，A／scale／sparse metadata／LUT 为读 lease；cp 对目的为写，shift 为完整参与区域的写 lease。

一笔操作原子取得所有 region，包括 CTA2 两端所需集合；失败时一项也不持有。读数据已经完整进入私有缓冲后，可释放相应读 lease，目的写 lease 保留到写提交。

先合并同一操作的自重叠 ranges，再由有序 coordinator 对两端一次 pre-reserve。8 个 slots 应表示规范化的 operand 包围范围，不能因合法 layout 的物理碎片超过 8 就拒绝合法指令；可按相同 allocation 的保守 hull 合并，接受假冲突代价，不能漏掉真实访问。

**反例：**操作 P 先锁 D 再等 A，操作 Q 先锁 A 再等 D，即使 bank 全空闲也死锁。不能用逐 operand 锁代替 try-all-or-none。

SMEM 版本记录是内部读取进度／debug 合同，不宣称能阻止任意普通 LSU store；软件仍须遵守 PTX 对源保持和 proxy 可见性的要求。

## 3. allocation、permit 与 pair 所有权

### 3.1 allocation table 容量不能制造伪资源不足

非exclusive 最小申请 32 列。基础 512 列 endpoint 可同时容纳 16 个独立申请；两端共 32 个。以下都是合法资源需求的候选：

1. CTA A 在 endpoint0 连续申请 16 次，每次 32 列；
2. CTA B 在 endpoint1 连续申请 16 次，每次 32 列；
3. 两者在全部申请成功后使用数据并逐项 dealloc。

若 pair 只有 18 个 descriptors，第 19 次 alloc 会因 metadata 满而阻塞；两端物理 TMEM 尚有可用空间，但程序可能不会提前 dealloc。这是实现限制制造的停顿环，不是必须由软件规避的 PTX 资源条件。

建议每 endpoint 18 项 allocator descriptors，每项 32 B，pair 共 1.125 KiB。pair allocation 可由一个共同 identity 引用两端记录；独立 CTA1 allocation 不得被强行合并成同一 owner。

### 3.2 bitmap 与 exclusive

每 endpoint 用 18 个 32-column granules。512 profile 只允许前 16 个，576 exclusive profile 才可暴露全部 18 个。分配器查连续空闲 run，非exclusive 可按尺寸进一步对齐；exclusive 可为非 2 幂的 32 列倍数。

exclusive grant 之前必须没有其他 live allocation，且在其存活时禁止其他申请，即使它没有占满全部列。dealloc 的 exclusive、nCols 和 generation 必须匹配，释放后 permit 才重新可用。

CTA permit 与 allocation 分开：relinquish 后不再允许 alloc，但不自动 free。按 CTA 执行顺序记录上次 nCols，检查后续申请不递增。[P1 PDF738—741]

### 3.3 CTA2 prepare → reserve → publish

收齐双方 warp 参与者和一致参数，执行 prepare；再对两端共同 base 的连续 chunks 做 reserve；只有双方都保留成功才 publish 地址。失败必须释放全部 provisional reservations 后再重试，不持一边等待另一边。

联合 allocation 保存 pair owner、两端引用数和共同 generation。dealloc 收齐双方参与者且两个引用数均为零后释放。peer 必须 active，不能由本端伪造到达。

### 3.4 owner admission 与等待队列

8 owner slots 必须在 CTA 允许发射本 endpoint 工作之前预留。若一个有效 CTA 已获执行但没有 owner slot，又需要先分配 TMEM 才能推进，不能把硬件上下文不足误说成软件死锁。

alloc 在资源不足时转 allocWaitQ8，不占 bank 或共享 issue port；新申请可回压，但 dealloc／completion 必须从 escape 路径继续前进。等候 exclusive 时可暂停更年轻 allocation grant，防止无限饥饿。

**反例：**alloc.exclusive 堵在单个 FIFO 队首，后面的 dealloc 负责释放旧申请。无论 FIFO 多深都不能解决，必须脱队等待并允许 release bypass。

## 4. normalCQ、escapeCQ 和 OpTable 的信用边界

normalCQ24 每项只存 16 B 指针／调度摘要；OpTable64 每项 256 B，共 16 KiB，含不超过 128 B 的 raw command 及进度、依赖和完成状态。一个在 CQ 等待的操作和一个已进入执行的操作可能都占 OpTable，但不能将 24 和 64 简单合并为同一个深度。

建议异步命令被 admission 时就保留 token 并分配 issuer sequence；否则越过它的 commit 可能遗漏尚在 CQ 的早先操作。管理／wait／commit 不必占数据 OpTable token，采用独立控制记录。

escapeCQ8 采用保留分区：4 项 commit、2 项 dealloc/permit、2 项 wait/fence。等待未满足时登记事件并让出共享 issue port；不能让一个 wait::ld 队首挡住后面释放该 ld 依赖的控制动作。某一分区占满不能借走其他释放类的最后保证信用。

8 个 MMA tile contexts 是 active 数量；其余 pending 操作可保存在 OpTable/CQ。新操作必须同时有 token、目标上下文、完整 range lease 与最终返回／写回 credit 才能发第一包。

### 4.1 event credit

接收 commit 时先取得 CommitWait8 条目和 eventQ16 的预留 slot。eventQ 应采用“已保留槽＋ready 列表”，不能让未完成 watermark 的占位 entry 把后面已就绪通知永远堵在物理 FIFO 头。

event 回包可被 mbarrier 服务反压，但不持 bank 或数据 lease。通知 records 保存 target mask 和 remaining-ack mask；multicast 对每目标 arrive-on(1) 恰好一次。

### 4.2 数据返回信用

主方案采用 8 个 128 B ARF 返回 credits，共 1 KiB，可 streaming 传回最大 16 KiB 的 x128 load；64×160 bit 的独立 ld/st scoreboard 约 1280 B。寄存器只在全部片段 ack 后标为 ready，不能把首片段返回当作整个 load 完成。

必须在启动前保留完整目的寄存器范围和返回路由身份；ARF 对 fragment 的接受不等待 wait::ld 或消费者指令 ready。每个 credit 在该 fragment 写入 ARF 并 ack 后归还，即使整个 load 尚未结束。

若 ARF sink 要等“整个 load 已完成”才 ack fragment，而 load 又在等待归还 credit 读取下一个 fragment，就会形成循环。bounded service 和返回路径的公平仲裁应作为明确环境合同，而非假设缓冲永远不满。

## 5. per-issuer full 与 A-read 两条序列

issuer identity 为 kernel generation、CTA、thread、CTA-group；不是只按 warp 编号。32 个动态 context，每项建议 64 B，约 2 KiB。

每 issuer 分开维护：

- MCS_seq：mma/cp/shift 的发射顺序，供 ordinary commit；
- MMA_seq：仅 MMA 的发射顺序，供 restricted A-read commit；
- 两类 completion prefix 与各自 8-bit done window。

commit snapshot 是该线程发射时之前的 watermark，不包括另一线程或未来命令。MCS window 的 admission 约束必须为 issued_seq−full_prefix≤8；A-read window 也不得覆盖仍有孔洞的旧 slot。仅限制“当前正在运算数≤8”不够，因为后完成的 token 退回后，序号跨度仍可能越过未完成老请求。

full_done 与 A_read_done 分开。A_read_done 只有在本 MMA 今后不可能再次读取其 SMEM A 时才能置位；第一次 collector fill、一次 tile A fetch 或“当前 cache 命中”都不充分。若后续 tile 可能 miss/reload，必须继续保持 A-read 未完成，或把全部还需的 A 保留于不会丢失的私有空间。

普通 full_done 要等数值、D 写回及所有被计入的两端副作用完成。restricted event 不释放 B、scale、metadata、LUT，也不允许读取 D。

CTA2 一笔操作只分配一个 parent token 与一次 thread-issued MCS／MMA 序号；peer 使用 child context，不伪造第二次线程发射。parent 的 full/A-read 分别累积两端 done masks，满足适用端点集合后才推进相应 prefix，避免一边先到而提前产生完成事件。

### 5.1 context 回收

当 context 无 outstanding、无 commit／event／依赖引用时可 evict；后续 commit 若确认该 issuer 没有 pending 工作，可立即安排 arrive。不能只因 full_prefix 追上就丢掉仍被 CommitWait 引用的 watermark identity。

operation 内部退休不等待软件发 commit，更不等待软件消费 barrier。已完成历史压缩进 prefix，token 可回收。

**反例：**64 个已完成操作仍占 token 等待 commit，issuer 无 token 提交 commit，系统永久等待。完成追踪不应依赖软件先消费。

### 5.2 ld/st wait 与 fence

ld/st 用独立的 warp collective 完成跟踪，不进入 MCS watermark。wait::ld/st 观察本线程之前的同类 load/store，不能替代 MMA full completion。

before/after_thread_sync 只建立适当跨线程顺序依赖，不直接置 full_done。SMEM generic/async proxy 可见性仍由对应外部 fence／producer 完成合同提供。

## 6. TMEM 操作与附加功能

### 6.1 ld/st

先收齐 warp 参与 mask 和一致 base，再形成 fragment map。st 的源寄存器范围在全部读取 ack 前保持有效，通过已保留的读路由 streaming；ld 先保留目的寄存器范围、返回路由和 fragment credit，再取读 lease。最后一个所需 TMEM 片段已取走后可释放 read lease，寄存器完成仍等全部片段写入 ack。

pack16/unpack16 是数据布局变换，不把它混为任意 FP 格式转换。load/store .sync.aligned 只保证参与，不保证异步数据已完成。

### 6.2 cp

SMEM 读取、可选 4/6→8 容器展开和 multicast 目的写包分别计数；全部目标写完才 full_done。验证 shape 与 warpx2/warpx4 的合法组合。cp 不自动变成 global→TMEM，也不替 TMA 完成其前置传输。

### 6.3 shift 与 ashift

建议每 endpoint 一份 1 KiB snapshot，覆盖一次 32-row×32 B 的窗口；先保存源，再把 row0..30 写往 row1..31。空出 row 的语义以 ISA 为准，不自行宣布清零。

最多每 endpoint 一个 active shift；其他 cp 可占独立 data-move context。CTA2 的完整完成是两端 snapshot/writeback 的合取。

直接按 row0→row1→row2 顺序边读边写会覆盖下一源，这是必须测试的反例。MMA 的 ashift 同样要把所有相关读写纳入该 operation 的 range 与 completion，不能伪装成无副作用地址更新。

### 6.4 reduction 与 spcompress

reduction 采用按 lane 保存的流式中间状态；spcompress 只在完整 2:4 group 收齐后选择元素并生成索引，不要求把整个 x128 input 存入 16 KiB gather buffer。输出沿相同 ARF fragment credit 路径传递。

spcompress 为 F32 保留 NaN、按 min/max/abs 选元素并产生 b2 metadata；ld.red.spcompress 的 .NaN 只作用于 reduction。cdata、mdata 和可选 reduction 的目标寄存器及返回身份都须在启动时保留，少量组缓存／metadata packing 暂存另计。

该 metadata 不能未经 layout/type 适配就当作任意 mma.sp metadata。若共享 comparator 可多周期处理，但不能先提交 cdata 后才发现 metadata 没有出口。

### 6.5 collector 与 LUT

主方案采用 2×16 KiB immutable A snapshot 与 4×8 KiB B opportunistic chunk cache；scale／metadata 另有 8 KiB cache。逻辑 collector identity 与物理 residency 分开，ws b0..b3 不等于必须有四块物理 bank。

cache tag 包括 owner/generation、source address/layout、format、K slice、side 与逻辑 collector epoch。fill/use/lastuse/discard 改变复用许可；use miss 仍可重读有效源，不能据 use 释放 source。

源修改／invalidate 只影响未来 reuse lookup，不能破坏 active operation 已引用的 immutable snapshot。若 A 与 D 合法别名，必须先完整 snapshot 本次需要的 A，再进行任何可能覆盖它的 D write。两个 snapshot 均占用时允许回压新的 A 版本，但不能先拿半套长期 lease 等 snapshot 释放。

LUT 建议缓存 16 个 slice，每 slice 8×8-bit 值，连 tags 约 512 B。SMEM B 的 3-bit index 与 TMEM LUT 读 lease 分别跟踪；A-read restricted event 不释放 LUT。

## 7. bank 仲裁与无死锁约束

每 endpoint 建议读／写请求 FIFO 各 8 项，response staging 为 8×128 B。先挑选已具备全部依赖和信用的 operation，再仲裁 bank packet。

优先级为已承诺写回／返回、活跃操作后续包、新读取。各类内部按 age 轮转；连续优先 grant 最多 8 次后向可执行老请求让出一次，避免长 MMA 饿死 ld。dealloc 和 notification metadata 不经过 bank 端口。

必须维持：

1. 先保留出口，再取得全套 leases，再发请求。
2. 长期锁不部分持有等待；两端也遵循同一规则。
3. 完成通知不等 bank，bank 写回不等软件 barrier 消费。
4. 每个被接受的 side effect 都有可完成的 token／credit。
5. op_id/generation 随全部返回传播，free 前引用归零。
6. 输出反压时数据、事件域与 target mask 稳定。

| 反例 | 失效 | 防线 |
|---|---|---|
| allocator 等待在共享 CQ 队首 | dealloc 无法发射 | allocWaitQ8 与 escape release |
| pair 各锁一侧 | 跨端 ABBA | prepare/reserve/publish、失败全撤 |
| ld 无 return credit 却持 read lease | st／MMA 循环等待 | 返回预留优先 |
| 首次 A cache fill 就发 restricted arrive | 后续 reload 读到覆写源 | 最后可能 SMEM A read 才置 done |
| multicast retry 重新发送已 ack 目标 | barrier 提前跨 phase | remaining-ack mask |
| window 只数 active，不限制序号跨度 | 完成孔洞被新 seq 覆盖 | prefix-distance≤8 |
| evict issuer 但还有 CommitWait 引用 | 通知归属丢失／误立即完成 | 引用归零才回收 |

## 8. reset/drain

完整 Tensor 的热复位不能照搬现有单 MALU“异步清 valid”做法，因为外部 SMEM 包、TMEM 写、peer 子操作或 mbarrier arrive 可能已不可撤销。

正常 drain 分阶段：

1. 同步接受管理请求，停止新工作类 alloc/mma/cp/shift。
2. 继续接收既有任务的 commit、wait、fence、结果 ld、dealloc 和 relinquish；继续消费全部返回／通知 ack。
3. 排空在途、缓冲、通知与引用，合作 owner 归还 allocation。
4. 两 endpoint 与外部接口都达到安全条件后提升 generation，清控制状态。

若第一步无差别停所有命令，软件可能永远不能发结果 ld／dealloc，正常 drain 会自己死锁。

不合作 kernel 或 peer 丢失只能升级执行环境的 kernel abort：撤销未开始事务，drain 已承诺副作用，等待两端／互连 ack 后隔离旧 generation。不能向被 abort kernel 伪造正常成功事件。只有覆盖整个相关 fabric 的 cold reset 才能直接丢弃全部在途请求。

这属于项目异常管理协议，不是 PTX 定义了任意 tcgen05 中途可恢复的 cancel 指令。

## 9. 原始资源预算

下表是 pair 的建议 raw storage，不含 ECC、宏 padding、数值阵列或布线：

| 项目 | 建议容量 | 预算 |
|---|---|---:|
| TMEM | 2×576×128×32 bit | 576 KiB |
| OpTable command/metadata | 64×256 B | 16 KiB |
| CQ pointers／控制 | normal24×16 B、escape8、allocWait8 | 约 1 KiB |
| CTA owner records | 8×64 B | 0.5 KiB |
| issuer contexts | 32×64 B | 2 KiB |
| MMA context metadata | 8×256 B | 2 KiB |
| CommitWait / events | 8×32 B +16×32 B | 0.75 KiB |
| allocation records | 建议 2×18×32 B | 1.125 KiB |
| region scoreboard | 64×8×64 bit | 4 KiB |
| ld/st scoreboard | 64×160 bit | 1.25 KiB |
| ARF fragment staging | 8×128 B | 1 KiB |
| shift snapshots | 2×1 KiB | 2 KiB |
| immutable A snapshots | 2×16 KiB | 32 KiB |
| B chunk data cache | 4×8 KiB | 32 KiB |
| scale／metadata cache | shared | 8 KiB |
| LUT data/tags | 16 slices | 约 0.5 KiB |
| bank response staging | 2×8×128 B | 2 KiB |

除 TMEM 的明确项合计约 106.125 KiB，request FIFO、cache tags、压缩 group 暂存、对齐与其他状态另加。每项是本项目预算，不是 PPA。allocation records 已按 pair 36 项预算，解决原先 pair 总计 18 项的进展反例。

本轮用独立小脚本枚举 128×576 个逻辑 cell，映射得到 73,728 个互异 bank/row 坐标；并重算每端 294,912 B、pair 576 KiB 及上述 106.125 KiB 小计。这仅验证地址公式的无别名与算术预算，不是 bank 仲裁、异步完成或无死锁验证。

## 10. 审查结论与验证建议

主参数中 queue／tokens 分层、独立 alloc wait、escape release、perissuer watermark 和全 range lease 的方向一致。allocation 容量已统一为 18/endpoint。主文仍须显式处理 8-entry completion window 距离、A-read 的“最后可能读取”、ARF streaming ack 和动态 context 引用回收，避免隐藏的合法程序停顿或过早完成。

建议将以下转成模型检查与 SVA：所有队列同时满；32个 issuer 与8深窗口孔洞；两端反向 region 集；8个 owner 多次最小 alloc；576 exclusive 与旧 nonexclusive 排空；多目标通知重试；最大 fragment 回包；collector miss；drain 期间只保留 release 指令；peer abort 与旧 generation 返回。

尚未执行这些验证，不能把本记录写成“已经证明无死锁”。它给出可验证的不变量、有限容量和反例，用于下一轮微架构冻结。

## 11. 对 26 章主微架构稿的最终只读审查

审查对象：[TCGEN05_TENSOR_MICROARCHITECTURE.md](../TCGEN05_TENSOR_MICROARCHITECTURE.md)。本轮只读审查控制、存储、队列、lease、credit 与生命周期，没有改主文、RTL 或 README；44 个 PERF dot contexts 和 3 个 finalizer 的算术预算由算术审查负责。

### 11.1 组织单位与已经一致的项目

主文已统一为“每 endpoint”资源表，两个 endpoint 才组成 pair。因此第 1—10 节早期 pair 级建议预算不是最终主文总量，不应直接与主文每 endpoint 的数字相加或比较。以主文第 1、22 节的组织单位为准：

| 检查项 | 主文当前值 | 结论 |
|---|---|---|
| TMEM bank / raw | 每 endpoint 32×1R1W×32 bit、2304 words/bank、288 KiB | 映射和容量可重算一致 |
| allocation records | 18/endpoint、36/pair | 解决最小 allocation 的 metadata 容量问题 |
| owner／warp 接入 | 8 CTA／64 warp slots，每 endpoint | 已写 core admission 联动 |
| OpTable | 64×256 B=16 KiB，每 endpoint | 与 CQ 指针存储分离 |
| Normal/Escape CQ | 24/8；escape=4 commit+2 free/permit+2 wait/fence | 分区与参数一致 |
| issuer | 32 个动态 contexts；两类独立序列、各 8-bit window | 已明确 prefix-distance，不只数 active |
| range | 64×8×64 bit=4 KiB | 允许保守 hull、自重叠合并及 pair 原子预留 |
| A/B/auxiliary | 每 endpoint 32/32/8 KiB | 与主文 immutable snapshot／chunk cache 用途一致 |
| register return | 8×128 B，完整目的预留，全部 ack 后 ready | 解决“ARF 等 wait”循环 |
| pair | issuing-thread parent+peer child，双 done mask | 不伪造 peer 线程发射序号 |

主文已经纳入 A-read≠full、opportunistic collector、A/D 别名先保存源、旧 epoch 隔离、allocation provisional rollback、Event Q 保留分区及外部公平假设。未发现 bank 映射错误、18/36 记录算错或 CQ/OpTable 被当作同一个深度。

### 11.2 需要主文补明的进度不变量

以下是文字合同中的具体遗漏，不是已经发现 RTL 错误：

#### C1：正常 drain 不能冻结仍需执行的工作

定位：主文第 20 节“停止新接收；停止新 tile 发射”。

若一个已接受 MMA 只完成部分 tile，停止其全部后续 tile 后，它永远不能产生 full_done；若软件尚未发结果 ld／dealloc，停止所有接收也会让 allocation 无法归还。

建议将 normal quiesce 明确为：

- 停止接收新的工作类命令；
- 继续推进已接受命令的所有剩余 tile、访存及写回；
- 继续接收已有 owner 的 commit、wait、fence、结果读取、dealloc 与 relinquish；
- drain 完毕才能清 epoch／owner；无法合作时升级 kernel abort，不能报正常完成。

若实际意图是停止 tile 并取消未执行部分，就应明确这是 abort，不是保证 kernel 正常完成的 drain。现有“按系统协议撤销”应引用一个具体 abort 分支，而不是同时保留两种不相容解释。

#### C2：Escape admission 不得要求新 MCS/window 槽

定位：主文第 4 节 S0 ACCEPT 的通用条件。

该表目前把 CQ、OpTable、issuer/window 一并列为接收条件。建议注记：它是普通异步命令的条件；commit/dealloc/wait/fence 使用自己的保留入口／控制表，不能因不存在“新的 MCS 序号槽”而被窗满挡住。

同样，阻塞 wait 应登记完成条件后释放共享 issue 端口，不能在 escape 分区中长期占住唯一发射资源。未使用的普通数据 token 不是这些释放控制前进的先决条件。

#### C3：sequence assignment 与 commit snapshot 要处于同一顺序点

定位：主文第 3、4、17 节。

建议明确 MCS/MMA 序号在 per-issuer 有序 admission 点分配，commit 在相同顺序点捕获此前水位，再允许不同 CQ／功能引擎重排。

反例 A：旧 MMA 已进入 Normal CQ，但到执行时才分序号；commit 从 Escape CQ 越过它并读当前 issued，会漏掉旧 MMA。

反例 B：commit 入队时没有捕获水位，等真正运行时再读当前 issued；中间进入的新 MMA 会错误延长该 commit 的等待集合。

主文已经说“后发命令不能延长快照”，但还需要把快照点落实到前端，以阻止上述两种调度解释。非法命令若已占序号，也应按项目错误处理关闭该槽，不留永久完成孔洞。

#### C4：ld/st 也需有明确的 window admission

定位：主文第 17.3 节每 warp 160 bit issued/prefix/window。

该预算可容纳两条独立 issued/prefix 和各 8-bit window，但应明确新 ld／st 的相应 issued−prefix 必须小于 8，并与 warp generation 匹配。不能让一个 warp 利用 global OpTable64 连发 64 个操作，却只有 8 位完成窗口可记录。

真实数据依赖自动等待与 wait::ld/st 的 memory ordering 是两回事，现有主文区分正确，应保持。

#### C5：token retirement 不得等待软件先发 commit

定位：主文第 3、17、19 节。

已有“OpTable 本地 done-bit 不依赖 Event Q”是必要条件，建议进一步明确：full 完成历史压入 prefix 后，数据 token 可以退休，不等软件发 commit 或消费 barrier。未完成通知自己的引用应保存在已预留的 CommitWait／event metadata。

反例：64 个已完成操作占满 OpTable 等 commit，而 commit admission 又要求一个普通 token，形成与存储无关的纯控制等待。C2 与 C5 共同关闭这个环。

### 11.3 存储预算需要说明“完整记录还是指针”

主文第 22 节 Event Q 为 16×16 B。若该 entry 是完整通知，单 barrier address64、target mask32、水位32、remaining-ack mask32 就已超过 128 bit，还未计 event ID／owner generation。

16 B 可以作为索引／路由摘要，前提是：

1. commit 的完整 metadata 保持在 8×32 B CommitWait，直到外部 ack；
2. peer 控制完整记录留在 peer bridge；
3. release／diagnostic 完整记录有独立稳定来源；
4. Event Q 仅持 generation-checked pointer，来源在 ack 前不得回收。

若意图把全部 metadata 移入 Event Q，则应增大 entry（例如 32 B）并更新预算；本审查不要求一概加深队列，只要求记录生命周期和位数自洽。

同理，region 的 64-bit range 可将 allocation generation 通过 OpTable 的稳定引用间接关联，不必在每个 range 冗余存完所有身份；主文应写清这些字段从哪份不可变对象读取。

### 11.4 发射预约的最后一致性建议

主文 S3 取得 lease，S4 才显示 tile context／后端预算可用。建议写清：可能长期占用的 snapshot、child、tile/closure/result credit 要么在 S3 一并预约，要么证明 S3 等 S4 时不会占住活跃操作完成所需资源。

不能把 S0 的“必要 credit”当作无限包罗但未定义的承诺。最小可执行合同应逐类列：普通 MMA、move、commit、free 分别保留哪些信用、在哪个 ack 归还。主文第 16 节已有接口归还点，是良好基础。

### 11.5 本轮结论

控制／存储总体参数和容量核算一致，主要需要关闭 C1—C5 的文字合同，并明确 Event Q 的 metadata 来源和 S3/S4 预约边界。上述建议已经发送主 agent；本文件没有自行替换主文。

这份审查没有运行新 Tensor RTL 或形式模型，不把文档审阅称为无死锁证明。此前 MALU 的主回归和 decoder 记录仍只属于 REF 单元。

## 12. 修订后的快速只读复核结论

主 agent 合并修订后，再次只读核对主文第 4、8、17、19、20、22 节，未修改正文或扩大本轮审查范围。

| 初审项 | 已见的实际修订 | 复核状态 |
|---|---|---|
| C1 soft drain | 明确继续当前 kernel 必需命令和已接受操作剩余 tiles；abort 取消另立协议 | 文档问题已关闭 |
| C2 escape admission | S0 区分普通异步与 escape；commit/wait/fence/dealloc 不要求普通 MCS 窗口或异步 OpTable 空项 | 文档问题已关闭 |
| C3 同一顺序点 | per-issuer S0 分 seq／捕获 cutoff；core dynamic ticket 禁止后到 escape 越过旧未接收命令 | 文档问题已关闭 |
| C4 ld/st 窗口 | 每条 stream 显式 issued−prefix<8，并核对 warp generation | 文档问题已关闭 |
| C5 token 退休 | full 历史进入 prefix、引用归零后可退休，不等未来 commit；通知 metadata 独立保留 | 文档问题已关闭 |
| Event metadata | 16 B 仅指针；完整信息在 CommitWait／peer／4×32 B 诊断记录，ack 前不回收 | 文档问题已关闭 |
| S3/S4 预约 | S3 一次保留 tile、snapshot、child、最低返回／写回预算，S4 仅填写已有计划 | 文档问题已关闭 |
| 超过 8 allocations | endpoint 18-bit pin mask、generation 引用及 endpoint-wide coarse lease；无权间隙仍拒绝 | 有明确 slow-path，不因范围槽不足静默漏查 |

另已核对序号按有界模运算比较，CommitWait 达到 watermark 后锁存 ready；新命令推进／回绕不会撤销已经满足的事件。SMEM-A MMA 的 A-read stream 与 TMEM-A 情形分开，peer 不制造第二个 thread-issued sequence。

本轮控制／存储文字合同已经覆盖所提反例，未发现仍需阻止本版文档成文的确定问题。此结论限于设计审阅；尚未做新 Tensor RTL、形式证明或工艺实现，不能据此声明整体无死锁验证通过。
