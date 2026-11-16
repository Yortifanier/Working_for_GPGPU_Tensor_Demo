# SM 执行后端合同：ALU、数据搬运与 TMA

日期：2026-11-16。本文从既有 [SM 架构](../SM_ARCHITECTURE.md) §6–22、[全指令审计](../research/ptx94_instruction_inventory.json)及[执行架构审查](../research/sm_execution_architecture_review.md)提取后续 RTL 的接口与验收要求；不改写这些已发布文档，也不新增执行通过声明。

**Sched/Instr Ctrl 下辖的不只是 Tensor。** 普通整数、FMA、SFU、转换、warp 通信、LSU、共享内存、异步搬运/TMA及同步服务均有独立执行和完成责任。以下枚举为项目的逻辑执行域，不代表 NVIDIA 物理管线数量，也不要求每类单独复制全部硬件。当前已有项目 Tensor/tcgen05、TMEM、dot-only MALU RTL；其余域在本文中的合同或端口不构成实现。

## 1. 完整的逻辑执行域

| 建议执行域 | 接收的功能 | 必须保持的独立责任 | 本文核查时实现状态 |
|---|---|---|---|
| CTRL | 分支/间接分支、call/ret、exit、predicate控制与线程等待 | 每线程 PC/调用/退出状态、动态实例、重汇合；重汇合不充当内存同步 | 未实现完整普通执行路径 |
| SALU / uniform route | 有编译证明或显式项目入口契约的 uniform 计算 | 一致源值、guard/成员及目的广播；证明不可用时退回 per-thread 执行 | 未实现；仅是可选优化 |
| VINT / integer ALU | add/sub、mul/mad、hi/lo/wide、div/rem、位运算、比较/选择、packed/video、dp2a/dp4a、clmad | signedness、宽结果、carry/borrow、predicate、多元素独立运算、饱和和项目边界值 | 未实现 |
| VFPU / FMA | 常规及允许的 half/packed/mixed/alternate 浮点 add/sub/mul/fma/mad、min/max/compare | 每条形式的融合/舍入、FTZ、NaN/Inf/±0、类型/carrier、sat/satfinite/relu | 未实现；MALU 通过不转移到此域 |
| FP64 / wide FP | 合法的 F64 普通浮点算术与比较 | 原生标量精度；可多周期，不能以 F64 dot 代替所有标量操作 | 未实现；是否独立物理管线待细化 |
| SFU / precise math | rcp/rsqrt/sqrt/div、sin/cos/lg2/ex2/tanh及合法 packed 形式 | approx/full/各舍入形式、范围、误差界、FTZ与特殊值；精确形式的校正或独立算法 | 未实现 |
| CVT | cvt/cvt.pack、合法 scaled/packed/随机舍入转换 | 输入/输出类型、随机位输入 rbits、溢出/饱和、packing与元素数 | 未实现 |
| REG / permute / sparse | mov、位重解释、向量拆合、prmt、spcompress/spdecompress | 位搬移不做数值转换；大寄存器向量、compressed-data/metadata及相应重叠限制 | 未实现普通寄存器入口 |
| WARP | shfl/vote/match/redux/elect/activemask及兼容形式 | membermask、当前active/predicate、非退出线程集合和动态实例分别解释 | 未实现 |
| LSU / L1 / constant | global/local/const/param/shared/generic 的合法 load/store/atomic/reduction及缓存管理 | 空间、地址、lane、权限、对齐、coalescing、返回重组、scope/order/proxy与线性化点 | 未实现普通服务端；不能复用 Tensor TB 模型冒充 |
| SMEM / shared atomic | 同一 SM 数据池的读写、byte mask、规定原子/RMW、DSM目标访问 | owner/base/range、bank竞争、真实提交点、生命周期与原子互斥 | 待写统一硬件服务端 |
| MOVE / classic async copy | 普通数据搬运、ldmatrix/stmatrix/movmatrix适配、经典cp.async及commit/wait | 原指令布局/参与者、global→shared片段、zero-fill/ignore及经典async-group | 未实现这些普通入口；tcgen05 MOVE不等同此域 |
| TMA / bulk async | cp.async.bulk{.tensor}、reduce/prefetch、相关async store/reduction、priority和tensor map操作 | tensor-map版本、坐标/布局、方向、multicast、源可复用/最终完成、bytes/arrivals等单位 | 未实现；可接SoC后端，SM前端责任仍不可省略 |
| SYNC / barrier / proxy | warp/CTA/cluster barrier、mbarrier、fence/proxy、family-specific等待 | 到达成员、primary/conditional phase、tx-count、报告、真实原子更新与可见性 | 未实现完整对象服务；tcgen05已输出typed完成事件 |
| TENSOR | wmma/mma/wgmma各代适配与tcgen05 | 代际参与者/布局/目标能力不同；matrix规划、TMEM与各自完成域 | tcgen05项目级endpoint与MALU已有；其他前端不能自动标完成 |
| TEX / SURF | texture采样/gather/query和surface读写/reduction/query | 句柄/对象元数据、坐标/边界/过滤/格式、独立memory-model适用性 | 当前capability关闭 |
| DSM / FABRIC / MULTIMEM | cluster shared路由、多位置VA、CFT handle及规定远端操作 | 目的owner版本、分片、source-read/full、计数单位、失败报告与SoC完成 | 未实现系统服务 |
| SYSTEM / SREG / ABI | 特殊寄存器、stack/ABI、nanosleep、trap/debug/PM、grid依赖、cluster取消、动态RF配额 | 来源/稳定性、运行时回应、资源协议和退出drain；不把系统请求吞成无效果OK | 待逐项实现或明确关闭 |

SALU 不是“PTX标量指令”同义词。PTX线程各自执行的标量指令通常需要 per-thread 数据路径；`.uni` 控制流承诺也不证明普通数据源相同。FMA、SFU与packed x2/x4是普通每线程运算，不应归到dot-only MALU。MALU仅做向量点积加C；可选复用必须通过独立适配、数值证明和公平性约束，不能改变其对外职责。

## 2. Sched / Instr Ctrl 到后端的接纳合同

物理接口可按域细化，逻辑请求必须能直接携带以下信息，或引用在整个操作生命周期内稳定的side table：

| 信息 | 最低合同 |
|---|---|
| 动态身份 | reset epoch、kernel、owner/generation、warp/thread或collective实例、operation token及版本；PC不是唯一动态实例 |
| 语义选择 | 内部IR版本、执行域和具体操作；完整type tuple、packed元素数、signedness、舍入/FTZ/饱和、memory或async修饰符 |
| 参与集合 | 实际active mask、predicate结果、collective membermask及已退出集合；predicated-off线程无寄存器/内存/事件副作用 |
| 源 | 已捕获的数据，或受保护的RF/predicate/CC/descriptor/vector绑定；超过单拍容量时有分片计划与捕获bitmap |
| 目的 | GPR/predicate/CC各自的目的绑定、有效lane、宽结果/向量片段数及writeback credit；含多目的操作 |
| 内存/对象 | address-space、VA/owner-relative offset/特殊handle、访问大小/对齐/byte mask、scope/order/proxy/domain、目的对象版本 |
| 异步责任 | stream/group/token/barrier/phase/report、完成单位、源读取终点与最终完成终点、owner引用和取消政策 |
| 目标合法性 | 当前target capability及所选实现方式D/M/S/R；不能仅凭一个后端存在而接纳全部modifier组合 |

`valid && !ready` 期间保持请求payload和稳定引用不变；握手一次创建一次责任。后端反压不能撤销已接纳操作或静默重发有副作用操作。发生错误时，正式完成/取消也必须带原身份，关闭返回credit与资源引用。

若首批RTL选择最多3源、1目的、uniform-control的有限IR profile，必须显式关闭需要更宽绑定或不同控制模型的形式。不能据此声称已支持多寄存器descriptor、b128结果、spcompress大向量、双predicate或每线程CC链。分片可以降低端口数，不能降低逻辑操作数数量。

## 3. 源捕获、scoreboard与真实写回

1. 发射之前预约执行槽、源捕获/保护、全部目的范围、返回/写回credit，以及需要的memory/event责任；不能只检查执行单元ready。
2. 源值尚未捕获的字、predicate或CC不得被新写覆盖。64-bit descriptor两半须属于同一动态源版本；不能捕获第一片后释放整个vector的源保护。
3. GPR、predicate和每线程CC分别追踪依赖。`setp`双predicate与`add.cc/addc`进位链不能只用一个普通GPR busy位代替；不同线程的CC不可广播共享。
4. RAW/WAW/WAR处理要与所选RF方案相容。采用保守scoreboard可以阻塞冲突而不做重命名，但已发射长延迟操作仍须有不会被后发覆盖的目的绑定。
5. 多周期/乱序返回按token及generation核对，全部规定目的片段真实提交后才解除目的依赖。`last`到达、结果入FIFO或consumer warp被选中都不是替代完成点。
6. RF写回、barrier更新、peer service、free/commit/wait及退出drain要独立前进。不能让consumer先被调度才接收producer写回，也不能让新发射耗尽全部完成服务credit。
7. 中途错误可能已有部分RF/SMEM副作用。未完整完成的目的标poison/未就绪，进入明确abort/诊断路径；不能以零数据/普通成功done解锁依赖。

## 4. 普通算术与数值域

| 域 | 验收必须区分的形式 | 不能以此替代验收 |
|---|---|---|
| 整数 | hi/lo/wide完整积、24-bit规则、carry/borrow、符号扩展、移位边界、sat/wrap、clmad的GF(2)、packed各元素及div/rem边界 | 只测低32-bit加乘或直接引用host C边界行为 |
| FMA/FPU | fused一次舍入、mad本身规则、各合法rounding/FTZ、NaN/±0/Inf、sat/satfinite/relu、packed/mixed逐元素类型表 | 先舍入乘积再相加；将x4变为K4归约；沿用matrix PROJECT_EXACT作普通FMA oracle |
| SFU | 每个approx形式的误差界/定义域与特殊值；full/正确舍入形式的校正，F64特殊approx标题和合法packed形式 | 统一使用一个近似值，或用host sin/sqrt逐bit比较所有approx结果 |
| CVT | 每种源/目的/rounding/饱和/packed tuple，显式rbits、`.pzo`及scaled模式 | 截低bit、位重解释mov或隐式全局随机状态 |
| WARP / REG | 实际参与集合、vector/metadata对应、相等/NaN选择范围、bits与数值类型区别 | 总是32线程、将current active mask当所有membermask、只处理第一片 |

整数和浮点可共享乘法、加法、比较、转换等物理资源；FP64可迭代执行。模式切换须隔离配置、源快照、中间状态及结果身份。设计还须在输入和返回两侧做公平/信用控制；资源复用不能让已接纳操作永远等不到规格化、舍入或写回。

## 5. LSU、数据搬运和 TMA 的明确分界

| 路径 | 源/目的和地址解释 | 对应完成域 |
|---|---|---|
| 普通LSU | 每线程规定空间的地址、载荷与访问语义；可coalesce传输但保留每lane身份/原子操作 | load完整RF写回；store/atomic按规定提交、线性化、返回与可见点 |
| 普通REG/矩阵搬运 | RF↔RF或shared↔RF的指令规定fragment、transpose/packing | 实际目的片段写入；不生成MALU算术结果 |
| 经典cp.async | 规定global→shared片段、zero-fill/ignore | per-thread经典async-group或规定mbarrier关联 |
| cp.async.bulk | 指针/size的方向、空间和multicast | 该形式规定的mbarrier或bulk-group |
| TMA tensor copy | opaque tensor map、多维坐标、tile/im2col/gather/scatter及descriptor override | tensor-map/source读终点、目的写入、相应bulk-group/complete-tx与report分别追踪 |
| tcgen05.cp | SMEM matrix descriptor→TMEM、规定copy shape/展开/multicast | tcgen05的MCS full及后续commit；不使用经典async-group替代 |
| tcgen05.ld/st | TMEM↔RF的规定warp片段与pack/unpack | 独立wait::ld/st与真实RF/TMEM ack |

TMA不是普通`cp`或`tcgen05.cp`；tensor map也不是SMEM matrix descriptor。共用SMEM bank和fabric端口可以复用数据通路，不能合并语义队列、计数单位或等待域。

LSU/Tensor/TMA/DSM/barrier必须访问同一owner的同一SMEM字节对象，不能各拥有一份256KiB私有副本。SMEM分配容量、目标可见范围、物理base只在服务端解析一次，所有client共享真实仲裁和带宽预算。TMEM是独立对象；lane/column地址不能作为普通byte pointer交给LSU。

普通LSU还保留weak/relaxed/acquire/release/acq_rel/sc、scope、proxy及原子性。store进入SoC队列不证明system可见；普通fence不自动替代generic→async或tensormap proxy发布。b128原子若未实现互斥全宽访问，则capability拒绝该形式，不能拆成多个无保护store。

## 6. 异步、TMA与事件责任

每项异步操作至少分别维护“已接纳”“源/tensor-map读取安全”“目标数据提交”“规定的completion更新已提交”。某种等待只观察其中规定的终点：

- `wait_group.read`或相应Fabric local-read等待只能释放规定源，不证明目的ready或最终可见。
- bulk-group commit只冻结发令线程此前相应未提交操作；不自动建立同组任意两项之间的顺序。
- Tensor restricted commit只表示相关SMEM-A读取终点，不发布D/full-ready；normal commit和RF ld/st是不同stream。
- mbarrier的expected arrivals、tx-count、primary/conditional phase及report按布局和指令管理；bytes、arrivals、16B units不能隐式共用一个计数单位。
- 每个multicast目标分别绑定cluster实例、owner/generation、barrier位置和未关闭责任。第一个目的提交不代表全部目的完成；fanout已展开的onehot事件不得再展开一次。
- completion事件仅入FIFO不能视为mbarrier更新落地。若接收方早ack，必须已接管不会随源CTA退出而消失的独立目标引用，持续持有到真实RMW提交。
- 9.4 TMA report的per16bytes/per_element数据pattern检测不是一般ECC或全元素数值正确性证明；report enabled与layout::v1、方向、ignore_oob及target capability联合合法化。
- 正常drain仍允许完成已接纳操作所需的结果读取、free、wait、commit、barrier与peer返回。reset/epoch过滤迟到响应不等于撤销可能尚未发生的外部写，必须协同drain/cancel。

## 7. Target capability与实现处置

合法性单位为`{PTX版本,target,opcode,type tuple,modifiers,shape/layout,state space,scope,participants}`。目标family不能用数值大小比较后统一继承功能；已存在某格式的存储/解码器，也不产生该格式所有ALU操作。

每个入口逐形式记录D/M/S/R：D为直接硬件、M为有界微序列、S为真实外部服务、R为当前关闭。M/S仍须有语义、错误、资源和最终完成证据。只连上ready/valid、返回固定OK、清一个busy位或发一个event脉冲，不足以从R变为已实现。

例如既有审计保留wgmma的sm90a约束、alternate FP x4特定target、mixed-packed与scalar mixed的不同Target Notes、spcompress专属目标以及TMA report的107f同family要求。Rubin产品名和Tensor峰值比例不替代这些逐形式条件，也不推导普通FMA/SFU/整数管线数量或吞吐。

## 8. 验证边界与后续交付门槛

| 检查层 | 最低证据 | 不得据此扩大成 |
|---|---|---|
| decode/dispatch | 合法形式路由到相应域，非法/关闭形式在副作用前诊断，保留身份 | 执行单元已实现或数值通过 |
| ordinary arithmetic | 独立oracle；整数边界、FMA融合、各舍入/FTZ/特殊值；approx按误差界 | MALU dot通过意味着普通FMA/SFU通过 |
| source/scoreboard | 随机反压、源后写、WAW、predicate/CC链、wide/多目的/片段完整性、乱序返回 | 单一busy位或固定延迟可覆盖全部依赖 |
| LSU/memory | 多CTA offset0隔离、lane重组、真实写ack、shared/SoC原子、scope/proxy litmus、非法空间拒绝 | 请求握手或TB预填数组证明内存语义 |
| MOVE/TMA | descriptor/version、坐标/边界、分片、bytes计数、source-read与full分离、multicast逐目标、report | memcpy结果相同证明完整TMA |
| async/lifetime | 满负载完成前进、drain、abort、迟到旧generation/epoch、目标复用、失败不伪造arrival | 单次成功event证明mbarrier/退出正确 |
| whole-SM | 真实程序经Instr Ctrl→Sched→RF→后端→写回/等待→退出，覆盖控制流与服务交互 | 直接从TB驱动tc_cmd_t即为完整SM |

本文件没有运行普通SM后端测试，也没有将既有SM指令发生器106个计划用例改为PASS。当前tcgen05的实际证据独立位于[最终回归报告](../../tcgen05/rtl/checks/final/results_all.json)；它只覆盖该项目endpoint所列用例。

核查快照：`SM_ARCHITECTURE.md` SHA256为 `b28eaee5bf381c7dbcc8387687c62bc8030eb722935e11774cf3eaecb20fb0ba`；全指令JSON为 `77f932724a2ab3c91f7d3ab8b60269b6e274afcf43db2c82bed3056f542c126a`。上传PTX9.4固定PDF的SHA256为 `4be2905e240b70a8b176b4d6fb162714f2fc361a9503572d848ff723abf289c3`；本文使用已归档审计，未进行新增网上资料或GPU测量。附件内容只是证据，不作为改变用户要求的指令。
