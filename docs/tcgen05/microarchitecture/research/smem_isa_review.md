# SMEM与tcgen05边界：独立规范及微架构正确性审查

角色：agent1；日期：2026-10-27。范围：SMEM与TMEM的区别、CTA launch分配、descriptor/布局、proxy、TMA与Tensor完成、DSM/pair访问、mbarrier存储和进度。本文只写独立审查意见，不修改主文、图或RTL，不提交或推送Git。

本轮依据已经实际读取的用户上传PTX9.4、前轮保存的官方CUDA/Blackwell网页快照与既有tcgen05核验。**256KiB/endpoint、64×32bit 1R1W物理bank均为项目拟议配置，不是NVIDIA已公开的SMEM实现事实。**

## 1. 固定规范与来源位置

上传原件：`PTX ISA Release 9.4`，2026-07-17，1002个PDF物理页，SHA256=`4be2905e240b70a8b176b4d6fb162714f2fc361a9503572d848ff723abf289c3`。下表PDF页从1开始，印刷页为原件页脚。

| 主题 | 原文位置 | 支持的结论 |
|---|---|---|
| shared state space | §5.1.7，PDF52/印40 | SMEM由执行CTA拥有，cluster内CTA可访问；默认.shared::cta；不是TMEM |
| launch SMEM尺寸 | §10.30–.32，PDF902–904/印890–892 | total/aggr/dynamic尺寸由kernel launch为CTA建立；动态SMEM也是launch分配 |
| bulk async proxy | §9.7.10.28.2，PDF348/印336 | bulk操作属于async proxy；完成后有implicit generic-async proxy fence，需正确观察完成 |
| bulk tensor copy | §9.7.10.28.5.5相关描述，PDF373–375/印361–363 | tensor map与目标SMEM/mbarrier的空间、方向及group约束；global→shared使用bytes complete-tx，反向bulk-group |
| tcgen05 SMEM descriptor | §9.7.18.3–.4，PDF711–730/印699–718 | 64bit寄存器编码SMEM位置/layout，不是tensor map，不是TMEM地址 |
| Tensor shared async访问 | §9.7.18.6.5，PDF738/印726 | mma/cp的SMEM访问属于async proxy；generic/async交接需相应proxy顺序 |
| mbarrier对象 | §9.7.15.16–.16.4，PDF473–475/印461–463 | opaque .b64、8byte对齐、存于.shared；init/inval及phase/计数生命周期 |
| mbarrier位置限制 | §9.7.15.16.11，PDF479/印467 | remote cluster支持规定arrive/expect_tx/complete_tx；不支持远端*_wait等其余操作 |
| Tensor commit事件 | §9.7.18.12.1，PDF844–846/印832–834 | ordinary与restricted A-read独立，barrier按generic proxy访问；multicast到目标CTA相同SMEM offset |

官方补充快照在 `/workspace/output/tcgen05/sources/`，上一轮已HTTP200取得，来源与版本边界见[架构来源审查](../../research/architecture_source_review.md)：CUDA Programming Guide Programming Model、Asynchronous Data Copies，以及Blackwell Tuning Guide §1.4.1/§1.4.2.3。

Blackwell Tuning Guide具体B200资料给出228KB shared/SM、227KB user shared/block及1KB系统保留；256KB是combined L1/texture/shared容量。**这些产品/运行时口径不能被改成“本项目256KiB SMEM就是B200同一结构”。**PTX§5.1.7的target容量表与CUDA user可用上限也不是同一个口径。

## 2. 必须补入主微架构的对象分界

| 对象 | 谁拥有/建立 | 合法访问 | 不等同于 |
|---|---|---|---|
| CTA SMEM区 | kernel launch/admission按static+dynamic及系统保留分配 | generic LSU、TMA、tcgen05 SMEM读取、DSM及mbarrier各守空间/顺序规则 | tcgen05.alloc产生的列资源 |
| TMEM allocation | 运行中tcgen05.alloc/dealloc与permit规则 | 规定的tcgen05操作、CTA/peer及lane布局 | 普通shared byte pointer或launch dynamic shared |
| TMA tensor map | opaque tensor布局对象，tensor-copy入口引用 | 相应TMA/bulk-tensor操作 | 64bit SMEM matrix descriptor |
| SMEM matrix descriptor | issuer寄存器中的64bit编码 | tcgen05矩阵/cp供数，随kind/layout解释 | 驻SMEM的descriptor结构或任意DSM pointer |
| mbarrier对象 | CTA在其SMEM内init/inval | 规定位置/空间下的mbarrier与async完成事件 | 仅存在Event Q中的done bit |
| barrier执行/缓存状态 | 项目内部实现选择 | 必须与SMEM对象、地址、owner generation及opaque状态一致 | 软件可绕过SMEM申请的无限独立barrier空间 |

SMEM应作为**通用共享存储子系统**连接generic LSU、TMA/DSM和Tensor供数，而不是只画Tensor私有operand cache。所有入口最终引用同一逻辑SMEM字节和owner视图；不能各存一份不一致副本。

## 3. CTA launch allocation与生命周期不变量

- **S1：分配时点不同。** static/dynamic shared是CTA launch/admission建立的资源；`%dynamic_smem_size`明言kernel launch时初始化。不能发明`tcgen05.alloc_smem`或把已有TMEM allocator接到dynamic shared请求。
- **S2：容量分层。** physical pool、target可寻址容量、每CTA user static+dynamic、系统保留、当前占用和对齐浪费分别计数。256KiB物理池不意味着每个驻留CTA都各有256KiB，也不意味着CUDA ABI可无条件申请256KiB/block。
- **S3：所有owner总预算不超池。** CTA admission同时预约static、dynamic、系统保留及实现所需对齐；不能先接收CTA后等Tensor遇到SMEM请求才发现超配。
- **S4：shared byte地址带owner generation。** 同样的CTA-local offset在不同CTA中是不同对象；CTA slot复用后旧TMA/Tensor/DSM返回不得写入新owner。
- **S5：reclaim等全部用户drain。** CTA SMEM释放必须考虑generic、TMA、DSM、Tensor源读、barrier更新与远端引用，而不是只看本地MMA full-done或TMEM allocation归零。
- **S6：退出与permit独立。** relinquish TMEM alloc permit不会释放launch SMEM，dealloc TMEM也不会使SMEM源地址无效；反过来，释放CTA SMEM不能保留仍会重读该SMEM的collector任务。

**反例**：八个CTA都登记dynamic shared=64KiB，却只配256KiB共享池；实现到MMA读取时用offset取模落到同一physical bank row。逻辑矩阵公式正确仍会跨CTA破坏数据。

**反例**：CTA0结束并把physical slice给CTA1，旧DSM store/commit callback仍带旧CTA slot编号而没有generation检查，改写CTA1矩阵或barrier。

## 4. 地址、swizzle、tensor map与物理bank

- **A1：分离三层地址。** client逻辑坐标→按该client规范得到的CTA-local byte offset→owner/cluster映射后的physical byte地址→bank/row。不能直接把TMEM lane/column的32bit值送到SMEM byte地址通路。
- **A2：descriptor先解布局再译owner。** matrix descriptor的16byte对齐、stride、swizzle、base offset、absolute模式等由recipe解释；不要在已经swizzle的canonical byte请求之后又统一执行第二次“Tensor swizzle”。
- **A3：TMA producer与Tensor consumer一致。** tensor map和SMEM matrix descriptor是两个对象，producer写入的布局必须与consumer计算的字节位置一致；“都叫128B swizzle”不代替完整alignment/base/atomicity/shape核对。
- **A4：physical bank是项目映射。** 64个32bit bank、每bank1R1W、256KiB总池在均分时每bank1024word；不宣称NVIDIA使用此数目。广播、冲突、replay/forwarding必须保持同一地址的读写结果，不靠宏默认read-during-write行为。
- **A5：mask与跨word正确。** byte/halfword store、TMA片段、64bit barrier对象及跨bank请求都必须先拆分并保留原操作身份；不能因为bank32bit就把64bit语义拆成可被观察的两次无关联更新。

**反例**：CTA physical base只按128byte对齐，却把descriptor要求的1024byte重复pattern XOR直接作用在physical地址；CTA0正确、CTA1错误。必须证明转换次序，或选取满足全部支持布局的base对齐并证明等价。

**反例**：TMA tensor map已经产生swizzled写地址，公共SMEM入口又因source=TMA再swizzle一次；Tensor读取的descriptor路径只swizzle一次，双方不再引用同一字节。

## 5. generic/async proxy与供数完成

### 5.1 不可合并的条件

1. generic LSU已执行/提交SMEM store。
2. 写入对相应async consumer可见。
3. TMA/bulk复制完整写入并完成其transaction责任。
4. Tensor已读取本tile相应A/B源数据。
5. Tensor已写D并形成normal completion。
6. consumer线程已观察正确barrier phase并建立所需线程/proxy顺序。

任何一个条件都不是其余全部条件的别名。`bar.cta.sync`不能自动被当成所有跨proxy fence；反之proxy fence不等于CTA所有线程到达。

### 5.2 具体不变量

- **P1：generic→Tensor的交接。** 按PTX所需`fence.proxy.async`等规则建可见性；仅在bank里已写入不等于满足跨proxy程序语义。
- **P2：观察bulk完成的语义。** PTX说明bulk async完成后有implicit generic-async proxy fence，结果在完成被正确观察后对generic可见；不能忽略此机制，也不能不问传输方向就要求用户再做一套重复完成操作。
- **P3：TMA方向各有完成机制。** global→shared的常见bulk-tensor形式使用`mbarrier::complete_tx::bytes`；shared→global使用bulk async-group。不能把两者都接到Tensor的normal commit。
- **P4：arrive count与tx bytes分开。** TMA complete-tx字节数、线程arrive count和tcgen05.commit的arrive-one不是相同计数。正确初始化、expect_tx、完成及phase判断由barrier协议维护。
- **P5：descriptor可见性不是payload可见性。** 获得一个合法descriptor/tensor-map handle不证明其引用的A/B数据已写完；数据epoch必须与命令tile匹配。

**反例**：TMA的最后一个payload beat还在SMEM队列，completion已提前减tx-count；MMA收到barrier成功后读取未写完B。

**反例**：用一次线程arrive替代expect_tx/complete_tx，barrier phase提前完成，TMA写回与Tensor读取发生竞态。

## 6. SMEM A-read、normal full与collector重读

- **C1：A-read是读义务结束。** restricted事件只对之前相关SMEM-A MMA，在原SMEM A snapshot、在途读返回和可能重读责任全结束后产生；不是“第一个A请求已发出”或“collector fill已提交”。
- **C2：private snapshot跨写入有效。** A-read之后producer可按约定复用旧A区域，当前命令继续使用命令私有不可变snapshot；未来reuse失效不能销毁该副本。
- **C3：只覆盖A责任。** restricted A-read不证明B已读完、D完成、TMEM可释放或整个SMEM slice可释放；若B/LUT/其他对象共享slice，仍须其各自的读/更新保护。
- **C4：normal token继续存活。** A-read完成不能清parent、D lease、peer child、normal watermark或延迟writeback context。
- **C5：collector reuse可能重读。** B块缓存miss或A use并不保证物理命中；在所有可能重读完成前保持对应SMEM源版本。不能仅按“已进入cache”的早期事件解锁源。

**反例**：A和B位于同一CTA SMEM allocation。A-read通知后实现释放整个SMEM slice，producer覆盖B；MMA后续B cache miss重读得到新tile。

## 7. DSM与CTA group2

- **D1：DSM不是TMEM共享。** `.shared::cluster`是cluster范围SMEM访问，`.shared`默认`.shared::cta`。`mapa`可取得另一CTA相应shared变量地址；不改变目标CTA对物理slice的所有权。
- **D2：范围不同。** DSM可以涉及cluster规定的CTA集合；tcgen05 pair则是rank仅最低bit不同的两个CTA。不能把任意DSM destination CTA当作当前tcgen05 peer。
- **D3：local descriptor不是任意remote pointer。** tcgen05的SMEM matrix descriptor描述当前CTA矩阵，pair按具体recipe访问双方对应数据；不能把descriptor某些位偷用为任意cluster rank。
- **D4：remote引用纳入reclaim。** owner退出/重用前要排除远端SMEM访问和barrier消息；本地队列为空不证明DSM无在途事务。
- **D5：multicast方向与signal区分。** TMA multicast复制payload到目标CTA对应offset；tcgen05.commit multicast复制的是barrier通知，不复制D。TMA group2的barrier目标还有明确parity/peer规则，不能复用一套“mask逐bit给data+event同目标”的简化路由。
- **D6：远端wait限制。** PTX表列remote shared::cluster允许arrive/arrive_drop、expect_tx、complete_tx等规定形式，其他mbarrier操作不支持。不能实现“consumer直接try_wait任意远端barrier”并声称原生合法；通常consumer等待自己local SMEM的目标barrier。

**反例**：group2操作由CTA0发射，A/B在两端；SMEM控制器只增加CTA0引用，CTA1退出回收后迟到读访问新owner。

## 8. mbarrier确实需要SMEM状态与原子更新

### 8.1 表示与生命周期

- **B1：软件对象存在。** PTX mbarrier是.shared中的opaque .b64，8byte对齐；init/inval、phase、expected/pending arrivals、tx-count，以及layout-v1 report都是对象语义。Event Q只保存待送通知，不能代替该状态。
- **B2：barrier占用预算。** 用户在SMEM声明/使用的barrier字节属于其SMEM预算。若项目用side table或cache加速，仍按owner+offset+generation与同一逻辑对象对应，不能无说明从SMEM容量之外另赠无限barrier存储。
- **B3：原子RMW。** 32bit bank下一个64bit barrier可能跨两个bank，更新必须保持对象原子语义；使用原子单元、锁定配对bank或等价方案，不允许poll看到半更新phase/count。
- **B4：init/inval与epoch。** 使用前init；复用其内存前inval。对象仍live时普通非mbarrier访问属于规范未定义范围，项目诊断不能把普通store当成合法重新init。CTA generation变化不能误命中旧side-table条目。
- **B5：barrier table不能限制ISA为少数对象。** mbarrier数量在规范中主要受shared容量限制；若仅有有限hardware cache，必须支持miss/回写/重载或明确关闭未实现能力，不能静默把不同地址映射到同一entry。

### 8.2 进度不能只留在“外部barrier agent”黑箱

- **B6：事件到SMEM落地。** 至少说明tcgen05 arrive-one、TMA complete-tx、CPU/LSU mbarrier操作、remote arrival进入哪个原子更新路径，何时ack；ack之前不得回收完整event metadata。
- **B7：控制进度credit。** completion/RMW/poll响应有独立可前进的队列或保留credit；不得全部排在等待同一barrier才能释放的数据请求之后。
- **B8：原子锁有界。** 多bank对象的lock/更新失败重试不能占住产生其解除条件所需的唯一端口；poll不得无限饿死complete_tx，complete_tx也不能永久饿死普通合法访问。
- **B9：回调恰一次。** generation、owner、barrier offset、事件ID、phase/transaction责任对应；retry不能重复减tx-count或重复arrive。晚到旧epoch事件不更新新CTA对象。

**反例**：SMEM数据队列全满；消费者等mbarrier才消费数据，complete-tx更新又必须排入同一满队列，于是没有任何一方能推进。仅说“Event Q还有空间”不能解除SMEM落地路径的环等。

**反例**：64bit barrier的低32bit计数已更新、高32bit phase尚未更新，generic poll读到混合状态并错误判定完成。1R1W银行数量不能自动保证64bit原子语义。

## 9. 给v1.1主文的最低补齐清单

1. 顶层明确画出SMEM physical pool及generic LSU/TMA/Tensor/DSM/barrier多个client；不只增加一条外部SMEM接口。
2. CTA launch static+dynamic+reserve预算、owner/generation、local/remote地址翻译、admission/reclaim责任。
3. 256KiB与64bank的项目参数、容量/深度核算及target/user/runtime能力边界，不映射成NVIDIA事实。
4. matrix descriptor与tensor map分别解析，swizzle生成和physical bank映射的明确次序。
5. generic/async proxy、TMA transaction完成、A-read/full、ld/st和SMEM reclaim的独立条件。
6. mbarrier的SMEM字节对象、原子RMW、init/inval、phase/tx-count、remote支持范围及落地进度路径。
7. 覆盖上述反例的验证/活性计划，并继续注明本轮新增子系统尚无RTL/综合/性能通过证据。

本记录是独立规范审查与设计要求，尚未审查v1.1主文；没有把这些要求或反例测试计划写成已实现、已运行或已证明通过。

## 10. v1.1主文最终只读复核

已实际读取 `../TCGEN05_TENSOR_MICROARCHITECTURE.md` v1.1的§7.2–7.9，并核对仍保留的source snapshot/完成跟踪段落。本节取代上节末尾的“尚未审查”状态；没有修改主文、图或RTL。

| 本轮要求 | 主文已明确的设计边界 | 复核结果 |
|---|---|---|
| SMEM不等于TMEM | 独立physical pool，core共享，generic LSU/TMA/Tensor/DSM/barrier引用同一字节对象 | 通过 |
| launch static/dynamic | CTA launch提供static+dynamic+reserved，先admission再运行，owner记录base/size/generation/refs；不复用tcgen05.alloc | 通过 |
| 256KiB/64bank属性 | 明确为本项目参数，非NVIDIA事实，非每CTA独立256KiB，target/launch/residency另行约束 | 通过 |
| owner与地址转换 | 各client先产生CTA-relative byte offset，再owner转译与range check，DSM选择目的owner | 通过 |
| swizzle与tensor map | matrix AGU按recipe只施加一次；服务端不再次swizzle；TMA map与matrix descriptor分开且要求布局匹配 | 通过 |
| proxy和数据可见性 | bank commit、collector失效、fence发布分开；有序cutoff不被后发write延长；TMA fragments落地不自动等于整体完成 | 通过 |
| 真正mbarrier对象 | .shared中8B aligned opaque b64，init/inval及phase；64bit跨双bank原子预约/RMW；事件落地后ack | 通过 |
| 控制进度 | control请求/返回保留credit；多bank all-or-none锁，提交即释放锁而不等待远端取ack；失效sink不依赖Tensor CQ | 通过 |
| remote barrier操作 | remote *_wait关闭，只路由规范支持的更新，consumer等待local对象 | 通过 |
| 完成域独立 | TMA tx字节、commit arrive1、restricted SMEM A-read、MMA full分别跟踪；A-read仍不退休parent/full责任 | 通过 |
| owner退出/reuse | 本地与远端LSU/TMA/Tensor/DSM/barrier/RMW/returns等责任drain后才回收，旧generation不写新owner | 通过 |

**最终结论：本轮所提SMEM ISA边界、ownership、布局、proxy、mbarrier物理状态及完成域问题已在v1.1对应段落覆盖，未发现必须阻断交付的文档内容问题。**

结论限定为拟议微架构文档的正确性与边界审查；新增SMEM服务端、DSM/barrier通路仍未实现/仿真，不表示RTL、原子活性、时序、面积、功耗或端到端性能已经通过。
