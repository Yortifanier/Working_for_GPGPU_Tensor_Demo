# SM 架构完整性与既有设计集成审查

日期：2026-11-01（UTC）。负责人：agent3。状态：独立文档审查及主文建议，尚未审阅本轮 SM 主文；本记录不新增功能 RTL，不提交或推送 Git。

## 1. 依据、范围与结论边界

本轮实际阅读了以下资料：

- 用户上传 PTX ISA Release 9.4（2026-07-17）的本地文本，核对第 3、5、9、10 章及指令家族入口；原件 SHA-256 为 4be2905e240b70a8b176b4d6fb162714f2fc361a9503572d848ff723abf289c3。
- [tcgen05 Tensor 架构 v1.0](../../tcgen05/TCGEN05_TENSOR_ARCHITECTURE.md)、[微架构 v1.1](../../tcgen05/microarchitecture/TCGEN05_TENSOR_MICROARCHITECTURE.md)，以及 SMEM、控制/存储的最终关闭记录。
- [MALU RTL 实现说明](../../malu/RTL_IMPLEMENTATION.md)及其资源、接口、能力和验证边界。
- 既有 NVIDIA 网页快照的来源审查；本轮 public_source_evidence.json 中各次在线请求记录为 403，不能将历史快照表述为 11 月 1 日重新联网取证成功。

全文的容量、映射和资源组织若来自既有微架构，均标为项目拟议配置；PTX 描述的是虚拟 ISA 和程序可观察语义，不能从助记符、矩阵 shape 或参与线程数推导 NVIDIA 的物理 lane、流水、乘法器或端口数量。

本轮最重要的集成结论：SM 文档应明确 core/SM/endpoint 的映射，建立线程—warp—CTA—cluster 的独立状态层次，并把通用执行、通用访存、共享存储、Tensor 与异步服务完整纳入。当前真实可运行成果仍是 PROJECT_EXACT MALU 单元；它不是整个 SM 或完整 tcgen05 的实现证据。

## 2. 必须先冻结的组织单位

### 2.1 推荐的项目映射

建议主文显式选择：**本项目 core 指一个 SM；一个 SM 集成一个 Tensor endpoint；两个 endpoint 经 SM 间 peer 服务执行已合法匹配的 CTA-pair 操作。**这是本轮建议的新集成约定，不是 PTX 或既有文档已经证明的 NVIDIA 实现关系。

如果主文选择一个 SM 内有多个 endpoint，也可成立，但必须同步重定义 8 CTA owner、64 warp slot、SMEM 单一物理池和 endpoint owner 映射，不能让每个 endpoint 各自以为拥有同一组全部信用。下表按推荐的一个 endpoint/SM 解释。

| 术语 | 项目职责 | 不能等同的对象 |
|---|---|---|
| device/SoC | grid/cluster 分派、全局地址与缓存一致性、外存、跨 SM 和系统/Fabric 服务 | 一个 SM 内的 warp scheduler |
| SM/core | 接收 CTA，保存线程与寄存器状态，调度执行，拥有本地共享存储与完成责任 | 单个 SP lane、单个 Tensor/MALU |
| Tensor endpoint | SM 的矩阵命令、TMEM 和 Tensor 完成域 | 整个 SM、全部算术指令后端 |
| CTA owner | 一个驻留 CTA 的 launch 与资源归属 | 一份独立复制的全部 SMEM/TMEM |
| warp | 32 threads 的架构组织及相应 collective 参与集合 | 固定同 PC、同等待条件的不可分对象 |
| thread | PC、调用状态、寄存器/谓词/CC、退出与依赖的语义主体 | 32 套独立物理发射端口 |
| cluster | 多 CTA 的协作、DSM 和 cluster 同步范围 | tcgen05 rank 最低位配对或某个固定物理 SM pair |

PTX §3.1（PDF31/印19）说明同一 thread block 的线程在同一 multiprocessor 执行；§3.2（PDF33/印21）说明 ITS 保存 per-thread PC 与 call stack，由调度机制组合兼容的 active threads 进行 SIMT 执行。这支持状态分层，不支持“每 thread 各一套取指/发射流水”的推论。

### 2.2 容量与 admission 的继承规则

| 既有量 | 本轮集成解释 | 必须避免的错误 |
|---|---|---|
| 最多 8 CTA owners / endpoint | 推荐映射下最多 8 resident CTA slots / SM | 保证同时驻留 8 个最大资源 CTA |
| 64 warp slots / endpoint | 推荐映射下 64 warp slots / SM，即最多 2048 个已分配线程槽 | 直接宣布任一 target 支持相同 residency，或把 64 warp 写成 64 scheduler |
| 32 active Tensor issuer contexts | 有界异步追踪工作集，可空闲回收 | 将其当作 SM 只能有 32 个发射线程或 32 个驻留 warps |
| 8 MMA tile contexts、64 OpTable tokens | Tensor 的内部生命周期预算 | SM 的通用指令窗口、全部线程数或 RF 容量 |
| paired CTA | cluster 内指定 rank 配对与双方存活 | 两个任意 CTA、任意 DSM 目标，或任意两个已经驻留的 SM |

CTA admission 必须联合检查线程/warp、CTA slot、RF 预算、static+dynamic SMEM、实现支持的 barrier/launch 元数据与必要的 cluster 资源。对需要协同驻留的 cluster，device/cluster admission 应预留完整组的可执行资源，避免 CTA0 先占满资源而 CTA1 永远无法 launch。Tensor 的运行时 TMEM 分配仍是独立的资源步骤。

## 3. SM 文档建议纲要

以下是架构文档纲要，不要求增加内部流水级、队列深度或 RF bank 等微架构决策。

| 章 | 必须回答的架构问题 | 主要产物 |
|---:|---|---|
| 1 | 什么是本文的 SM，证据、目标 capability、实现状态分别是什么？ | 范围和版本维度表 |
| 2 | SM 与 SoC、cluster、Tensor endpoint、MALU 如何分工？ | 顶层职责和接口图 |
| 3 | 所有 PTX 指令与非指令对象如何查验？ | 全量覆盖账本、类型/修饰符/target 检查规则 |
| 4 | kernel、CTA、warp、thread 如何建立、运行和退出？ | 分层状态及所有权表 |
| 5 | 取指、分支、谓词、ITS、call/return、collective 如何交互？ | 活跃集合与控制流契约 |
| 6 | 寄存器、谓词、隐式 CC、特殊寄存器和动态寄存器分配如何表示？ | 可见状态与保存责任 |
| 7 | scheduler、collector、依赖追踪与回写提供什么保证？ | 发射资格、源捕获、结果发布边界 |
| 8 | SALU/VALU、整型、F32/F64、半精度/packed/alternate、SFU 如何覆盖？ | 运算域、精度、近似误差与 capability |
| 9 | 通用 load/store、地址空间、转换、atomic/red/multimem 如何执行？ | 访存与内存模型责任表 |
| 10 | SMEM 的 launch 归属与 LSU/TMA/Tensor/DSM/barrier 访问如何一致？ | 容量、地址、共享服务和顺序契约 |
| 11 | cp.async、bulk/tensor TMA、tensor-map、Fabric 如何分工？ | 数据移动及外部服务边界 |
| 12 | texture/sampler、surface 与常量访问提供何种完整功能？ | opaque 对象、过滤/寻址、访存返回 |
| 13 | warp/CTA/cluster 同步、mbarrier、fence/proxy 如何组合？ | 分离的完成与可见性域 |
| 14 | legacy WMMA/MMA、WGMMA、tcgen05 如何共存或明确禁用？ | 各家族参与者、存储与完成接口 |
| 15 | Tensor/TMEM/MALU 如何接入 SM，哪些是原生能力或项目扩展？ | 已有文档的有界引用 |
| 16 | debug/trap、时钟/计数器、grid 依赖、stack、系统服务由谁负责？ | SM/运行时/SoC 责任矩阵 |
| 17 | SM 与 LSU、RF、Tensor、TMA、cluster、SoC 的接口保证是什么？ | identity、generation、ordering、completion 合同 |
| 18 | CTA exit、drain、abort、reset、抢占状态如何处理？ | 正常完成与取消协议 |
| 19 | 吞吐/occupancy/共享带宽如何测量，哪些参数尚未冻结？ | 可观察计数和限制 |
| 20 | 哪些功能已经实现，哪些拟议，如何分阶段验证？ | 能力/证据矩阵和验收清单 |

主文可合并章节，但应保留上述职责。尤其不要只放一个“其他指令”表来代替 texture/surface、Fabric、stack 或动态寄存器分配的状态和接口。

## 4. 所有指令的完整性检查方法

### 4.1 逐条账本的最低字段

完整性应从上传原件的第 9 章每个正式指令条目起步，而不是从既有模块名反推指令列表。每条记录至少包含：规范节号、正式名称/助记符、物理页/印刷页、类型/packing、关键修饰符、参与者/地址空间、target、执行责任、完成/顺序、项目状态、证据链接。

建议状态分为：已有且测试过的 RTL、拟议原生功能、需要有语义保证的编译 lowering、外部/SoC 服务、因 target 或实现范围关闭、尚未决策。编译 lowering 不能仅写“可拆分”：应列出精度/舍入、原子性、scope/proxy、collective 参与和错误行为是否等价。关闭能力需明确诊断/拒绝入口；不能静默当作 no-op。

第 9 章 formal entries、独立 mnemonic、语法 alternatives 和实际目标 opcode 是不同计数。相同 add 出现在整数、浮点和 packed 家族并不构成重复遗漏；反过来只清点唯一字符串 add 会丢掉大量独立语义。控制流条目中的花括号和 @ 属语法/谓词结构，也不能据其标题数推出硬件 opcode 数。

专门清点 agent 已报告：217 个说明叶子与 217 个 Syntax 块对应，其中包含花括号和 @ 两个控制语法条目。该计数是逐条账本的统计，不能改写为 217 个独立硬件 opcode。本记录未重复全部 Syntax 清点。主文还应点名 st.bulk、applypriority.async.bulk/.tensor、spcompress/spdecompress、Fabric 六类操作、legacy shfl/vote 以及 ldmatrix/stmatrix/movmatrix，避免只沿大写标题或 Tensor 目录搜索造成遗漏。9.4 的 packed alternate/mixed 算术仍属寄存器 ALU 语义，各形式 target 不能合并为一个能力开关。

### 4.2 独立核对的 21 个一级指令家族

下表的起始物理页已从本地 PTX 全文逐页定位；这是主文查全的索引，不替代 agent1 的逐条指令账本。

| PTX 节 | 家族起始 PDF 页 | 应映射的 SM/系统职责 | 容易漏掉的语义 |
|---|---:|---|---|
| 9.7.1 | 141 | 整型执行/编译 lowering | wide/hi、饱和、bit 操作、dp2a/dp4a，不是 tcgen05 |
| 9.7.2 | 174 | 每 thread 隐式 CC 与扩展整型 | carry/borrow 依赖，不是通用 NZCV 标志 |
| 9.7.3 | 181 | F32/F64、比较分类、SFU 或精确后端 | rounded 与 approx、FTZ、特殊值和误差界分别检查 |
| 9.7.4 | 220 | F16/BF16 和 packed 浮点 | 一寄存器多元素、逐元素 predicate/result |
| 9.7.5 | 240 | mixed precision 算术 | 输入提升、目的精度、单次舍入及 9.4 新形式 |
| 9.7.6 | 247 | alternate FP8/FP6/FP4 算术 | 不能因 MALU 会 dot 就声称 scalar/packed add/mul/fma 已实现 |
| 9.7.7 | 257 | 比较/选择、谓词写入 | ordered/unordered、双谓词、选择不等于分支 |
| 9.7.8 | 264 | 半精度比较 | packed 语义、多个谓词责任 |
| 9.7.9 | 269 | bit/predicate/shift | lop3、funnel shift、超宽 shift 行为 |
| 9.7.10 | 280 | RF/cross-lane、转换、地址、LSU、异步复制 | cvt 与位重排不同；包含 sparsity 压缩/解压等新形式 |
| 9.7.11 | 396 | SM Fabric 前端与 SoC 传输服务 | CFT handle、可报告失败、独立完成/等待，不是普通 pointer LSU |
| 9.7.12 | 409 | texture/sampler 访问与查询 | 寻址、过滤、LOD/梯度、opaque handles 与 target |
| 9.7.13 | 423 | surface load/store/reduction/query | 边界模式、原子/归约、像素与字节寻址区别 |
| 9.7.14 | 431 | 分支、call/return、thread exit | per-thread 控制、谓词与编译 scope 结构 |
| 9.7.15 | 439 | warp/CTA/cluster 协作及全局同步服务 | atom/red、multimem、griddepcontrol、mbarrier 等不同完成域 |
| 9.7.16 | 505 | warp-level matrix 与矩阵寄存器移动 | WMMA/MMA/SP、ldmatrix/stmatrix/movmatrix，不被 tcgen05 自动覆盖 |
| 9.7.17 | 645 | WGMMA 独立集成或 target 关闭 | warpgroup 参与、wgmma fence/commit_group/wait_group |
| 9.7.18 | 699 | tcgen05 Tensor endpoint | 单 thread 发射与 warp collective 混合；TMEM 独立于 SMEM |
| 9.7.19 | 847 | 每 thread stack/ABI | stacksave/restore、alloca，不能从 CTA SMEM 池分配 |
| 9.7.20 | 851 | packed integer/video 执行或 lowering | byte/half extraction、clamp、secondary op、merge |
| 9.7.21 | 868 | debug/sleep/计数/寄存器资源服务 | setmaxnreg 是动态资源协议，trap 不是普通算术结果 |

### 4.3 指令之外仍需纳入架构的内容

第 10 章特殊寄存器至少覆盖 thread/warp/CTA/SM/cluster 标识、lane masks、clock/PM/globaltimer、launch SMEM 尺寸、graph 环境、per-CTA global 切片。第 11 章版本/target、entry/ABI、launch/cluster/performance directives 是编译与运行时合同，不应虚构为 SM 的独立指令流水。

9.4 的 %perctamemoryoffset 与 %perctamemorysize 见 PDF906–907/印894–895，必须与 .minperctamemory 及 Driver 支持一起解释。它们描述 **per-CTA global memory**，不是 SMEM、local stack 或 TMEM。%perctamemorysize 在不支持分配的 Driver 上可为 0；不能只因有一个 special-register ID 就声明设备运行时服务已完成。

## 5. 可观察状态与依赖层次

| 层次 | 必须表示的状态 | 主要消费者/生命周期 |
|---|---|---|
| kernel/dispatch | entry、target/capability、参数/常量环境、grid/cluster 形状、epoch | device launch 到整个 kernel drain |
| cluster | CTA rank→SM/owner 映射、协同 admission、cluster barrier 与 DSM 在途引用 | 最后 CTA/远端引用退出前有效 |
| CTA | identity/generation、threads/warps、SMEM base/visible size、RF 分配预算、barrier 与 Tensor owner | 所有用户和异步责任关闭后回收 |
| warp | member/exited masks、动态 collective instance、warp-level 等待和动态 RF ownership | 不以 PC 单独识别一轮 collective |
| thread | PC、call/stack、通用寄存器、谓词、隐式 CC、活跃/等待/退出、程序顺序 ticket | 可独立让出执行，不丢失其数据/控制状态 |
| register/result | 目的寄存器依赖、部分返回进度、producer identity/generation | 最后片段 ack 后发布完整 ready |
| async stream | 指令家族自己的 issued/cutoff/completion、owner 引用、错误/取消 | 完成释放与随后 commit/wait 追踪分离 |

PTX 的虚拟寄存器名和位宽不是物理 RF 端口/容量规格。64-bit 值、packed 元素和 predicate 需要相应语义，但是否映射为一或多个物理条目留到微架构。local/stack 空间是每 thread 的 device-memory 状态，不因其名称 local 就从 SMEM 分配。

PTX §9.7.2（PDF174/印162）规定 CC 仅有 carry flag，只有列出的 extended arithmetic 访问，不能读取/测试/任意设清，且不保证跨 call 保存。架构不能漏掉每 thread CC 的隐式依赖，也不能扩写成 PTX 要求通用条件码寄存器。

setmaxnreg 见 PDF872–874/印860–862：CTA 内寄存器池、warp 所有权调整、inc 资源等待与 warpgroup 一致参与分别处理。即使暂不支持，也需在能力表关闭，而不是把动态请求简单当作普通寄存器写。资源等待不能占住其他 warp 执行 dec 或完成返回的唯一进度通道。

## 6. 调度、collector 与 scoreboard 的架构合同

SM scheduler 选择满足控制流、输入依赖、参与者和目的服务接收条件的 active group。ITS 不要求为每 thread 设置独立物理取指器，也不允许因 warp 中某个 thread 等待就永远阻止同 warp 中能够提供其解除条件的 thread。

SALU/VALU 是项目执行分类。能证明数据与控制 uniform 时可以选择共享的 SALU 路径，但 .uni 标记的是相应控制流的非分歧保证，不能单独据此假定所有源寄存器都是 uniform 或建立一套 PTX 规定的 uniform RF。标量 PTX 算术仍是每 thread 的语义。

必须区分四类追踪：

1. **寄存器 scoreboard**：真实源/目的数据依赖、隐式 CC、谓词、分片写回完整性。
2. **collective 参与追踪**：正确 member mask 与动态指令实例；不能只按 PC 汇合两轮循环。
3. **memory/proxy 顺序追踪**：scope、release/acquire、fence cutoff、SMEM 实际提交和失效应用。
4. **异步家族完成追踪**：cp.async、bulk/TMA、WGMMA、tcgen05、Fabric 等各有自身定义。

一个“warp busy”位不足以表达这些责任。寄存器 ready 可以自动阻止不完整结果被读取，但不自动为无关访存建立 proxy 顺序；相反，合法异步发射后线程可以继续执行不依赖其结果的指令，不应无条件等待整个 Tensor endpoint 变空。

SM 普通 register operand collector 和 Tensor A/B collector 也不同。前者负责捕获本条指令源值，后者可能跨矩阵命令复用 SMEM/TMEM 数据版本。源寄存器在成功捕获后可按依赖规则重用；Tensor cache fill/use 不能成为提前覆盖原 SMEM 输入的许可。

## 7. 两套片上存储及已有预算的一致继承

### 7.1 必须保持的分界

| 存储 | 项目容量及归属 | 接口/语义边界 |
|---|---|---|
| core shared SMEM | 每 SM/endpoint 256 KiB 有效数据，所有 resident CTA 共享池 | launch 分配；generic LSU、TMA、Tensor、DSM、barrier 同一字节对象 |
| Tensor TMEM | 每 endpoint 288 KiB physical，512-column profile 使用 256 KiB | 128 lanes×576/512 columns×32 bit；运行时 allocation 与 permit |
| RF/predicate/CC | 容量另定；每 thread 语义与 CTA 资源分配 | 不重复统计为 A/B snapshot 或 TMEM |
| Tensor A/B/aux | 32/32/8 KiB 的项目缓存/snapshot | 非新增软件 shared 地址空间，仍受原对象版本/引用保护 |
| L1/texture/constant cache | 项目结构与容量尚待主文决定 | 不从 256 KiB SMEM 中暗扣，也不将缓存容量算作 CTA 可用 SMEM |

不能将 256+288=544 KiB 作为一个 CTA 的 shared memory，也不能把 8 CTA 写成 8×256 KiB SMEM 或 8×288 KiB TMEM。项目物理池大小也不直接决定声明 target 的软件上限；PTX §5.1.7（PDF52/印40）的架构专属 target 容量表对 sm_100a/103a/107a/110a 给出 228 KB，需要保留该目标/ABI 约束。

### 7.2 SMEM 服务端信用不得在 SM 集成时丢失

现有 v1.1 服务端 ReqQ 为 Tensor16×128 B、LSU/TMA/peer 各8×256 B、control8×64 B。所有 packet 的数据至多128 B；更宽 LSU 操作拆分，不能把任意32-thread地址向量和256 B写数据免费塞进256 B记录。

RAS 为64×256 B data＋64×32 B metadata，固定 credits Tensor32、LSU8、TMA8、peer8、control8，总计64。它与 Tensor 客户端32tags、8×128 B return staging 是不同层。移到 SM 顶层资源表时应各统计一次，不能把两套响应责任合为8项，也不能重复加同一份 staging。

同一套64×32-bit 1R1W SMEM banks 的无冲突上界是256 B/cycle读和256 B/cycle写。Tensor2×128 B读若占满全部 R ports，LSU/TMA/DSM/barrier 不再有额外免费读峰值。TMEM32banks的128 B R＋128 B W是另一资源，不是SMEM额外端口。

### 7.3 从 v1.1 已关闭问题必须继承的顺序

- SMEM store bank-commit、collector 实际失效、proxy publish 分开；collector ack 必须在 future lookup 已能观察失效之后，不能仅 FIFO 接受。
- A-read 只关闭相关原 SMEM A 读取义务，不能释放 B、D、normal full token 或整个 CTA shared allocation。
- mbarrier 是 SMEM 内8B aligned opaque b64对象；Tensor Event→barrier agent→对象原子更新落地→ack，不只是一条 Event Q done bit。
- optional ECC scrub 取得 RMW锁后重新读当前word并重验ECC；不能迟到写回旧 cached corrected value。CTA exit 取消未开始的可选scrub，已开始的RMW仍drain。
- CTA shared owner 直到 LSU/TMA/Tensor/DSM/RMW/returns/barrier/visibility 全部责任关闭才能回收，旧generation不得写入新owner。

## 8. 执行域与全指令集成风险

| 执行域 | SM 架构应承诺的内容 | 与已有 MALU 的关系 |
|---|---|---|
| SALU/VALU 整数 | 每 thread 数学语义、packed/bit/CC/compare、地址生成 | 既有 int dot 不是普通 add/div/shift 执行管线 |
| F32/F64 | add/mul/fma/div/sqrt/convert 等逐条能力与舍入/特殊值 | MALU 支持 F64 dot 不证明 SM 通用 F64 已实现 |
| half/mixed/alternate | F16/BF16/FP8/6/4 的逐条类型和 packing | 不把矩阵合法类型自动推广到所有 scalar/packed 指令 |
| SFU/approx | 指令约束的误差、范围与FTZ；不能替代要求精确的运算 | 外置功能，无现有MALU RTL实现证据 |
| legacy matrix | WMMA/MMA/SP、矩阵寄存器移动，独立fragment与参与者 | 可适配相同数学后端，但前端和数值契约另验 |
| WGMMA | warpgroup与async-group接口；按target启闭 | tcgen05 commit不能替代wgmma.commit_group |
| tcgen05 | TMEM、kind/shape/layout、scale/sparse、CTA group、完成域 | Tensor前端仍拟议；MALU只承担dot+C数值子任务 |
| LSU/atomic/red | 所有地址空间、scope、order、宽度、返回责任 | 32bit数值adder不等于已实现128bitCAS或系统atomic |
| texture/surface | opaque对象、寻址/过滤/边界/查询及返回 | 不可仅画一条global load线后声明覆盖 |
| async/TMA/Fabric | typed request、owner、完成/错误、SoC服务边界 | TMA不是tcgen05.cp，Fabric handle不是SMEM地址 |
| stack/system/debug | per-thread ABI、sleep/trap、PM、动态寄存器、grid依赖 | 不放入MALU或TMEM allocator |

对未实现的 texture/filter、Fabric传输、legacy matrix等，可以在项目能力表明确关闭；这仍是完整架构审视。相反“已列名称，因此全部支持”不成立。

## 9. SM 接口最低合同与完成域

所有跨服务异步接口应能唯一定位kernel epoch、CTA slot/generation、warp/thread或collective instance、operation token/generation及返回片段；不要求全部字段逐位出现在同一根总线，但必须有稳定的被引用上下文。

| 接口/事件 | 接受时必须转移的责任 | 可观察完成不能提前为 |
|---|---|---|
| device→CTA admission | 全套launch资源与身份/参数 | 只分到CTA slot、SMEM/RF还无着落 |
| scheduler→执行域 | 固化operation、active mask、源值或源保护 | 某个源只读了一半就允许覆写 |
| LSU/Tensor→RF | 目的范围/写回route与fragment责任 | 第一fragment到达就整体ready |
| TMA→SMEM | producer/segment、owner、payload与bytes责任 | DMA命令发出即complete_tx |
| core→Tensor | 有序issuer ticket、不可变描述符、owner/capability | commit越过更早尚未admit的MMA |
| Tensor→SMEM/collector | 原源读引用、版本/失效确认、返回信用 | 请求入队即A-read或proxy可见 |
| Tensor→barrier | exactly-once事件及stable metadata | event入FIFO就视为mbarrier对象已更新 |
| SM→DSM/Fabric/SoC | 目标/资源handle、scope、response/error责任 | 统一当作本地一拍load/store |
| CTA exit→资源回收 | 全部本地/远端引用的drain或取消确认 | 最后一个thread exit就立即重用SMEM/CTA slot |

必须分别描述：普通指令结果可读、warp collective完成、CTA/cluster到达、SMEM对相应proxy可见、cp.async group完成、bulk/TMA事务完成、WGMMA group完成、tcgen05 MCS full、restricted A-read、tcgen05 ld/st、Fabric完成以及系统可见性。不能用统一done bit赋予超出规范的全部顺序。

## 10. 面向主文的反例与验收建议

| 反例 | 错误后果 | 架构必须给出的打断条件 |
|---|---|---|
| 8CTA各申请64KiB，却都因有8slots而launch | 超配256KiB SMEM或越权别名 | 联合admission和单一池预算 |
| CTA0占满资源后等尚未launch的cluster peer | 软件合法协作永远无进度 | device/cluster协同资源保证 |
| same-warp某thread等锁，整个warp被永久停住 | 能解锁的另一thread无法执行 | ITS active-group的可前进调度 |
| 两轮循环同PC的collective被合并 | 跨动态实例错配参与者和数据 | dynamic instance＋member验证 |
| F64 scalar操作送现有dot核且默认逐次相同舍入 | 外部语义、时序、ISA支持均错 | 独立scalar能力或经证明lowering |
| source register在Tensor命令接收前被后写覆盖 | idesc或地址中途改变 | admission时源捕获/保护 |
| Tensor窗口满时普通CQ阻塞commit | 无法关闭已有异步责任 | 保留escape路径，不依赖普通MCS/OpTable槽 |
| 所有SMEM RAS被数据借空，barrier更新也等slot | 消费者与完成事件环等 | 固定control信用与可推进sink |
| Tensorload首个fragment返回就取消整目的寄存器保护 | 部分新值/旧值混合 | 全fragment ack后ready |
| A-read后回收整个shared slice | 后续B miss或barrier引用访问新owner | 独立引用和full/owner生命周期 |
| CTA退出只看本地warp而不看旧DSM/TMA callback | 迟到写破坏下一CTA | generation＋系统drain/cancel |
| .uni被当成所有数据uniform的证明 | SALU广播错误结果 | 独立数据uniform证明与退化路径 |
| perctamemoryoffset被译为shared offset | 全局perCTA切片错误寻址 | launch/Driver与global地址服务 |
| 单个SMEM bank池给每client分别承诺满速 | 性能预算无效/无公平进度 | 共享带宽和公平性合同 |

验证计划应将上述反例落到控制模型、指令语义测试和后续RTL/SVA；本轮仅做文档与来源核查，没有运行新的SM RTL、调度器、RF、TMA或SMEM仿真。

## 11. 已实现证据与新增 SM 文档的分离

现有 MALU 最终源指纹为 197395785750354d3e1acf59dbba4542894062cfe66390eb952ed6d9022f96fd。实际RTL参数化共享乘法表达式为F64开53×53→106、关24×24→48；共享carry路径33bit；累加数组开132×32、关20×32。LANES=4只是每拍输入槽，不是4个并行乘法器或4条SM lane。

既有三轮实际执行10,861数值事务与55协议用例、独立decoder66,999项，不是SM指令集验证。它们不能转用于宣称通用F64、VALU/SALU/SFU、矩阵前端、TMEM、SMEM、cluster或PERF-S1已经通过。证据入口为[真实检查归档](../../malu/checks/2026-10-26/README.md)。

SM架构能力表建议至少设置“规范存在”“本项目目标”“架构已定义”“RTL已实现”“实际验证证据”五列。它们可以取不同值；特别是规范存在与RTL已实现之间不自动递推。

Rubin官方整GPU dense相对配比只可作为独立目标背景，不得据其反推SM数、每SM F64单元数、scheduler数量或现有串行MALU性能。产品峰值、项目PERF raw term预算、真实执行周期和SM端到端指标各列各表。

## 12. 本轮状态及后续主文审查入口

本记录已完成：21个一级家族独立核对、既有资源边界阅读、SM纲要、状态/完成/接口和反例清单。逐条指令全量枚举与target审查由同组专门账本提供；不得把本记录的一阶索引说成每种修饰符均已独立穷尽。

待主文形成后重点只读核对：core/SM/endpoint映射是否冻结；shared/TMEM/RF预算是否一致；每家族是否有责任与状态；ITS/CC/dynamic RF是否完整；异步完成域是否保持分离；实现状态是否与MALU证据一致。发现问题会追加到本文件，不并行改写主文。

## 13. SM-ARCH-S0 冻结基线（2026-11-07）

主笔已选择本记录 §2.1 建议的项目映射：1 core=1 SM，sp 为 core 内部执行组织；每 SM 逻辑映射 1 个 Tensor endpoint。这是项目 SM-ARCH-S0，不能转述为 NVIDIA 物理实例关系。后续主文复核以该已定基线为准，不再将 endpoint 数量写成未决。

继承的资源上限为每 SM 不超过 64 warp slots、不超过 8 CTA slots，warp 为32 threads，因此分配的线程槽不超过2048。实际驻留还受每 CTA 线程上限、向上取整的 warp 预算、RF、SMEM 和其他 launch 能力约束；padding lanes 不成为额外活跃线程。SMEM 256 KiB 有效数据池与 TMEM 最大288 KiB分别计数。RF物理容量保持 R_SM 参数，不在架构层冻结bank/端口、流水级或算术单元数量。

本节只是接收并记录已冻结基线。SM主文尚未落盘时，不据此声明其26章、215条附录和所有正文已完成审阅；本轮外网失败也不新增成功取证声明。2026-11-01历史研究日期保留，随后实际主文复核另记日期与结论。

## 14. SM 主文首次实际只读审查（2026-11-07）

### 14.1 对象和实际完成的检查

审查对象为 [SM_ARCHITECTURE.md](../SM_ARCHITECTURE.md) v1.0 的26章正文及附录。本轮已读取全篇，实际查看7张PNG，并与既有Tensor架构、v1.1微架构和MALU实现说明交叉核对。未修改主文、图、构建器或RTL。

轻量脚本独立核对得到：一级章号1至26连续；第26章217个第9章节号互异且与机器清单集合相同；全部217行物理/印刷起始页对与JSON一致；相对Markdown链接均存在。机器清单中215项为instruction、2项为控制语法。专门检查器的 Syntax/PDF逐字段审计另见 instruction_coverage_check.json；本次没有将本记录的集合比较冒称为再次解析全部合法tuple。

### 14.2 已一致的架构合同

| 审查项 | 主文位置及实际内容 | 结果 |
|---|---|---|
| SM-ARCH-S0 | §2、§4：core=SM、sp在core内部、每SM一个逻辑endpoint，均为项目约定 | 一致，不推导NVIDIA实例 |
| 驻留与RF | §4：≤64warp/≤8CTA、32threads/warp、R_SM参数及联合预算，单CTA上限另由capability声明 | 不把2048槽当作单CTA或无条件occupancy |
| ITS与控制 | §5：perthread状态、active group、dynamic collective、predication与.uni边界 | 未强制单warp PC或共享carry |
| RF/source/return | §6–7：源捕获或保护，全片段写回后ready；GPR/predicate/CC与setmaxnreg分开 | 与Tensor ARF合同一致 |
| 执行域边界 | §8–10、§16：标量/packed/approx、warp通信、矩阵归约各自处理 | F64 dot不冒充通用F64，MALU保持dot-only |
| 存储容量 | §4、§11–12、§16：SMEM256KiB与TMEM最高288KiB独立，L1容量另计 | 不合成544KiB CTA shared，不按CTA复制 |
| SMEM ownership | §12：launch分配、owner先于bank寻址、visible与实际allocation分开 | 与v1.1一致 |
| SMEM顺序与ECC | §12：失效实际应用后ack、proxy发布独立、active snapshot保留、scrub锁内重读 | 没有重新引入已关闭反例 |
| 完成域 | §14–16、§18：barrier对象落地、TMA/bulk、MCS full、restricted A-read和ld/st分开 | 没有统一done替代各家族 |
| owner回收 | §4、§22：thread exit不等于owner free，正常drain允许收尾命令，abort/reset另有系统确认 | 迟到包过滤不冒称外部副作用撤销 |
| 状态证据 | §21、§23–24：现有MALU与拟议SM/Tensor/PERF分开 | 未声称新SM RTL、PPA或全ISA仿真通过 |
| 图文边界 | 图1–7：S0、独立SMEM/TMEM、矩阵payload/descriptor分开、A-read/full独立 | 无TMA直接写TMEM或RF代替矩阵存储的图示错误 |
| 引用/日期 | §1、§25：固定PTX与历史快照，代理403如实记录 | 未新宣称2026-11-07官网访问成功 |

架构层未冻结RF bank/端口、scheduler数量、流水级或lane数量。引用v1.1的SMEM bank预算及PERF资源时均注明下位提案，不是SM的新物理常量。

### 14.3 SI-1：C 缩放与禁用旧 D 的契约遗漏——已关闭

初稿§16.2以“项目MALU仅返回”引入D=C+sum，但现有实现说明§1/§3已包含独立c_scale_shift；既有Tensor架构也已定义native scale-input-d。该写法会使一般式和既有接口不一致，并遗漏旧D禁用时不能读取未初始化旧值的责任。

已通知主笔；随后实际读到§16.1–16.2修订为D=C×2^(−s_C)+sum，普通s_C=0，native f16/tf32 kind的s=0..15、项目F16/BF16/TF32合法组合与A/B scale/block独立。enable-input-d=false时不读旧D，提供正式零C seed；true时传未缩放的D_old及独立shift，避免重复缩放。因此SI-1已关闭。

### 14.4 SI-2：CTA-pair 放置与双 endpoint 合同——待主笔明确

S0每SM只有一个逻辑Tensor endpoint；既有微架构§18则采用两个endpoint上的parent/peer child、双边reservation与完成mask。主文§17已写跨端点一致，但device/cluster admission尚未明确偶/奇rank一对CTA必须落在可互通的两个endpoint。若通用调度器将两者放同一SM，单endpoint不能直接套用既有双端协议。

建议把它明确为项目调度约束：一对CTA映射到能够建立peer关系的两个不同endpoint/SM，双方资源与存活同时保证；未定义同SM双逻辑参与者适配时，本版不接纳该放置。约束只属于本项目实现合同，不声称PTX规定了NVIDIA物理SM放置。已通知主笔，待实际修订后追加关闭结论。

### 14.5 非阻断澄清项：物理共享池与每 CTA target 上限

§12.1可显式补充每CTA visible shared仍受选定target/ABI限制。PTX§5.1.7 PDF52/印40对sm_100a/103a/107a/110a表列228KB，而项目物理池为256KiB，两者不是同一口径。当前主文没有直接宣称这些target每CTA均可使用256KiB，因此此项属于补明边界，不单独作为确定错误。

当前结论：除SI-2待明确的项目放置合同外，未发现本轮指定集成范围中仍未处理的阻断项；SI-1已在实际正文关闭。所有结论限于架构文档与图示，不等于SM RTL、无死锁、综合或端到端性能验收。

## 15. 修订后最终关闭复核（2026-11-07）

再次实际只读核对主文§12.1、§16.1–16.2与§17，结论如下：

- **SI-1已关闭**：独立C缩放一般式、s_C=0默认、native与项目合法范围、enable-input-d=false零seed且不读取旧D均已在正文保留。
- **SI-2已关闭**：§17明确S0由device/cluster admission将group2 even/odd CTA映射到可互通的两个不同endpoint/SM，共同保证资源与生命周期；同SM双参与者适配尚未定义，故本项目不接纳该放置。正文明确该限制属于项目双端协议，不把它写成PTX或NVIDIA的通用物理要求。
- **容量边界已补明**：§12.1独立约束单CTA visible shared的target/ABI/capability上限，并同时要求SM联合预算；256KiB池不冒充任意target的单CTA限额。

本轮指定的SM-ARCH-S0、owner/drain、RF/ITS、SMEM/TMEM、图文与既有MALU集成范围内，已无尚待修正的确定阻断项，可作为架构文档评审稿冻结。第14节的待修订状态由本节关闭结论取代。git diff --check未报告格式错误。

冻结范围仍是文档、清点与集成合同。现有证据没有新增SM功能RTL、全指令tuple合规、形式活性证明、综合/PPA或性能通过结论；后续实现须按capability与对应验收逐项开启。
