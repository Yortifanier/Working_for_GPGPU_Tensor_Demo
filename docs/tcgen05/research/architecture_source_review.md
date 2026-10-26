# tcgen05 Tensor 架构：来源与边界独立审查

审查者：agent2；日期：2026-10-26（Asia/Shanghai）。审查范围为架构责任、软件可见对象、执行参与者、完成与可见性、target/产品关系。本文不提出流水、物理阵列、乘法器数量、归约树、队列、仲裁或存储端口设计，不修改主文档，也不提交仓库。

已阅读主稿 `TCGEN05_TENSOR_ARCHITECTURE.md` v1.0 的 20 章，并交叉核对上传 PTX 的相关页、既有论文/两专利提取记录及本轮实际取得的官方网页。主稿严格区分架构与微架构、原生 Tensor 与项目 MALU，未发现需要阻止交付的确定事实错误。下述来源补充和限定应保留在最终稿中。

## 1. 本轮新增的实际访问来源

以下网页本轮均通过正常 HTTPS 访问返回 HTTP 200，未借助替代代理。快照在 `/workspace/output/tcgen05/sources/`，不将其当前内容倒推成上传 PTX 9.4 的版本定义。网页可能更新，引用应保留本次访问日期。

| 编号 | 来源及具体位置 | 可支持的架构事实 | 限定 |
|---|---|---|---|
| A1 | [CUDA Programming Guide：Programming Model](https://docs.nvidia.com/cuda/cuda-programming-guide/01-introduction/programming-model.html)，§1.2.2、§1.2.2.1、§1.2.2.1.1、§1.2.2.2、§1.2.3.3 | 一个 CTA 的线程由一个 SM 执行；warp 为 32 threads；cluster 的 CTA 在同一 GPC 同时调度，可协作访问 distributed shared memory；register/shared memory 的程序可见角色 | 该页明确 conceptual hardware model 不等于实际物理布局。cluster 同时调度不代表任意两个 CTA 都是 tcgen05 peer |
| A2 | [CUDA Programming Guide：Asynchronous Data Copies](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/async-copies.html)，§4.12.2、§4.12.2.1、§4.12.2.2 | TMA 是 bulk/bulk-tensor 异步搬运机制；包括 global↔shared、cluster 共享内存相关传输和规定的 multicast；多维 tensor copy 使用 tensor map；完成机制依传输方向而异 | TMA 不是 tcgen05.cp，也不是 TMEM allocator。tensor map 不是 SMEM matrix descriptor；不同完成域不可互换 |
| A3 | [NVIDIA Blackwell Tuning Guide](https://docs.nvidia.com/cuda/blackwell-tuning-guide/index.html)，§1.4.1、§1.4.1.2、§1.4.2.3 | Blackwell 软件运行与 SM、CTA cluster、共享内存/L1 的背景；资源限制是具体 CC 的属性 | 不足以支持全部 Tensor 指令的 target 合法性；不能拿本页替代 PTX 每条指令 Target ISA Notes |
| A4 | [CUDA GPU Compute Capability](https://developer.nvidia.com/cuda/gpus)，Data Center 表 | GB200/B200 对应 CC10.0；GB300/B300 对应 CC10.3 | 本次页面未列 Rubin 条目。因此不能据此确认 sm_107*→Rubin，更不能认为数字更大就继承全部 family-specific 功能 |
| A5 | [Inside NVIDIA Blackwell Ultra: The Chip Powering the AI Factory Era](https://developer.nvidia.com/blog/inside-nvidia-blackwell-ultra-the-chip-powering-the-ai-factory-era/)，正文 “Streaming multiprocessors”、Fig.2、“NVIDIA Tensor Cores” | 特定 Blackwell Ultra 产品中，SM 包含 CUDA compute、第五代 Tensor、SFU、TMEM 等功能；正文讨论 dual-thread-block MMA 与 TMEM | 页面顶部有明确标识的 AI-generated summary，本审查不以其为证据。正文中的产品数量/容量不能提升为 tcgen05 全目标不变约束 |
| A6 | [Vera Rubin NVL72](https://www.nvidia.com/en-us/data-center/vera-rubin-nvl72/)，NVL72 Specs 表 **单 NVIDIA Rubin GPU 列**、脚注 2/3 | 当前单 GPU TF32=2、FP16/BF16=4、FP8/FP6 Training=17.5、NVFP4 Training=35 PFLOPS 为 dense；NVFP4 Inference=50 PFLOPS 为 sparse | 是厂商产品峰值口径，不是项目实测、不是 native 指令逐 tuple 的吞吐表，也不是 target 编号映射 |

本轮取得的 CUDA Programming Guide 页面标记为 v13.4.2。PTX 主规范仍固定为上传的 Release 9.4（2026-07-17），不能将滚动网页版本当作同一快照。

## 2. Tensor 的整体功能边界

**规范级 Tensor 家族**不只是 dot arithmetic。其软件可见能力包括：TMEM 地址及动态资源管理、warp 与 TMEM 的 load/store、SMEM→TMEM copy、TMEM shift、矩阵运算及其数据/辅助对象、规定的 load reduction / sparse compression，以及异步完成和跨线程/proxy 顺序。

**本项目 MALU**只有向量 dot+C 数值责任；既有 RTL 不负责原生矩阵 descriptor、TMEM allocation、CTA peer、TMA、sparse metadata 的完整原生布局或 mbarrier。不能把既有 MALU 的测试通过写成 Tensor 前端已经完成。项目的独立 C/D、较宽类型集合和 PROJECT_EXACT 数值契约也不能倒写成 tcgen05 原生字段。

**周边设施**负责线程执行和一般数据供给。架构文档可以写“调度器提供 warp/thread 发射上下文”“通用访存角色提供普通 global/shared/register 数据操作”，但不得从 PTX 指令名确定它们经过哪个真实 issue port、LSU 队列或物理互连。

| 周边对象/功能 | 与 Tensor 的架构关系 | 不应额外推断 |
|---|---|---|
| warp/CTA 调度 | 正确参与者从其指令流发起 Tensor 操作；异步操作的发起与完成分离 | Tensor 自己调度任意 CTA、独立启动 kernel，或有已知的专用调度队列 |
| 一般访存功能（LSU 角色） | 准备普通内存/寄存器数据和描述符、消费结果；与 async proxy 的共享内存交互需显式顺序 | 所有 tcgen05.ld/st/cp 都等同于普通 ld/st，或必然共享一个物理 LSU 端口 |
| SMEM | 保存 B、可选 A，以及 Tensor 供数相关对象；通过规定 descriptor/layout 寻址 | 把 SMEM 当作 TMEM 的别名，或仅看起始地址就足以生成合法 matrix descriptor |
| TMA | 用 tensor map / pointer-size 等相应形式搬运数据，为 SMEM 中的 Tensor 输入提供前置条件 | TMA 直接等同于 Tensor 算术、TMEM 分配，或无条件 global→TMEM |
| TMEM | 保存 D、可选 A，以及 scale/sparse/LUT 等辅助矩阵；有 CTA/peer、allocation 与访问权限 | 把 CTA 可见二维地址空间解释为每 CTA 独立复制的整块 SRAM，或 warp lane=TMEM lane |
| MALU | 消费已形成的逻辑向量和 C，提供 dot 数值结果 | 用 dot 接口代替完整 Tensor 的资源、稀疏、布局和完成语义 |

架构图宜把命令/所有权、数据、完成通知画成不同关系；不标周期、端口数、物理 lane 数、内部 FIFO 或归约结构。

## 3. 参与者、所有权与完成：经上传 PTX 页核验

下列 PDF 页码为从 1 开始的物理页，印刷页为页脚；相关章节满足 PDF=印刷+12。

| 主题 | PTX 9.4 位置 | 审查结论 |
|---|---|---|
| TMEM 视图/地址 | §9.7.18.1，PDF699–700/印687–688 | 512 columns×128 lanes×32 bit 的描述明确限定 sm_100a/f。它是 CTA 可见视图，不是每 CTA 的物理独立容量保证 |
| 发射粒度 | §9.7.18.5，表57，PDF730–731/印718–719 | mma/cp/shift/commit 一 thread 发起；alloc/dealloc/permit 为 warp collective；CTA2 的资源操作要求两 CTA 各一 warp |
| CTA pair | §9.7.18.5.1–.2，PDF732/印720 | 同 cluster 的 rank 仅最低 bit 不同，两者互为 peer；不是任意 pair，也不规定物理相邻 SM 编号 |
| warpgroup 与 TMEM 访问 | §9.7.18.8.1，PDF741/印729 | 四 warp 分别访问 lanes0–31、32–63、64–95、96–127；这不把 MMA 发射变成 warpgroup collective |
| 特定 pipeline 顺序 | §9.7.18.6.2，PDF733/印721 | 只有明列配对及其条件保证顺序，不能把同线程发射推广成全部异步访问按序完成 |
| 两种完成机制 | §9.7.18.6.2.1–.3，PDF734/印722 | mma/cp/shift→commit+mbarrier；ld/st→wait::ld/st；wait::ld 不能等待 MMA 整体完成 |
| 跨线程同步 | §9.7.18.6.3–.4，PDF734–737/印722–725 | before/after_thread_sync 与线程同步/执行顺序机制组合。fence 不是线程 barrier，也不提供统一的全部结果完成保证 |
| shared async proxy | §9.7.18.6.5，PDF738/印726 | mma/cp 的 shared accesses 属 async proxy；generic-proxy 写入与其交互应按规定使用跨 proxy 顺序 |
| allocation 与 permit | §9.7.18.7.1，PDF738–741/印726–729 | allocation、permit、完成事件是不同对象。kernel 退出前显式 dealloc；放弃 permit 不等于释放；peer 退出条件必须满足 |
| 非 exclusive / exclusive | 表60，PDF739/印727 | 非 exclusive 32..512 列、power-of-two；exclusive 支持按32列倍数，表列 sm_107 上限576。必须再联合该功能的 Target ISA Notes，不把容量行当作独立 feature 许可 |
| 受限 A-read 完成 | §9.7.18.12.1，PDF844–846/印832–834 | sync_restrict 只证明之前相关 MMA 的 SMEM A read 完成，不证明 B read、D、MMA 整体或 TMEM 释放条件成立 |

**原文差异必须保留：** PDF733/印721 的分类表将 commit 放在 Synchronous instructions；PDF845/印833 的 commit Description 又使用 “an asynchronous instruction”。主文档不应自行统一成固定物理阻塞行为。可精确表述其可见效果：发起 mbarrier 的完成追踪；登记动作不是被追踪 MMA 的整体完成。

## 4. 地址与描述符：需补充的架构区分

除了主稿已列的 TMEM address、SMEM matrix descriptor、instruction descriptor、zero-column mask，还应在 TMA 背景段落说明 **TMA tensor map 是另一个对象**：

- TMA tensor map 描述 global/shared 中多维 tensor 的布局，通常由 host 的 cuTensorMapEncode 建立，用于 bulk-tensor async copy。[A2 §4.12.2、.2.2]
- tcgen05 SMEM matrix descriptor 是 64-bit register 中的矩阵位置/layout 编码。[PTX §9.7.18.4.1，PDF720、722/印708、710]
- tcgen05 instruction descriptor 为 32-bit register，按 MMA kind 解释 shape/type 等。[PTX §9.7.18.4.2，PDF723/印711]
- TMEM address 是 lane/column 地址，不能当 ordinary shared pointer 或 tensor-map handle。[PTX PDF699/印687]

因此架构供数链条可以描述成：通过 TMA 等机制准备 SMEM→建立相应数据可见性→需要时 tcgen05.cp 准备 TMEM 对象→发起矩阵操作→观察对应完成→collective ld/结果消费→排除全部访问后释放。这个链条是对象和依赖关系，不是所有模式必经的固定微操作序列。

## 5. 稀疏、scale 与数值责任

- 稀疏 A 的 mathematical K 与压缩存储 K/2 分开。TF32 的1:2、若干 kind 的2:4以及 FP4 MX/NV 的成对4:8是不同结构；metadata 合法值与版本按具体 target 核查。[§9.7.18.10.9，PDF816–818/印804–806]
- scale_A/scale_B 为独立数学矩阵，位于 TMEM，按 A 的 row 与 B 的 column 沿 K 分组。元素格式、scale 格式、BLOCK16/32分别描述，联合 kind/shape/target 合法表决定是否可用。[§9.7.18.10.7，PDF774/印762；表70–71，PDF781–782/印769–770]
- 原生 descriptor 的 A/B Scale Matrix Type 是共同字段；项目两个 scale 字段独立不产生任意交叉格式许可。[表54–55，PDF725–726/印713–714]
- `.kind::ti16` 的确定类型为 `.s1z4m11`，16-bit signed integer，范围[-2047,2047]，S32 D；不能按 e1z4m11 浮点或普通 S16 猜测 raw 编码。[表53及后文，PDF724–725/印712–713]
- 原生 D_old/D_new 是同一 TMEM 矩阵对象；独立 C-format/D-format 是项目接口扩展，不能当成通用原生能力。[§9.7.18.10，PDF755/印743]
- 架构应规定可见类型、数学关系、明确的精度/异常约束与设备 profile 边界，**不选内部乘积宽度、归约顺序或累加实现**。旧 mma/wgmma 精度段落不能直接补成 tcgen05 的完整逐 bit 保证；项目 PROJECT_EXACT 与设备实测分列。
- 原生 tcgen05 类型表没有 FP64/INT4/B1/完整 F32 乘数行；项目 MALU 支持它们，不意味着 Tensor 前端可将其编码成 tcgen05。[表50，PDF700–704/印688–692]

## 6. 论文和专利能证明什么

### 6.1 论文

[Accurate Models of NVIDIA Tensor Cores](https://arxiv.org/abs/2512.07004)，上传本作者为 **Faizan A. Khattak、Mantas Mikaitis**，v3、2026-04-04。PDF4–5定义矩阵结果与 inner product；PDF11–12说明指令入口可影响数值路径，B200 tcgen05 部分未研究 FP6/FP4；PDF14明确某些模型与验证范围限制；PDF15 Table4为特定设备数值模型。

这篇论文支持“数值行为需要固定 GPU 和指令入口”的架构边界，不能用其图推断所有产品的物理阵列、排队/发射能力或未来 Rubin 行为。尤其不能以表中某个内部对阶/累加位数充当本架构所有格式统一资源规范。

### 6.2 两件专利

| 上传原件与身份 | 可引用的正文/权利要求 | 架构用途与限制 |
|---|---|---|
| [US20250060938A1](https://patents.google.com/patent/US20250060938A1/en)，METHOD AND APPARATUS FOR DIRECT CONVOLUTION CALCULATION；NVIDIA；申请2023-08-14、公开2025-02-20 | PDF52–54，[0086]–[0119]；Fig.5A/B在PDF11、Fig.6A在PDF12；独立claim1在PDF69，方法claims17/19在PDF70 | 支持讨论驻留activation、移动窗口、补数据、MMA与累加的责任组合。32/128 lane、collector/TMEM具体组织是实施例，不是 tcgen05 或商品 GPU 的通用架构约束 |
| [US20250077615A1](https://patents.google.com/patent/US20250077615A1/en)，METHOD AND APPARATUS FOR WEIGHT-STATIONARY DIRECT CONVOLUTION CALCULATION；NVIDIA；申请2023-08-30、公开2025-03-06 | PDF61–62，[0093]–[0105]；Fig.5A/B在PDF11、Fig.5C在PDF12；独立claim1在PDF80，方法claims18/20在PDF81 | 支持讨论weight-stationary与输入复用/累加的职责。AGU、crossbar、每周期输入、lane数等不能进入本文成为强制微架构 |

专利 physical A-input/B-input 与 PTX 数学 A/B 必须先映射，不能凭名称相同画等号。权利要求与实施例必须分开；不存在“申请人是 NVIDIA，所以图必然就是 B200/Rubin 商品芯片”的推理。

PTX 自身也规定 collector reuse 是 **opportunistic**：许可复用不保证命中，Tensor 仍可能重读。源矩阵在使用它的 MMA 未完成前必须保持有效，不能因为 reuse qualifier 就提前改写。[§9.7.18.10，PDF756/印744] 这是比从专利示意图猜缓存行为更直接的架构依据。

## 7. PTX、Blackwell 与 Rubin：三条证据链

1. **ISA/target 证据链**：上传 PTX 9.4逐功能写明 sm_*a / sm_*f 条件。不是一个 target 数字阈值，也不是所有9.4条目都在基础 Blackwell 上可用。
2. **产品/执行环境证据链**：A4确认 B200/GB200=CC10.0、B300/GB300=CC10.3；A5给特定 Blackwell Ultra 产品的 SM/Tensor/TMEM 背景。具体指令仍查 target notes，不从“第五代 Tensor”自动继承全部新功能。
3. **目标配比证据链**：A6的 Rubin单GPU dense比例可算为 TF32:FP16/BF16:FP8/FP6 Training:NVFP4 Training = 0.5:1:4.375:8.75；50PF sparse inference单列。它不能给 Ti16/I8、每个scale/block tuple 或项目RTL填吞吐，也不能证明 sm_107* 对应 Rubin。

单 Rubin GPU、含两GPU的 Superchip、72GPU的 NVL72 和40K GPU AI Factory分别是不同列/表。即使各列数值近似成倍，也必须引用原表的同一粒度、同一模式与脚注，不能把50PF inference与35PF training用作纯位宽速度比。

## 8. 对主稿的最终审查意见

已确认主稿正确保留：架构/微架构分界；single-thread issue与warpgroup TMEM访问区别；D_old 与项目C区别；TMEM allocation/permit/完成分开；受限A-read完成不是整体MMA完成；Ti16 raw缺口；FP64/INT4/B1非原生tcgen05；opportunistic collector；Rubin与sm_107映射未证实；论文和专利不代表商品芯片实现。

**应补充的来源/说明（不是要求重做架构）：**

- 在§2.1或来源表加入A1/A2。TMA、warp/CTA/cluster与普通访存的背景，不能只引一份并未完整定义这些事项的Blackwell Tuning Guide。
- 在TMA背景说明tensor map与tcgen05 SMEM matrix descriptor是不同对象，并明确tcgen05.cp的SMEM→TMEM职责；避免读者把两种“Tensor”搬运当同一指令。
- 若正文要引用产品TMEM容量，保留具体产品/SM口径，不能与PTX的CTA可见二维空间相乘得到每CTA独立物理容量。主稿现有§5.1限定正确，应继续保留。
- commit分类表与Description术语差异在研究记录留档，主文只写可见完成语义即可。主稿§14.5的处理方向可接受。

本审查没有发现必须修改数值规格、CTA参与者或Rubin配比的阻断项。新研究文件落盘后，主稿原先预留的链接有效；新增引用可由root合并并重建排版产物。本审查未改主文档、RTL或既有测试产物，未执行commit/push。
