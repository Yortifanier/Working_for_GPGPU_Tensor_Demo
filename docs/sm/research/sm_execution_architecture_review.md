# PTX 9.4 全 SM 执行域与架构边界独立审查

审查：agent2；首轮：2026-11-01；mbarrier 补审：2026-11-07（UTC）。范围：SM 的执行、状态、存储和系统服务责任，及 PTX 指令到项目执行域的映射原则。本文只写研究结论，不修改主文档、构建器或 RTL，不提交仓库。

**主要结论：PTX 是待翻译的虚拟 ISA，不是 NVIDIA 物理管线清单。** 全 SM 文档必须覆盖线程状态、控制流、普通算术、集体通信、存储、同步、Tensor 和 SoC 服务。现有 dot-only MALU 仅覆盖其中一项数值服务；它的 PROJECT_EXACT profile、FP64 和资源复用结果不能直接转成全 SM 的原生 PTX 兼容声明。

## 1. 证据与审查方法

本轮实际读取上传 PTX 的文本 `/tmp/sm_ptx94.txt`，核对 Release 9.4、2026-07-17 的封面、§1.2–1.3、§3、§5、§7、§8 与下述 §9.7 的相关原文。页码采用从 1 开始的 **PDF 物理页/印刷页**；相关主体满足 PDF=印刷+12。完整 instruction heading 与拆分 mnemonic 清单由 agent1 单独提供，本文不以家族覆盖表代替其逐条清点。

同时读取仓库现有 [Tensor 架构](../../tcgen05/TCGEN05_TENSOR_ARCHITECTURE.md)、[Tensor 微架构 v1.1](../../tcgen05/microarchitecture/TCGEN05_TENSOR_MICROARCHITECTURE.md)、[MALU RTL 说明](../../malu/RTL_IMPLEMENTATION.md)，以及已保存的官方网页快照。2026-10-26 快照本次可在本地复读；[本轮公开源访问记录](public_source_evidence.json)显示 2026-11-01 直接 HTTPS 为 403，因此本审查不宣称今日重新取得网页成功。

| 来源 | 版本/实际访问日期 | 本文使用范围 |
|---|---|---|
| [PTX ISA 官方入口](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html)；本项目以用户上传 PDF 为固定快照 | Release 9.4，2026-07-17；本轮本地复读 2026-11-01 | 指令、参与者、类型、内存模型、target 合法性的主证据；滚动网页不替代 PDF |
| [CUDA Programming Guide: Programming Model](https://docs.nvidia.com/cuda/cuda-programming-guide/01-introduction/programming-model.html) §1.2.2–1.2.3 | 保存快照 2026-10-26，网页 v13.4.2 | CTA/SM、32-thread warp、cluster/DSM 的软件模型；不是物理布局保证 |
| [CUDA Programming Guide: Async Copies](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/async-copies.html) §4.12.2 | 同上 | TMA、tensor map、异步完成背景；不是 tcgen05.cp 的别名 |
| [Blackwell Tuning Guide](https://docs.nvidia.com/cuda/blackwell-tuning-guide/index.html) §1.4.1、§1.4.2.3 | 保存快照 2026-10-26 | 特定 CC 的 RF/occupancy/L1/SMEM 限额。CC10.0 的 64K×32 RF、228 KB SMEM/227 KB 每 CTA 是产品背景，不是本项目参数 |
| [Inside NVIDIA Blackwell Ultra](https://developer.nvidia.com/blog/inside-nvidia-blackwell-ultra-the-chip-powering-the-ai-factory-era/)，正文 Streaming multiprocessors、Tensor Cores、SFU 段 | 保存快照 2026-10-26 | 特定 Blackwell Ultra 的 CUDA compute/Tensor/SFU/TMEM 功能分工；不采用页首 AI-generated summary 为证据 |
| [Vera Rubin NVL72](https://www.nvidia.com/en-us/data-center/vera-rubin-nvl72/)，单 GPU 列与 dense/sparse 脚注 | 保存快照 2026-10-26 | 只作芯片级峰值目标背景；不反推每 SM 或每执行域的物理数量、发射率、时钟或 ISA target |

上述网页 HTML/text 保存于 `/workspace/output/tcgen05/sources/`。对 NVIDIA 的已披露事实、ISA 要求、项目方案及未验证能力，主文应分别标记。

## 2. 必须冻结的架构契约

全 SM 的合规检查单位应是 `(PTX version, target, opcode, type tuple, modifiers, shape/layout, state space, scope, participant constraints)`。只检查 mnemonic 名称不能判断是否支持。例如 `add` 同时出现在整数、常规 FP、mixed FP 和 alternate FP 章节；其类型、数值和 target 条件不同。

“核对全部 PTX 9.4 指令”应指清点和处置全部项目，不意味着同一 NVIDIA target 原生支持书中所有历史和架构专属形式。建议每条合法形式登记以下处置之一：

| 处置 | 含义 | 对外承诺 |
|---|---|---|
| D：项目直接执行 | 一条项目机器指令进入相应服务；可多周期 | 有实现与验收才声明支持；不意味着单周期或一条 NVIDIA SASS |
| M：项目序列化/降低 | 编译器、微序列器或运行库生成多个受控操作 | 需保持数值、active mask、异常/诊断、内存顺序、完成及 ABI 的可见行为 |
| S：委托系统服务 | 请求 L2/DSM/TMA/Fabric/运行时等 SoC 角色 | SM 保留提交、依赖、完成和错误责任，不能把队列接收当作服务完成 |
| C：翻译或链接时处理 | 类型、符号、ABI、布局、常量等静态处理 | 不为每个 PTX directive 建一个执行单元 |
| R：当前明确不支持 | capability 关闭并在合法化阶段诊断 | 不把未实现形式吞成 no-op，不把项目拒绝响应称作 PTX 规范异常 |

PTX §1.2、PDF22/印10 明确 PTX 被优化并翻译为 native target instructions。本文的 D/M/S 分类是项目建议；未经反汇编/设备测量，不能写成 NVIDIA 已实现的精确 pipeline 映射。

## 3. SALU / VALU / FPU / SFU / MALU 的正确边界

| 项目逻辑域 | 架构责任 | 边界 |
|---|---|---|
| Thread/warp control | active/exited/wait 状态、控制流、调用/返回、collective 参与者 | 分歧控制不等同于普通整数 ALU 比较；ITS 也不是 32 个独立 warp scheduler |
| SALU / uniform service（若选用） | 经编译证明或显式项目规则保证一致的地址/控制计算，可广播结果 | PTX 普通 `.reg` 是 per-thread；不能因某次值碰巧相同就永久合并线程状态。`.uni` 是对应控制流保证，不能据此对任意数据指令使用共享 RF |
| VALU / integer lanes | 线程标量整数/bit 操作、比较、packed 整数、dp2a/dp4a、video、地址计算 | “线程标量”不表示只做一项全 warp 运算；packed 元素与 thread lane 是两个维度 |
| FP32 / FP16 / BF16 / packed FP service | 常规与混合精度算术、比较、转换及逐线程 packed 运算 | 支持 BF16/FP8 类型不意味着允许所有类型任意交叉组合；不能转成矩阵归约 |
| FP64 service | PTX 标量 `.f64` 算术、比较、转换及相应数值契约 | 可采用多周期/序列实现；不能用现有 dot-F64 模式替代 `div.rn.f64`、`sqrt.rn.f64` 或独立 FP64 指令 |
| SFU / math sequence service | `rcp/rsqrt/sqrt/div` 的各精度形式、`sin/cos/lg2/ex2/tanh` 等 | `.approx` 的误差与特例逐指令规定；correctly-rounded 路径可依赖 SFU+校正，不能全部退化为同一个近似函数 |
| Warp communication | vote/match/redux/shfl/elect/activemask 及相应 rendezvous | warp reduction、线程内 packed dot 与 matrix dot 是三种不同操作 |
| Tensor frontend / adapters | wmma/mma/wgmma/tcgen05 的规定参与者、fragment/descriptor、布局、资源与完成 | 各代前端不能只更换 opcode 后沿用同一参与协议；wgmma 与 tcgen05 的 target 约束分别核查 |
| MALU | 用户定义的 Matrix ALU，接收逻辑向量和正式 C seed，返回 dot+C 数值结果 | 保持 dot-only，不加入 SALU/VALU/SFU 指令。矩阵布局、稀疏索引、TMEM 和完成协议由外围负责 |

`dp4a/dp2a` 是线程内 packed integer dot（§9.7.1.24–.25，PDF171–173/印159–161）。实现可以在有界服务保证下复用点积资源，但这是项目映射，需先拆/打包并保持 S32 结果语义，不能把它说成 tcgen05 原生指令，也不能把 MALU 对外改为通用 ALU。

跨代 matrix 前端尤其要保留 target 分离：上传规范的 wgmma dense/sparse、fence/commit_group/wait_group 均写 `Requires sm_90a`（PDF678/印666、695–698/印683–686）。本项目若额外接纳这些形式并降低到其他后端，必须单列兼容扩展，不得将其写成 `sm_107` 或 Rubin 的已确认原生能力。

现有 MALU 只有 `PROJECT_EXACT=0`；其最终一次舍入不能被泛化为所有矩阵硬件，也不能用它覆盖 FP 标量指令逐条规定的舍入/FTZ/NaN 行为。PERF 文档的 0.5:1:4.375:8.75 是规划目标，不能变成全 SM FPU/SFU/整数 lane 数量。

## 4. 线程状态、ITS 与分歧

PTX §3.1–3.2（PDF31–33/印19–21）说明 warp 发射的公共指令作用于相应 active threads；Volta 起有每线程 PC/call stack，可在 sub-warp 粒度分歧、重汇合及等待。架构要求包括：

- 每线程 PC/调用栈的**可见语义**，以及 active、predicated-off、waiting、exited 的区分。物理上采用哪种压缩 PC 或 reconvergence 结构属于后续微架构选择。
- 对寄存器结果和内存副作用均使用正确的线程有效集合；不能只 mask writeback，却让 predicated-off 线程仍执行 store、atomic 或提交异步工作。
- 不把 warp 同步执行当隐式通信顺序。`shfl.sync`、`vote.sync`、`match.sync`、`redux.sync`、`elect.sync`、`bar.warp.sync` 各自检查 membermask/参与者/退出线程约束；不能套用一个统一“active mask 就够”的规则。
- `.sync` 可能表示到达同一 collective 指令，不能统一解释为所有内存或异步操作完成；`.aligned` 是一致执行契约，不是地址对齐修饰。
- `.uni` 保证的对象是当前执行该控制流指令的 active threads 的 guard 与 target/index 等相同（§9.5，PDF140/印128；`bra/brx.idx` PDF433–434/印421–422），不是要求全部 32 个线程永远在同一 PC，也不创建新的 PTX uniform register 类型。
- 不承诺任意跨 CTA 自旋锁都会前进；CTA residency、cluster、资源占用和调度服务范围必须与程序假设匹配。ITS 不消除尚未被调度 CTA 引起的资源死锁。

`call/ret` 包括间接调用、ABI 参数和 divergent return；单一 warp 共用 return PC 不足以覆盖全部语义。`exit` 结束线程与 CTA/owner 回收是两个生命周期；Tensor、Fabric、TMA 等异步服务还需各自满足退出前义务，不能在最后一条普通 ALU 退休时提前释放内存 owner。

## 5. 寄存器、predicate、CC 与 uniform 状态

§5.1.1（PDF46/印34）定义 `.reg` 为 per-thread、不可寻址的虚拟寄存器；包含 1-bit predicate 和 8/16/32/64/128-bit scalar carrier。128-bit carrier 不要求一条 128-bit 算术 datapath；分配成多个 32-bit words 是项目实现选择。类型检查、narrow load 的扩展、tuple 拆/合并和 writeback 要保持规定语义。

§9.3（PDF134/印122）的谓词为虚拟 `.pred`。项目 predicate RF、uniform predicate 或 scoreboard 都必须保存每个线程的结果；predicate、执行 active mask、collective membermask 和 Tensor output-disable mask 不可混用。`set` 数值结果与 `setp` 谓词结果也不互换。

§9.7.2（PDF173/印161）另有隐式 `CC.CF`，用于 add.cc/addc/sub.cc/subc/mad.cc/madc 的 carry/borrow。它不是普通可读写 predicate，也不是 warp 共用的唯一 carry bit；跨线程和交错 warp 必须隔离，不能被 lowering helper 随意覆盖。原文明确 CC 不跨 call 保存，主要用于直线多精度序列。

动态 RF 管理亦不可遗漏：`setmaxnreg`（PDF872–874/印860–862）调整 warp 所拥有的每线程 register quota，从 CTA 的可用池取得/释放。`.inc` 可阻塞，新获寄存器须初始化；同一 warpgroup 的所有 warp 须执行相同操作，并在后续操作前显式同步。它不是一个无资源效果的计数提示，也不是改变 PTX 虚拟寄存器类型。

特殊寄存器要按各条定义实现，不能因为 `.sreg` 名称就都复制为 CTA 常量：如 `%laneid/%tid`、`%warpid/%smid`、clock/timer、cluster rank、性能计数等具有不同的粒度和稳定性。9.4 的 `%perctamemoryoffset` 为 u64、`%perctamemorysize` 为 u32，后者为 1024B 的倍数；必须结合 entry 的 `.minperctamemory` 与 driver 能力，不能把 per-CTA **global** slice 当作新增 shared memory（PDF906–907/印894–895、PDF937/印925）。

## 6. 算术与转换必须逐形式验收

| 项目 | 容易出错的降低/复用方式 | 必须保持的内容与依据 |
|---|---|---|
| 整数 `mul/mad` | 只算截断低积后再尝试生成 `.hi/.wide` | 宽度、符号、全乘积选段、饱和限定、carry/borrow；§9.7.1–.2 |
| 整数 `div/rem` | 直接沿用 host C++ 的所有边界行为 | 除零为 unspecified/machine-specific；`rem` 的负数行为原文为 machine-dependent，项目选向零需标为 profile 选择。PDF153–154/印141–142 |
| `clmad` | 复用普通整数乘加得到结果 | 是 u64×u64 的无进位 GF(2) 乘法，128-bit 中间多项式，选 hi/lo64 后 XOR c；§9.7.1.5 PDF148/印136。可用 XOR/shift 序列，不能用普通乘法替代 |
| 标量/packed FMA | 先舍入乘积再相加，或用矩阵 PROJECT_EXACT 结果随意截取 | 标量指令的单次融合舍入、逐元素 packed 独立结果、NaN/Inf/±0/FTZ；常规 FMA PDF192–193/印180–181 |
| `div/rcp/sqrt/rsqrt` | 所有形式共用一个低精度近似结果 | `.approx/.full/.rn/.rz/.rm/.rp`、适用格式及误差/特例不同；`div` PDF196–197/印184–185 |
| `.sat/.satfinite/.relu` | 当作统一“饱和” | 整数截限、FP [0,1]、有限最大值、ReLU 与 NaN 行为分别规定；不建立一个跨指令通用饱和开关 |
| `cvt/cvt.pack` | 只按目标位宽截断或依赖 host cast | 整/浮舍入、范围/NaN、packing、`.pzo`、随机舍入 `cvt.rs` 的显式 rbits、scale tuple；§9.7.10.24–.25 |
| 比较/min/max | 统一使用 host `min` | ordered/unordered、NaN 传播/忽略、±0、`.abs/.xorsign`、packed 输出编码；§9.3.1、§9.7.7–.8 |

PTX §9.6.1（PDF140/印128）还保留 16-bit 运算的 machine-specific datapath 提升语义；不能从 16-bit carrier 自动推断所有运算严格屏蔽高半字。项目若冻结严格宽度/扩展规则，应明确其选择以及可覆盖的程序集合。

**9.4 新特性不得只放进 Tensor：**

- §9.7.5 mixed precision 的 `.f16x2/.bf16x2/.f32x2` 形式是线程内逐元素转换/算术；upconvert、downconvert、`.rz/.ftz` 及 A/B/C/D 类型表分别核查（PDF240–247/印228–235）。新 packed 形式的 target 为 `sm_107f or higher in the same family`，不能与 scalar mixed 形式的 `sm_100 or higher` 混成一行。
- §9.7.6 的 FP8/6/4/UE8M0 x4 add/sub/mul/fma 是四项独立结果，目的为指定 FP8 x4 类型，不是 K=4 dot。四条的 Target Notes 实际列 **sm_100a、sm_103a**（PDF249/印237、251/239、254/242、257/245）。不能以“9.4 新增”推导“sm_107 全部原生支持”。
- packed `.e2m1x4` 是 b16，而 `.e2m1p4x4` 使用 b32、每 byte 内低 4 bit 有效；FP6 在 byte container 内有 padding。carrier、有效数位和计算吞吐是三个概念。
- 9.4 `set` 新增 `.u8x4/.s8x4/.u16x2/.s16x2`，结果是 packed 数值比较，不能用单一 warp predicate 取代（PDF260/印248）。

## 7. 普通存储、L1、SMEM、DSM 与 TMA

普通 LDST 域的架构责任包括：逐 lane 地址/状态空间解析、对齐和范围规则、predication、load 扩展、store mask、coalescing 后仍可追踪每线程目的、普通原子及访问完成。coalescing、cache line 和 bank 是物理组织选择，不能改变线程可见地址或把 vector 操作擅自升级为整体原子。

`.local` 是每线程的可寻址 device memory，不是私有片上 RF；spill、call frame 和 alloca 都可能经 LDST/cache/外部内存。`.param::entry` 与 `.param::func` 的 ABI/作用域不同；泛型地址、`cvta/isspacep`、`mapa/getctarank`、`.shared::cta/.shared::cluster` 必须保留地址类型与目标 owner，不能统统按裸 shared byte offset 解码。

L1/texture、constant、SMEM 可以在产品中共享部分物理设施，但软件对象和可见性仍分别定义。本项目 v1.1 选择 **256 KiB SMEM、独立于 L1/TMEM**；TMEM 288 KiB 的项目物理池也不是 L1 carveout。不能将 Blackwell Tuning Guide 的 CC10.0 228 KB shared 或 256 KB combined L1/texture/shared 背景写成项目参数已被 NVIDIA 证明。

TMA 是 SM 与系统异步搬运服务：pointer/size bulk、tensor map 多维寻址、im2col、multicast、reduce、descriptor override、priority/prefetch 等形式分别合法化。SMEM matrix descriptor、TMA tensor map、TMEM address 与 Fabric handle 是四种不同对象。`tcgen05.cp` 是 SMEM→TMEM，不能因为名称含 cp 就合并为普通 global→shared `cp.async`。

必须为每类服务指定发起者、source 可重用点、destination 可消费点、完成对象及退出 drain。classic `cp.async` 的 async-group、bulk 的 mbarrier/bulk-group、wgmma group、tcgen05 commit/wait、Fabric completion 互不替代。bulk 事务在一条 PTX 指令内可拆多段，不能第一段完成就释放整条 instruction 的目的/owner 责任。

## 8. 内存模型、proxy、fence 与原子

PTX 第8章适用范围为 sm_70+；原文 **不适用于 texture（含 ld.global.nc）与 surface accesses**（PDF115/印103）。不要为了简化全 SM 框图，给这些访问虚构与普通 generic memory 相同的一致性保证。

1. 强/弱操作、scope 和 proxy 必须独立记录。scope 是 `.cta/.cluster/.gpu/.sys`，**warp 不是内存模型 scope**（PDF119/印107）。`.shared.sys` 也不会令其他设备直接获得对同一 SMEM 对象的访问权。
2. fence 负责规定的顺序，barrier 负责相应线程同步；两者不互代。`fence.sc` 与 `fence.acq_rel` 也有不同的序关系，不能统一编译成“等 LSU 队列空”。
3. proxy 包括 generic、async、tensormap、fabric、readonly、texture/surface，以及虚拟 alias 所需的顺序。generic 写完后普通 fence 并不自动完成 async/tensormap/fabric 的跨 proxy 可见性（PDF120/印108；§9.7.15.3–.4）。
4. `ld.proxy::readonly` 将目标视为 kernel 生命周期只读，允许的地址空间受限制（PDF295/印283）；不能以普通缓存失效假设允许本 kernel 原地修改，再继续走 readonly proxy。
5. cache operators/prefetch/cache hints 通常不改变 memory consistency（§9.7.10.1，PDF281/印269）；忽略一个可选性能 hint 与忽略 completion-bearing 指令是两回事。`discard` 具有破坏性、可产生 unstable indeterminate value，不是无效果 hint（PDF321/印309）。
6. `.volatile` 等同 system-scope relaxed 加特定编译/执行约束，不保证 MMIO 的访问次数；`.mmio` 才限制读写合并、转发和 cache（PDF118–119/印106–107）。不能把二者共用一个普通可合并队列策略。
7. `atom/red` 的合法 op/type/state-space/scope、原子宽度及数值语义分别核查。vector、f16x2/bf16x2 的原子性按**每 scalar element**保证，不能擅自承诺整条 vector 原子。反向也不能把 b128 CAS/exch 拆成若干无互斥的普通 32-bit store（PDF450–452/印438–440）。
8. `red` 不形成 acquire pattern，即使后面有 acquire fence；不能因实现内部有读取就把 `red` 当成返回旧值的 `atom`（§8.11.1，PDF132/印120）。
9. FP32 atomic/reduce 的 FTZ 按指令与 shared/global 区别处理；9.4 `.noftz.f32` 不是可丢弃提示（PDF452/印440、458–459/印446–447）。

建议把 memory-order/proxy 责任作为 SM↔SoC 请求的正式 metadata，与 token/owner/generation 一起传递。项目若关闭 b128 atomic 或其他服务，capability 必须拒绝对应形式，不能宣称完整 PTX 支持后再用非原子模拟。

## 9. Fabric/CFT 必须作为独立系统服务

§9.7.11（PDF396–409/印384–397）介绍可报告 NVLink 故障的 CUDA Compute Fabric Transport。它与普通 pointer-based memory 的失败模型不同；host 创建/绑定 logical endpoint，device 发起并观察操作。因此全 SM 顶层需要 Fabric 命令、提交、部分完成、最终完成和错误返回责任，SoC 提供 endpoint/routing/transport/reduction 等服务，不能把全部 Fabric 塞进一个无错误状态的普通 LSU load/store 请求。

| 对象/操作 | 已核验要求 | 架构含义 |
|---|---|---|
| CFT handle | leId 为 u32，resource offset 为 u64；不是单一 pointer（PDF396/印384） | 与普通 VA、multimem VA、TMEM address 分开建模 |
| try_get / try_put / try_red / try_pullred | 全部异步且可能报告错误；访问 CFT 用 fabric proxy、本地 SMEM 用 async proxy、barrier 用 generic proxy（PDF397–406/印385–394） | 不可省略跨 proxy 契约或把错误变成正常零数据 |
| submit | 只提交当前 thread 的相应先前操作；`.op_restrict::fetching` 只 get/pullred；已提交的操作不重复提交（PDF407–408/印395–396） | issue 与 submit 是不同里程碑；须在 barrier phase 完成前提交 |
| 最终完成/report | 使用 layout::v1 mbarrier；primary completion 后检查 report predicate/value；失败也存在完成与排序责任（PDF397–398/印385–386） | 正常与失败都不能泄漏 token；成功不修改已有 report，不可每项成功时清掉其他项错误 |
| complete-tx units | get/pullred 按 bytes；put/red 按 16B units（PDF400/印388、402/390、404/392、406/394） | completion count 不可统一为 bytes；独立 expected-tx 与数据 byte count |
| fabric.wait | 只等待已提交操作对 local SMEM 的 reads，便于复用 source（PDF408–409/印396–397） | 不是远端写完，也不等待 try_get destination 可用 |
| counted completion | put/red 可用 8-byte counter，但必须 256-byte aligned；按 destination data bytes 累计，粒度未规定；multimem counter 只追踪各自目的设备（PDF399/印387） | 不能看到一次中间增量就认为全事务结束；不能令 counter 与 data 重叠 |
| try_pullred.sync | 所有 warp lanes 执行相同 operand；imm-membermask 必须 0xffffffff，任一线程已退出为 undefined（PDF406/印394） | 与允许非 exited subset 的其他 warp collective 不同，不能套通用 mask 检查 |
| 退出 | submit 并等待 Fabric 完成后才能 grid exit（各指令正文） | SM 线程退休、CTA 资源回收、grid drain 与 SoC 完成必须衔接 |

get 的 CFT source 访问以 128-bit 为原子粒度，不能把整块 copy 说成原子；put/red 的 reduction 也不意味着整个 size 范围单一线性化。`.multimem` Fabric 使用 multicast logical endpoint，与 `multimem.*` 的 virtual address 接口相关但不相同。fabric 的 system-scope proxy fence 示例在 PDF449/印437：generic::fabric release 与 fabric::generic acquire 均有明确方向。

本章 Fabric 在 PTX 9.3 引入、已包含在 9.4；不能把整章误记为 9.4 首次加入。

## 10. 容易从“计算型 SM”遗漏的指令

| 功能 | 应纳入的架构责任 | 不能作的简化 |
|---|---|---|
| `st.bulk` | shared::cta 区间置零；size32/64、8B 倍数、上限16777216B；地址及 owner bounds；sm100+（PDF312/印300） | 不是 Tensor store、不是任意 initval memset，也不是每 CTA 承诺16MiB SMEM |
| `multimem.*` / `.st.async` / `.red.async` | multimem VA 译成多位置服务；release/scope、load+reduce、remote completion 责任（PDF313–316/印301–304；st.async PDF310–311/印298–299） | 普通 ld/st 访问 multimem VA 为 undefined；不能把 async release store 等同 Fabric handle 服务 |
| `applypriority.async.bulk(.tensor)` | L2 eviction-priority 服务、128B 起址对齐或 tensor map 寻址、bulk-group 完成；sm107f family（PDF319–321/印307–309） | 虽为性能管理仍有规定的异步完成，不能提前 retire group 或当成数据 copy |
| `spcompress` | 2:4 选择、metadata 与 register vector 结果；MAX/MAXABS/MIN/MINABS、NaN 优先、−0<+0；多寄存器源/目的检查（PDF391–393/印379–381） | 不是 matrix MMA 的同义词；比较并列选择为 implementation-specific，不能宣称本项目 tie-break 是 NVIDIA 唯一编码 |
| `spdecompress` | 指定 spfactor 的寄存器散布和补零；metadata/shape/operand 长度检查（PDF394–396/印382–384） | 不能只支持2:4却宣称全部形式；out-of-range index 原文为 implementation-specific |
| texture `tex/tld4/txq/istypep` | handle、sampler、坐标、边界模式、filter/LOD、格式转换、查询与 texture read contract（§9.7.12，印397起） | 多个普通 global load 不能自动模拟过滤/取样/缓存可见性；compute-only 项目须明确关闭或提供完整降低服务 |
| surface `suld/sust/sured/suq` | surface descriptor、边界、格式、read/write/reduction/query（§9.7.13） | 非普通 pointer alias，不沿用未证明的 generic coherence |
| stack | 每线程动态 call frame、local pointer、save/restore 与生命周期（PDF847–850/印835–838） | stacksave/restore 不只是普通 mov；alloca 不是 shared allocator，deallocated pointer 不再有效 |
| video | 32-bit carrier 内 scalar/SIMD extract、sign/zero extend、算术、clamp、secondary operation、merge（PDF851/印839起） | 不是要求独立视频编解码器；不能只做一条普通 add 丢失选择/合并阶段 |
| `griddepcontrol` | 与 runtime 的 dependent/prerequisite grid 调度、等待和可见性（PDF471–472/印459–460） | 不是 CTA barrier；launch_dependents 不保证立即启动，也不代表本 grid 全部完成 |
| `nanosleep/brkpt/trap/pmevent` | 有目标约束的调度提示、调试/终止、性能事件服务（§9.7.21） | sleep 不等同内存 fence；trap 不等同普通分支；不可全吞成 no-op |

`spcompress` 的 `.x64` 可含 128 个输入 b32、64 个压缩输出 b32；三类 operand 总寄存器数≤253，且 data/cdata/mdata 之间任何重叠/复用为 undefined。即使逻辑上归“向量处理”，也必须给多周期 operand capture/写回或编译序列留出能力；不能把一条 PTX 指令假设为固定 3R1W RF 访问。该家族在上传 9.4 的 Target Notes 为 `sm_107a`。

## 11. 全 SM 逻辑域覆盖表

这是责任检查表，不是完整 mnemonic inventory，也不是 NVIDIA 管线图。各行需关联 agent1 清单中所有具体形式与 capability。

| PTX §9.7 家族 | SM 责任与候选服务 | 首要共享状态/依赖 |
|---|---|---|
| .1–.2 integer/extended precision | VALU、可选 SALU、integer iterative/microsequence、carryless service | per-thread RF/CC，宽乘积，call/clobber |
| .3–.6 FP/half/mixed/alternate | FPU32/FPU64/packed、SFU/math sequence、转换服务 | 舍入、FTZ、NaN/Inf/±0、packed tuple/target |
| .7–.9 compare/half compare/logic | VALU/predicate/bit-permute，部分可降低 | RF/predicate、signedness、packed结果 |
| .10 data/convert/memory | RF/convert、AGU/LDST、cache/SMEM/DSM、TMA、稀疏寄存器转换 | 地址类型、owner、proxy、async completion |
| .11 Fabric | SM Fabric frontend ↔ SoC CFT | handle、submit、layoutv1 barrier、错误report、partial/full completion |
| .12–.13 texture/surface | texture/surface frontend ↔ sampler/cache/SoC | opaque handles、过滤、边界、独立可见性 |
| .14 control | control/ITS、call ABI、退出管理 | PC/callstack、active/exited、collective和异步生命周期 |
| .15 synchronization/communication | warp exchange、CTA/cluster barrier、atomics、memory-order、runtime grid 服务 | membermask、scope/proxy、mbarrier primary/conditional/report、owner |
| .16–.18 matrix families | 各代 collective/async frontend、layout、memory/operand service、dot-only MALU | warp/warpgroup/single-thread参与差别、fragment、TMEM、group/commit/wait |
| .19 stack | thread stack/ABI+LDST local | pointer、alignment、frame lifetime |
| .20 video | VALU packed/bit operations 或语义保持序列 | extract/extend/clamp/secondary/merge |
| .21 miscellaneous | debug、perf、schedule、dynamic RF allocation | termination、time hint、CTA RF pool和warpgroup参与 |

全 SM 接口至少要表达命令责任、寄存器写回责任、内存完成责任和长期资源 owner 责任。画出一个单向“dispatch→ALU→writeback”不能覆盖 st/atomic/reduction/barrier/TMA/Fabric/Tensor 的不同终结事件。

## 12. 给主文和后续实现的必须保留项

1. 把“已完整清点”与“已实现全部形式”分别陈述；已有 RTL 仅 dot-only MALU。任何支持矩阵至少保留 target/type/modifier/participant，不能只以 mnemonic 行数作为兼容率。
2. 架构边界中补齐独立 Fabric/texture/surface/stack/runtime-grid/debug 服务。Fabric 接口要显式 carry completion units、report/phase、submit/thread identity 与 proxy；不与普通 LDST 字节计数隐式共用。
3. SALU/uniform RF、FPU64 和 packed 服务是项目逻辑域及可选实现选择；无文献依据时不声称数量/分区/每周期指令率。Rubin 芯片 dense 比值不能推导这些单元数量。
4. 对 ordinary ALU 数值单独建立合法形式和数值验收；不沿用 Matrix PROJECT_EXACT 包揽。尤其 mixedpacked、FP8x4 target、`.pzo/.rs`、负数rem、clmad、FP32 atomic noftz 应进专门矩阵。
5. 在完整指令表中给每条形式 D/M/S/C/R 处置及状态。lowering 的正确性条件包括 active mask、CC/predicate、rounding、原子/顺序、completion、ABI 和 owner 生命周期，不能只比最终普通寄存器值。
6. mbarrier v1 的 primary/conditional phase、payload report 不能压成旧版一个 parity bit；成功等待、report检查和下一phase复用按原文建立责任。不能只把所有新参数当“版本兼容空字段”。
7. 保留产品和项目内存差异：256 KiB SMEM/288 KiB TMEM、64bank1R1W 等均为本项目方案；同一份 SMEM 服务于 LSU/TMA/Tensor/barrier/peer/Fabric，各自峰值不能无条件相加。

本研究完成的是 ISA 与逻辑架构的覆盖审查。没有执行全 SM RTL 仿真、设备 SASS 对比、形式验证、性能测量或 PPA；不将已有 MALU 回归报告用作本研究未实现服务的验收证据。

## 13. 2026-11-07 补审：mbarrier v0/v1 与 TMA/Fabric report

本轮从上传 PDF 重新生成 `/tmp/sm_agent2_ptx94.txt`，实际读取 §9.7.15.16（PDF474–495/印462–483）、异步 copy report 定义（PDF347/印335）、bulk 与 tensor copy 的相关语法/Target Notes（PDF353–358/印341–346、372–379/印360–367）。没有再次联网，没有申请新的网络权限。下表是 ISA 可见要求；不规定 NVIDIA 的内部 bit layout 或物理 barrier table。

### 13.1 两种 layout 不只是增加一组可忽略字段

| 项目 | layout::v0 | layout::v1 | 原文位置 |
|---|---|---|---|
| 对象大小/对齐/位置 | opaque b64、8B 对齐、shared memory | 同左，不增加为128bit对象 | PDF474/印462 |
| 默认初始化 | 未指定 layout 时取 v0 | 必须显式选择 v1 | PDF479/印467 |
| expected arrival count | 1…2^20−1 | **1…2^9−1，即511** | 表43，PDF475/印463 |
| pending arrival count | 0…2^20−1 | **0…511** | 同上 |
| tx-count | −(2^20−1)…2^20−1 | 同左 | 同上；是有正负范围的计数，不能一概用无符号饱和实现 |
| phase 可见语义 | primary/conditional 一起推进 | primary 可推进而 conditional 不推进；另有每 primary phase 的 payload report | PDF475–478/印463–466 |
| primary 完成 | pending arrivals=0 且 tx-count=0 | 同左，**不以 payload 为零为条件** | PDF477–478/印465–466 |
| conditional 完成 | 与 primary 一致 | primary 的上述条件成立且 payload 全零 | 同上 |

v1 不能直接把1024个CTA线程计成 `mbarrier.init [bar],1024`；需要符合程序协议的指定到达者/计数组织，或明确不支持该组合，不能悄悄扩大原生范围。tx-count 的单位由被追踪的异步操作决定，不是统一的字节单位，更不等同 arrival count。

v1 phase transition 原子地推进 primary、在本阶段 payload 为零时推进 conditional、清零**下一 primary phase** 的 payload，并按 expected count 重装 pending arrivals。清下一阶段不等于应用可以忽略刚完成阶段的 report，或允许实现提前清掉还未观察的错误。原文仅允许等待当前或紧前一个 phase；还要求每个 primary phase 至少一次 test_wait/try_wait 返回 waitComplete=True，之后才进行下一 primary phase 的 arrive（PDF476/印464、493/印481）。实现要维持这组观察/复用约束，不能以无限深历史 token 或任意旧 parity 代替。

不论 layout，未初始化对象上的非 init mbarrier 操作均 undefined；有效对象必须先 inval 才能重新 init 或改作其他用途（PDF474、479–480/印462、467–468）。不能通过普通 store 清零有效对象来“重置”；也不能将 opaque 原始 bits 固定解释成项目自定公开字段。`mbarrier.check_layout` 可查询 layout，属于正式谓词结果，而不是读取 raw bit 的替代约定（PDF499/印487）。

### 13.2 wait、成功判断与内存可见性

- `test_wait` 非阻塞；`try_wait` 可阻塞，也可在阶段尚未完成时因系统时间限额/timeHint 返回。因此 wait 解除调度等待不等于 waitComplete=True（PDF493/印481）。
- 省略 `.phase_type` 检查 primary。`.phase_type::primary` 可返回 reportPredicate 和 b8 的 reportValue；waitComplete=False 时 report 输出无规定值。只有观察已完成 phase 后，才可把 report 当作该 phase 的报告（PDF492–493/印480–481）。
- 对 v0，reportPredicate/reportValue 恒为零；不能因此认为 v0 也可以追踪要求 v1 的 error/validity report 操作。
- `.phase_type::conditional` **要求 `.parity`**；它用于观察成功条件的阶段推进。对可能报告失败的服务，仅循环等待 conditional 可能无法获知已完成的失败；失败处置需要 primary completion 加 report 检查，不能把失败当成永远“尚未完成”。
- `.acquire` 是默认语义、`.cta` 是默认 scope；显式 `.sem` 与 `.scope` 必须一起给出。只有 acquire wait 返回 True 才建立规定的 acquire pattern；`.relaxed` 不提供同样的排序/可见性（PDF494/印482）。不能仅根据一个 success predicate，把 relaxed wait 当作全部后续读取已经获得可见性的证明。
- `.shared::cluster` 的地址空间与 `.cluster` 的同步 scope 是独立属性。远端 shared 支持 arrive/arrive_drop（不能返回 state）、expect_tx、complete_tx；其他 mbarrier 操作没有远端 shared 支持（PDF479/印467）。不能把远端 atomic 路由能力自动推广成 remote init/test_wait/inval。

### 13.3 TMA validity report 与 Fabric transport report 必须分开

| 主题 | TMA / bulk copy validity | Fabric report |
|---|---|---|
| 触发原因 | 传输数据匹配指定 bit pattern | Fabric 操作报告失败，供应用处理 transport/resource 相关错误 |
| 路径 | `.global → .shared::cta/.shared::cluster` 的规定 copy 形式 | try_get/try_put/try_red/try_pullred |
| report 默认 | 省略即 `.mbarrier::report::disabled`，不检查数据 | 使用规定的 `.mbarrier::report::fabric` |
| layout | 启用数据检查必须 v1，否则 undefined | 必须 v1 |
| 内容 | pattern 匹配设 report predicate 非零；reportValue 以 OR 0 的幂等方式更新 | 成功不改变已有 payload；失败设置 predicate 并可带 opaque reportValue；交给规定 CUDA API 解码 |
| 与完成的关系 | copy 完成与 validity 报告分开；标记匹配不能笼统称作硬件访存异常 | 错误也须保留最终完成/排序责任，不得泄漏 token 或仅将错误清零 |

TMA 数据检查的 **per_16bytes 是从对齐16B chunk 采样一个 element 来匹配**，不是检查该chunk内每个元素；表33列出 FP32 −0 的80000000、FP16的8000、FP8的80、FP4的8等 pattern。`per_element::ff` 按每个对应 byte 检查。不能宣称任意 NaN、所有坏数据或传输位翻转都会被该机制发现；它不是 ECC（PDF347/印335）。

`cp.async.bulk .ignore_oob` 仅规定 global→shared::cta 路径，边缘可能越界的 destination bytes 是 indeterminate，且若指定 report mechanism，只能 disabled（PDF355/印343）。不能把 ignore_oob、TMA tensor-map 的 OOB fill、validity report、Fabric error-report 合并成一个“容错拷贝”开关。

Fabric 原文称：程序组合指定 report::fabric 的 Fabric 操作与指定不同 reporting mechanism 的其他操作，其行为 undefined（PDF398/印386）。本审查不据此发明跨机制 payload 的合并规则；至少不能承诺同一 barrier phase 混投 TMA validity 和 Fabric report 合法。项目可复用 barrier 原子服务，但每个 phase 的 report mechanism、payload 组合、完成单位和 owner 必须保持原生契约。

### 13.4 版本/target 与现有子系统边界

| 能力 | 上传 PDF 的指令专属 Notes | 主文需要保留的边界 |
|---|---|---|
| mbarrier layout qualifier | 引入于PTX9.3；需要sm90+（PDF480/印468） | 9.4封面摘要将其列作新增，但详细 Notes 是9.3；不把摘要当逐条版本表的唯一证据 |
| wait phase_type/report operands | 引入于PTX9.3；需要sm90+（PDF494–495/印482–483） | 仍需分别满足test_wait sm80+、try_wait sm90+等基线条件 |
| cp.async.bulk report_mechanism | 引入于9.4；Target Notes 为sm107f及同family后续（PDF357/印345） | mbarrier v1 存在并不令所有目标自动获得数据 validity copy |
| cp.async.bulk.tensor report_mechanism | 9.4引入；Target Notes 为sm107f及同family后续（PDF376–378/印364–366） | 仍须联合具体load_mode、state space、cta_group及其他修饰符检查，不能仅凭report capability开启全部tensor形式 |
| Fabric 全家族 | 9.3引入；本章相关指令要求sm100+（PDF400–409/印388–397） | 本项目是否实际实现与原生目标许可分开；现有Tensor/MALU RTL不提供该服务 |

现有 Tensor 微架构 v1.1 的 barrier path 是拟议项目方案，现有 RTL 只有 dot-only MALU。新全 SM 若选择完整 v1/TMA report/Fabric，需要扩展并审查对应原子对象、阶段、等待、报告和错误 drain 责任；不能因旧文已经画过一个 barrier agent 就写成这些能力已经实现。

这次补审不改变本文第2节 D/M/S/C/R 的处置原则，也不要求用 SALU 接收全部线程标量算术；普通 mixed/packed FP 仍由线程执行域处理，MALU 保持 Matrix dot-only。

## 14. 2026-11-07：SM 主文 v1.0 只读技术审查

已通读 [SM_ARCHITECTURE.md](../SM_ARCHITECTURE.md) 的26章正文及附录责任表，并对本文负责的普通数值、scope/proxy、TMA report、Fabric completion、mbarrier layout及target/实现边界逐项比对。审阅期间读取的1002行快照 SHA-256 为 `79dbad96b66b58fe40b017a83b1a8056e81a479db1b08a011e47211e35217198`；主稿由主agent继续编辑，此hash只定位本次快照，不锁定后续排版版次。

### 14.1 实际检查范围

- 阅读了全部26章文字和21类指令映射的责任/处置列，检查其与本文第2–13节的逻辑边界是否一致。
- 用独立Python脚本从主文Markdown读取第26章节号，对照现有 `ptx94_instruction_inventory.json` 的 `instruction_topics` 集合：**217个源说明节对应217行，缺项0、多余0、重复0，覆盖21类**。包括两个非opcode控制语法说明节；没有把它们升级为新增硬件opcode。
- 特殊寄存器附表实际有35个第10章说明节行；这里只核对索引行数与分组责任，没有声称重新对全部特殊寄存器的每个展开名/target逐一做独立PDF认证。相应详细源审查仍由agent1的清单负责。
- 对mbarrier、bulk wait_group.read、TMA validity与Fabric使用了本轮重新抽取的固定PDF正文；例如bulk read wait明确同时涵盖tensormap read与source read，未误把它当destination最终完成（PDF387/印375）。
- 没有重跑全SM仿真，没有运行汇编器、SASS反汇编或目标GPU。没有对所有type/modifier/shape合法tuple作穷举；217/21/35是文档映射统计，**不是RTL通过数、兼容率或测试覆盖率**。

### 14.2 结论与必须修正项

本次未发现阻止当前架构文档交付的确定事实错误。主文正确保留以下关键边界：

| 审查点 | 主文结果 |
|---|---|
| 普通整数/FP/packed/mixed/SFU | 属线程执行域，保持各自数值/target约束；未移交dot-only MALU包揽 |
| SALU与uniform RF | 经证明的数据一致性优化，不强迫所有线程标量指令只算一次；`.uni`未被误写成通用uniform寄存器许可 |
| scope/proxy/atomic | warp不是一般memory scope；普通fence不替代跨proxy；vector按元素原子、b128 CAS不能无锁拆片；red不形成acquire pattern |
| TMA report | layoutv1、disabled默认、pattern检测、per16B采样、ignore_oob限制与Fabric故障报告分开 |
| mbarrier | b64/8B、v1上限511、tx正负范围、primary/conditional、false报告未定义及remote更新/本地等待边界保留 |
| Fabric | 独立SM↔SoC服务；handle不当pointer；submit、source read partial与full分离；get/pullred按bytes、put/red按16B；counter8B但256B对齐 |
| target/产品 | WGMMA sm90a及alternate packed特定target未被冒充sm107/Rubin；Rubin芯片峰值比未转成SM单元数量 |
| 当前实现 | 只有既有PROJECT_EXACT dot-only MALU有RTL证据；SIMT/普通执行域/SMEM/TMA/Fabric等未实现能力关闭，D/M映射未称已运行 |

### 14.3 非阻断的表述精化建议

已向主agent发送以下澄清建议；它们用于减少下位实现误读，不表示已发现对应RTL缺陷，也不由本agent改主文：

1. §14.1可把“conditional有规定的parity条件”写明为“conditional必须`.parity`”；补明只有`.acquire` wait返回True才建立规定可见性，`.relaxed`和try_wait解除阻塞均不能代替。
2. §18.1宜直写“CFT资源经fabric proxy、本地SMEM经async proxy、barrier经generic proxy”。现有“async/fabric代理关系按方向建立”不应被后续实现者解读成规范存在通用`fence.proxy.async::fabric`形式；已核验的显式跨proxy fence按Fabric↔generic等原生语法处理。
3. §12.3“32/64-bit原子整体保持原子性”可限定为相应scalar atomic，或指向§13的vector/packed逐元素例外，避免仅按32bit carrier将f16x2升级为整体原子。

本轮只追加研究审查记录；未修改主文、构建器或RTL，未commit/push。

## 15. 2026-11-07：冻结前增量确认

按主agent要求，仅只读复核主文§12.1、§12.3、§14.1、§16.2、§17及§18.1的最终增量；未重复全文审查，未联网、未重跑RTL。所读1012行主文快照SHA-256为 `b28eaee5bf381c7dbcc8387687c62bc8030eb722935e11774cf3eaecb20fb0ba`。

第14.3节三项澄清均已落实：conditional明确必须`.parity`，acquire wait须返回True才建立规定可见性；Fabric三proxy分别明确为CFT/fabric、SMEM/async、mbarrier/generic且不新增任意fence组合；scalar atomic与packed/vector逐元素例外明确分开。

新增C缩放与既有MALU的`c_scale_shift`检查相容：未缩放C与shift只传一次，在匹配数值profile内部执行指数/累加变换，避免提前重新量化或二次缩放；enable-input-d=false提供正式零seed。group2的不同endpoint/SM放置已明确标为项目双端协议的调度约束，未冒充PTX普遍物理要求。单CTA visible shared同时受target/ABI/capability与联合物理池预算约束，未把256KiB池容量冒充任意target的单CTA额度。

**增量复核无新增必须修正项；第14节的技术审查结论保持。** 该结论限于已阅读架构快照与上述增量；不构成全SM实现、全部ISA tuple验证、性能或PPA证明。未修改主文、构建器或RTL，未commit/push。
