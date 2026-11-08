# SM 指令发生器：存储、异步与资源状态独立审查

日期：2026-11-08（UTC）。负责人：agent3。状态：vplan研究输入与独立审查准则；发生器、全SM RTL及本记录中的用例均未由本文实现或运行。本文只写本research文件，不改主vplan、构建器或DUT，不提交。

## 1. 依据和适用边界

依据为仓库固定的PTX ISA Release9.4指令/特殊寄存器清单、SM_ARCHITECTURE.md v1.0、tcgen05 Tensor架构v1.0、Tensor微架构v1.1及MALU实际实现说明。本轮继续使用本地已核验资料；没有新增官网访问或硬件实验声明。

本研究面向**能构造合法whole-program的指令发生器**。输出应包括可重放的程序/意图IR、资源与同步依赖、初始化数据、期望观察条件、能力/target及生成证据。它不是把随机指令直接塞给一个SM RTL testbench，也不是已经存在的完整PTX执行器。

“合法”至少有三层：指令形式合法；动态参与者/对象/生命周期合法；程序依赖与环境条件足以让它安全完成。单条Syntax能被打印、甚至能被assembler接纳，都不能证明整程序满足后两层。

当前真实RTL只覆盖PROJECT_EXACT dot-only MALU。其独立A/B/C/D和scale字段、decoded-Ti16、普通F32/F64/INT4/B1等项目能力不能直接开启原生tcgen05形式。vplan应分别登记native-ISA程序、项目扩展程序、静态拒绝用例与未具执行后端的生成测试。

## 2. 发生器必须维护的三种状态

### 2.1 不把issue当作complete

| 状态层 | 作用 | 不允许的替代 |
|---|---|---|
| 建造状态planned | 已选择对象、合法recipe、资源预算和未来cleanup义务 | 提前把程序尚未执行的wait结果作为当前事实 |
| 动态模型状态issued/inflight | 已在程序顺序中发起的操作、可能返回、持有的引用和phase责任 | 认为所有操作按发射顺序完成 |
| 已观察状态observed | 程序执行到匹配wait/phase/响应后能使用的事实 | 用无关barrier或一次try_wait=false释放数据/资源 |

建议用抽象解释器/符号资源模型维护依赖DAG。异步完成可以以任意符合规范和所选环境合同的顺序发生，生成出的默认合法程序应对这些允许顺序都安全。只在一个“生成时假定的执行顺序”上账本平衡，不足以证明程序合法。

例如生成MMA后直接把A引用减到0，然后生成覆盖A的store，即使生成器随后把MMA标为完成，仍没有在程序中建立源可重用的观察条件。正确做法是生成对应A-read/full完成协议，观察后才在后继块允许重用。

### 2.2 控制流与资源状态必须一起合并

资源对象带path predicate。分支merge只保留所有可达路径都成立的definedness、所有权与观察事实；不同路径的allocation不得仅因复用同一个虚拟寄存器名就合为一个对象。循环需要有界迭代与loop-carried状态，不能把第二轮当作第一轮的同一collective/phase。

基线可采用结构化控制流、有限循环、资源平衡的子程序。若某一分支alloc，必须在该路径完成使用和释放，或以显式typed phi把合法allocation传到共同cleanup。正常早exit只有在该路径无未关闭责任时才允许；trap/abort走独立测试类别。

## 3. 资源账本的建议对象

以下为发生器软件模型，不要求DUT具有相同table、字段或队列深度。

| 账本对象 | 最低字段 | 必须保持的不变量 |
|---|---|---|
| kernel/profile | PTX版本、target功能位、native/project入口、seed、环境服务能力 | 未启用形式不能因相邻类型存在而被生成 |
| CTA/cluster | CTA ID/generation、cluster rank、SM/endpoint放置、live threads/warps、退出状态 | peer/DSM目标在整个引用期存活 |
| launch reservation | warp slots、R_SM预算、static/dynamic/reserved SMEM及取整 | 联合admission，全有全无，不按CTA复制整池 |
| memory object | 空间、owner/generation、base/length/alignment、元素类型、defined bytes、版本 | 检查完整range后才进行地址编码/截位 |
| register object | owner thread集合、carrier/tuple、defined mask、pending writer/read-capture | 分片返回全部完成前不得消费整体值 |
| barrier object | owner+offset、layout、init/inval、phase序号/parity、arrival/tx/report义务 | 布局/计数单位/phase不混用，不仅保存一个parity bit |
| TMEM allocation | endpoint/pair、base/nCols、exclusive、generation、permit、引用/在途访问 | release匹配且所有本地/peer访问结束 |
| async obligation | family、issuer、dynamic ID、source/destination引用、commit/group/cutoff、完成单位 | 每一接受责任恰好关闭一次，不被其他family wait冒认 |
| Tensor operand view | kind/shape/major/layout、packing、scale/meta/LUT、source版本 | 逻辑坐标、TMEM坐标、寄存器lane、packed位置分别建模 |
| environment event | 目标服务、延迟/乱序/错误规则、fairness保证、cancel ack | 不凭空制造来自不存在后端的成功响应 |

SM-ARCH-S0配置继承1core=1SM、每SM1逻辑Tensor endpoint、≤8CTA/≤64warp、warp32。SMEM256KiB与TMEM最高288KiB是两个池，R_SM参数化。单CTA可见shared与target/ABI/capability限制单独检查，不能因池有256KiB就给任意target的单CTA256KiB。

## 4. SMEM、DSM与初始化合法性

### 4.1 Launch和地址

生成前先计算static+dynamic+可选runtime reserved及实际取整，联合验证CTA/warp/RF/SMEM预算；系统保留与程序已声明mbarrier不重复计数。不同CTA的offset0指向不同对象，DSM请求显式选择目标owner/rank，不偷用SMEM descriptor位编码任意remote CTA。

每个访问的byte range、自然/指令对齐、类型/carrier、predicated线程集合均由对象产生。普通字节地址、generic地址、SMEM matrix descriptor、tensor map、TMEM lane/column、multimem VA和CFT handle使用不同IR类型，禁止在打印阶段无规则互转。

默认确定性程序对每个消费字节提供已定义初始化，mask/padding根据该形式规则处理。不要求程序读取本来没有定义的padding结果；也不把未初始化TMEM旧D当作数值0。允许未定义值的专用用例须限制其不影响后续地址、参与者或数值oracle。

### 4.2 避免默认程序引入数据竞争

对所有可能并发的重叠访问，记录read/write/atomic、scope/proxy及happens-before。默认合法确定性套件为冲突访问建立明确顺序；不能以“两个bank不同”或模拟器默认先后替代软件同步。vector操作的原子性只按规范定义，不扩大成整vector。

竞态/litmus属于单独套件：保持规范允许的程序集合，并使用允许结果集合或内存模型约束，不能给无顺序读写强加唯一host顺序结果。undefined程序放静态拒绝/诊断套件，不作为正常DUT数值对比输入。

DSM生成要保证目的CTA存活及回收前远端引用关闭；mapa/getctarank地址变换与cluster rank分别检查。CTA-pair不等于任意DSM目标。覆盖同offset不同owner、不同rank、remote延迟返回及owner重用隔离。

## 5. mbarrier v0/v1的生成状态机

### 5.1 对象、计数与阶段

barrier是shared中的8B aligned opaque b64。发生器通过init/arrive/expect_tx/complete_tx/wait/inval的语义操作建立状态，不随机填入其内部字段。barrier对象与普通named CTA barrier分开。

| 维度 | 约束与生成方式 | 关键检查 |
|---|---|---|
| layout | v0/v1与target及使用形式联合合法化 | 不是任意wait/报告都可套任意布局 |
| arrival | v0上限2^20−1；v1上限511，具体操作再查原文 | 不生成“512/1024 arrivals也适用v1”的模板 |
| transaction | 规范tx-count范围为±(2^20−1)；模型保留有符号状态 | 可先以有界非负expected工作构建基线，不错误缩窄规范允许范围 |
| completion unit | bytes、arrivals、16B units等typed单位 | 禁止把数据byte数直接减所有tx-count |
| phase | 保存不回绕的逻辑phase ID，再派生token/parity | parity相等不自动证明观察的是本次工作 |
| primary/conditional | 分别维护pending-arrival、tx与report条件 | 错误可使primary完成而conditional不完成 |
| report | v1 report机制及producer集合相容性 | 成功项不清除本phase已有失败 |

phase推进不能只靠生成器内部减计数：程序必须包含恰当的生产、到达和观察链。提前完成、缺少expect、重复complete、错单位和错误phase属于负例；合法try_wait超时false不是错误。超时false时不使用未定义report值，也不提前标记payload可用。

### 5.2 生命周期和远端限制

每个可达路径在使用前init，普通改作其他用途或重新init前按规范inval并关闭旧引用。不要把普通store当作合法重置active barrier。跨phase复用要防止等待者滞后、错误token、过度推进；有界程序可限制复用间距并强制本phase观察完成。

远端shared::cluster只开放规范允许的arrive/drop/expect/complete更新；remote wait/init/inval保持关闭。消费者等待自己的local对象。multicast复制通知时，对每个目的barrier分别验证owner、相同逻辑offset、layout、phase、计数预算与存活期。

## 6. Proxy、数据可见与完成域

### 6.1 独立的可消费/可重用事实

账本不能只有async_done：

| 事件域 | 能释放/允许的事实 | 不能推出的事实 |
|---|---|---|
| ordinary register/load ready | 对应目的的完整值可读 | 其他memory/proxy顺序已建立 |
| SMEM bank commit | 指定bytes真正落地 | 已满足generic→async发布或所有collector更新 |
| proxy publish | cutoff内规定的可见性已建立 | 任意后发写入或Tensor结果完成 |
| classic cp.async group | 发射thread相应group按规则完成 | TMA bulk/WGMMA/tcgen05都完成 |
| TMA mbarrier/bulk-group full | 该形式对应终点完成 | 其他发射thread的独立操作已完成 |
| bulk wait_group.read | 规定source/tensor-map读取责任结束 | 最终目的写入可消费 |
| WGMMA group | 相应warpgroup工作完成 | tcgen05 MCS/ld/st stream完成 |
| tcgen05 restricted A-read | 相关SMEM-A原源不再被读取 | B已读完、D已写完、TMEM/owner可释放 |
| tcgen05 full MCS | 相应issuer截止前MMA/cp/shift完整责任结束 | 尚未完成的ld/st寄存器返回或无关issuer工作完成 |
| tcgen05 ld/st | 相应warp传输/寄存器片段责任结束 | MMA已完成或跨thread/proxy关系自动成立 |
| Fabric local reads | 已提交操作的相应SMEM源读结束 | try_get目的ready或远端写/归约全部结束 |
| Fabric final primary/report | 对应操作最终责任及报告可观察 | 失败变成正常结果或conditional必定完成 |

### 6.2 程序中的顺序链

发生器应按producer路径选择canonical同步recipe：generic store、经典cp.async、TMA、Tensor load/store、Fabric各自的发布/观察步骤不同。不能要求每种producer都无差别插同一fence，更不能因为全部服务最终共用SMEM就省去proxy规则。

tcgen05跨thread例子应表示：生产与proxy发布→合法发射→commit登记→消费者等待正确phase→所需after_thread_sync→collective ld→wait::ld/结果依赖。before/after_thread_sync按规范参与者添加，不只在发射thread执行一个fence就宣称覆盖所有消费者。

fence/commit的cutoff捕获先前集合，后发操作不能延长它。软件IR记录动态issuer与程序顺序；允许后端乱序完成，禁止后来commit越过未计入的更早MMA。静态程序的issue序号是建模身份，不是强制DUT有相同内部计数器。

## 7. TMEM allocation、permit与CTA group2

### 7.1 分配账本

非exclusive列数从32/64/128/256/512和target联合选择，按32column chunks；同CTA执行序列中的连续申请顺序限制逐次检查。exclusive选择合法32倍数，并根据target限制512/576最大值；576不是全部目标的公共能力。

allocation记录base/nCols/group/exclusive/owner generation。alloc结果发布到SMEM后，使用者还须建立正确线程可见性。relinquish仅关闭后续alloc许可，不释放allocation；不得再生成同CTA生命周期的alloc。dealloc匹配原属性且所有本地/peer访问结束，不能依赖dealloc隐式替自己等待最后一次MMA。

资源压力程序可接近池容量或形成临时alloc等待，但发生器必须预构造解除条件：其他可执行owner能够完成访问并dealloc。不能让同一控制路径先阻塞于第二个alloc，再把释放第一个alloc写在它后面且没有其他释放者。

### 7.2 CTA group2

按S0项目放置约束，even/odd rank一对CTA由device/cluster admission放到可互通的两个不同SM/endpoint，并保证双方存活。group值的kernel一致性、正确最低bit配对、collective参与者、shape/layout与两端allocation同时合法。

alloc/dealloc/permit在两CTA各由规定warp参与；MMA/cp/shift/commit只由合法的一方thread发起一次，不能两端同时重复发相同parent工作。全range/两端所有权在生成模型中原子计划，程序不构造ABBA等待。对称的CTA1 exclusive只锁各自资源，不错误扩大到整个pair。

group2结束必须取得双边相关读取/full/writeback及释放安全条件，再执行匹配释放。任一端先exit而peer仍有引用应在静态checker被拒；peer故障测试走明确abort类别，不与正常合法程序混用。

## 8. Tensor格式、scale、sparse与collector

### 8.1 格式和数值profile

生成单位是合法tuple，包含kind、shape、target、source位置/layout、A/B/D类型、packing、scale、metadata与修饰符，而非分别随机字段后希望碰巧合法。C在native tcgen05中对应D_old；独立C/D格式是项目扩展，不扩大原生表。

native raw Ti16因编码/transpose证据未闭合保持关闭。可生成raw Ti16静态拒绝用例，但不把普通S16位串当合法native操作数。decoded-Ti16使用显式项目入口和范围[-2047,2047]，单独统计，不计native覆盖。

### 8.2 Scale/block配置

| 联合条件 | 发生器基线 | 不允许的简化 |
|---|---|---|
| mxf8f6f4 | 合法A/B低精度tuple，UE8M0，BLOCK32 | 任意scale或BLOCK16 |
| mxf4 | E2M1、UE8M0、BLOCK32 | 看到E2M1就允许所有NVFP4配置 |
| mxf4nvf4 | E2M1、规定UE8M0/UE4M3/UE5M3与BLOCK16/32；追加target约束 | 忽略UE5M3、UE4M3+BLOCK32的sm_107f family条件 |
| A/B scale字段 | native共同scale format；两side数据对象独立 | 项目接口字段独立即native允许两种不同format |
| scale_count与布局 | 按完整logical K、block、sparse/layout recipe求取 | 永久设BLOCK16=4个scale、BLOCK32=2个scale |
| C shift | 单独c_scale_shift=0..15及合法f16/tf32 kind；普通0 | 塞进A/B scale_fmt或把所有kind都开启 |

项目MALU beat每拍不得跨任一A/B scale块边界，同块重复payload一致，logical K和独立offset跨beat连续。此条件属于适配/项目接口；PTX程序生成层使用native布局时，应由布局适配器满足，不虚构为PTX原生总线宽度限制。

scale正例覆盖普通值、最小/最大、特殊编码与合法NaN语义；特殊数值结果不是协议错误。UE4M3 bit7等项目载体非法填充属于项目编码拒绝，不能无条件移植为PTX公开raw布局诊断。

### 8.3 Sparse、LUT与collector

分别保存logical K、packed K和scale索引，metadata只从合法稀疏模式/位置生成。2:4、特殊sparsity、selector和metadata布局按kind/shape/target选择；不要将ld.spcompress、寄存器spcompress、mma.sp的metadata未经适配互换。

对tie/NaN及实现允许的选择，checker使用允许集合或把输入限制为无歧义排序，不能给实现相关tie硬设唯一结果。PROJECT_EXACT与设备profile分开，尤其结构性零遇Inf/NaN不得沿用错误的“所有跳项都无副作用”oracle。

collector fill/use/lastuse/discard建立合法source生命周期，opportunistic命中不作为安全前提。B cache miss/重读仍需旧源有效；A-read后可以覆写旧A而不能破坏active immutable snapshot，B共享同slice时仍受B引用保护。LUT3bit索引/E4M3表与sparse metadata分开，layout/对齐/target独立检查。

## 9. TMA、Fabric与系统场景

### 9.1 TMA

generator fixture显式提供合法tensor map及runtime元数据；matrix descriptor与tensor map不共用对象类型。多维tile/im2col/gather/scatter、OOB/zero-fill、multicast、override与report逐形式合法化。每目的CTA单独维护owner、barrier和expected责任，最后一段才可关闭完整操作。

global→shared常见complete-tx bytes与shared→global bulk-group不能合并。wait_group.read只释放规定读责任。TMA report使用合法v1及允许pattern语义，不把“未报告”当成任意数据/ECC校验通过；report disabled/ignore_oob组合按原文。无TMA后端时，只记程序生成/静态checker覆盖，不能填executed。

### 9.2 Fabric/CFT

fixture包含host建立的u32 leId+u64 resource offset、服务能力与本地shared/barrier对象。保留issue→submit→primary/report观察链；submit属于对应thread且在phase完成前，不能以单个fabric.wait代替最终完成。

get/pullred complete-tx为bytes，put/red为16B units；counted completion的counter为8B对象但需256B对齐，计数按目的data bytes且中间增量不等于终点。multimem目的分别跟踪；成功操作不清同phase的旧失败。report错误是合法功能场景，不能误归为非法程序。

try_pullred.sync要求完整warp相同operand与指定全mask、无已退出thread，不能直接套可用subset collective模板。远端reduce失败/超时不自动重试非幂等副作用，错误分支必须有定义的退出或重试协议。

Fabric、DSM与multimem不是普通pointer LSU的三个别名；不同proxy、地址形式、失败和完成语义分别建模。无系统后端的负例最多验证静态fixture/接口模型，不声称NVLink硬件失败场景已执行。

## 10. Credit、公平性与场景合法性

指令发生器需要提供有界压力和解除依赖的程序，不应把某个微架构队列深度当作PTX合法性的硬限制。64OpTable、normalCQ24/escape8、SMEM RAS64固定32+8×4等是v1.1项目场景参数；可以用于压力目标与模型配置，不能把超过某个在途数量的合法程序直接列作ISA非法。

压力场景可覆盖：同bank热点、返回反压、连续Tensor/TMA与控制竞争、等待alloc时其他ownerdealloc、MCS窗口满时commit可接收、RAS满时barrier完成仍有保留进度。数据量、指令数和假定service delay均有上限，场景最终撤销注入并允许drain。

公平性测试区分发生器输入与环境约束：环境可在有界范围延迟/乱序，必须最终返回已承诺response/ack；若故意永久屏蔽服务，这是故障/abort测试，不是自动判内部死锁。watchdog报告时保存等待图、最老义务、最近事件、service公平性是否兑现，避免只报“程序未结束”。

不能让“增加压力”的动作耗尽程序构造器剩余cleanup预算。为每个alloc/async/phase/peer义务预留必要终结片段或先按完整安全motif预分配大小，再混洗独立motif；最后随机拼几条wait不构成闭合证明。

## 11. End-drain、reset与取消

### 11.1 正常whole-program终结条件

正常程序在所有可达终止路径都提供以下证据，而非仅所有虚拟PC到了exit：

1. 所有异步family已按其机制提交、观察完成，源/目的引用归零；
2. 所有寄存器/SMEM/TMEM结果片段和写回责任关闭；
3. barrier phase与report已被正确观察，复用/改用途遵守inval规则；
4. 所有TMEM allocation匹配dealloc，permit状态不被混作释放；
5. peer/DSM/TMA/Fabric仍可能到达的访问与事件关闭；
6. CTA/cluster满足所需退出协同，最后才允许owner/generation回收；
7. 软件正常结束与系统服务最终排空分别可观察，资源账本无泄漏或重复归还。

并非所有barrier都要在kernel正常结束前为“清零计数”插入额外非法操作；inval要求按规范的复用/普通改写与具体生命周期执行。end-drain检查的是语义义务关闭，不是强制每个内部硬件table全0。

### 11.2 Soft drain和reset

soft drain属于执行/平台场景：停止新kernel/epoch，却允许当前程序完成需要的剩余tiles、load、store、commit/wait/free与barrier。不能把所有后续程序指令停掉后期待正常结束。

hard reset/owner abort在程序外注入时，oracle转为取消/隔离而非旧程序正常数值结果。fixture记录哪些外部副作用已承诺、哪些请求得到cancel ack；旧epoch响应可被隔离，但过滤旧包不等于撤销已经发生的global/remote写。

coverage应区分程序内部合法init/inval/phase切换、系统soft drain、owner abort、硬reset四类。reset之后新owner重用同slot/offset，检查旧返回不被当成新结果；是否在旧程序中途精细恢复不在S0当前能力内。

## 12. Checker、负例与覆盖建议

### 12.1 Checker分层与独立性

| 检查器 | 输入/输出 | 独立性要求 |
|---|---|---|
| syntax/target checker | 指令IR与具体tuple→合法/拒绝及依据 | 不只复用generator的同一个allow函数 |
| whole-program resource checker | CFG、账本对象、HB/phase→无未关闭义务或最短反例 | 独立重走控制流，不相信generator最后打印的balanced=true |
| executable/backend validator | PTX/项目IR→assembler/backend接受记录 | 未安装/未实现时明确not-run，不当pass |
| semantic oracle | 数值、allowed-set、memory litmus、reports→期望观察 | native约束、PROJECT_EXACT、设备bitfit分别选择 |
| liveness/end checker | 事件trace、fairness合同、drain账本→完成/故障分类 | timeout不自动等于DUT数学或内部死锁 |

建议为静态resource checker构建最小mutation测试：从已闭合motif删除一条必要wait、改phase/owner/单位、交换释放顺序、移除peer参与者，确认能拒绝。mutation只改一个根因，避免靠后续语法错误偶然被拒而漏掉真实资源问题。

### 12.2 负例与合法故障分开

| 类别 | 示例 | 预期判定位置 |
|---|---|---|
| 静态非法tuple | BLOCK16配mxf8f6f4、错误target、rawTi16关闭 | 生成配置/合法化拒绝，给section/规则依据 |
| 动态资源非法 | use-after-free、错owner、permit放弃后alloc、peer先exit | resource checker拒绝；不默认运行undefined程序比数值 |
| 同步缺口 | 错phase、未submit Fabric、A-read当full、错tx单位 | HB/obligation checker拒绝或特定负例监测 |
| 合法数值特殊值 | NaN/Inf/次正规scale、稀疏tie | 对应数值/allowed-set oracle，不期望协议拒绝 |
| 合法外部报告 | Fabric失败、TMA有效性pattern、try_wait超时 | 结果/report路径，不能当成非法指令 |
| 项目协议拒绝 | MALU跨block beat、载体填充、length错误 | 项目接口测试，不能算native PTX形式失败 |
| 系统故障 | peer失联、永久服务屏蔽、abort/reset | 取消/隔离合同，区别正常end-drain |

### 12.3 Coverage与交叉

覆盖粒度为具体合法tuple/状态边，而非只数217说明节。建议交叉：

- 地址空间×owner本地/远端×宽度/对齐×definedness×合法scope/proxy；
- barrier layout×phase重复×arrival边界×tx单位×primary/conditional×report来源；
- TMEM mode×nCols边界×CTA group×permit×多allocation顺序×双边存活；
- kind×A/B/D格式×source位置×shape/layout×scale_fmt×BLOCK16/32×K×sparse×target；
- C shift0/1/15×合法kind×enable-input-d×C特殊值，禁用旧D时不得传播原D内容；
- collector miss/hit候选×source版本/重写×A-read/full×B仍在途；
- TMA方向/多维/OOB/multicast/report×barrier/group×尾片段；
- Fabric操作×submit方式×units×成功/失败×source/full×多目的；
- 压力类型×控制保留进度×response乱序/反压×正常drain/abort/reset；
- 资源边从create→live→inflight→observed→free以及故意断边的独立拒绝。

所有cross按合法空间剪枝；不为不可能tuple留下永远无法关闭的bin。分别统计requested/generated、whole-program静态通过、backend接受、实际执行、结果检查与drain完成，不能用generator命中过覆盖点代替DUT executed coverage。被关闭的能力记planned/not-run，不记pass。

## 13. 建议的可重放motif库

以下是语义意图模板，不是可直接汇编的伪PTX；每次实例化仍由合法recipe产生实际指令形式。

| Motif | 安全骨架 | 主要反例mutation |
|---|---|---|
| shared producer→Tensor consumer | launch/init→写A/B→正确proxy/线程发布→alloc结果发布→mma→commit/等待→结果ld/wait→双边安全释放 | 删proxy、错phase、提前覆写B |
| 两阶段double buffer | buffer0使用中供buffer1；A-read仅解锁旧A；full关闭D与B责任；按版本切换 | A-read释放整个slice、旧collector命中 |
| native block-scaled dot | 初始化A/B/scale布局→合法block/K recipe→MMA→full→load | scale_count固定、AB scale fmt不一致、sparse K混淆 |
| CTA-pair resource lifecycle | cluster联合launch→两端collective alloc→一端单thread发令→双边完成/观察→配对释放→退出 | 两端重复parent、单端free/exit |
| TMA→Tensor | tensor-map fixture→expect/发起copy→观察对应完成→Tensor合法读取→full→回收 | 最后payload未落地先完成、bytes单位错误 |
| Fabric report recovery | fixture/layoutv1→issue→submit→primary观察→report分支→定义的drain/重试 | 成功清旧错、只wait.read即exit |
| saturated progress | 多owner已承诺数据→有界回压/热点→release/commit/barrier仍可前进→撤压drain | 占满control信用、无解除者alloc等待 |

每个motif记录前置条件、产生/消费对象、未关闭义务、合法变体、checker规则、coverage bins、结束证明与缩减策略。发生失败时按motif依赖DAG缩减，保留触发语义的wait/phase/target及根因；不能盲删到程序变成另一种undefined问题。

## 14. 主vplan后续审查重点

本轮研究输入已形成；主文尚待实际读取。届时重点核对：是否区分生成器与执行后端；是否具备typed对象/phase/units与全路径账本；是否为每个异步家族定义源/目的终点；是否把v1.1队列深度误当ISA限制；是否构造cleanup而非随意补exit；是否将rawTi16和未实现系统能力维持关闭；是否分开静态负例、合法故障与系统abort；coverage是否区分生成/验证/执行。

本文件提出的测试均为计划。已有MALU回归不转移为SM指令发生器、TMEM/SMEM/TMA/Fabric或whole-program checker的通过证据。

## 15. 主vplan实际只读审查（2026-11-08）

审查对象为SM_INSTR_GEN_VPLAN.md的§6、§9–16、§18–19，以及§24中的MEM/SMEM/SYNC/ASYNC/TMEM/MATRIX/CLUSTER/FABRIC/ENV/LIFE/COV测试点。对照读取了testpoints.json与vplan_features.json，只修改本research记录，不修改主文或JSON。

### 15.1 已落实的资源合同

| 审查点 | 主文/测试点的实际内容 | 结论 |
|---|---|---|
| 三层状态 | §6明确planned、issued、observed-complete分账，允许乱序终点由真实事件推进 | 没有按第N条指令预测完成并释放 |
| 全路径/多顺序 | §6.1、SIG-LIFE-001/003保守CFG merge、有界loop与全部允许prefix检查 | 发生器shadow不是唯一oracle |
| cleanup与回滚 | §6.2、SIG-LIFE-002/004保留尾部预算/执行者、候选回滚、继续必要wait/free | 正常收尾和abort分开 |
| SMEM与launch | §9、SIG-SMEM-001联合CTA/RF/warp/shared预算、typed owner与target单CTA限制 | 不因有8槽就admit超容量CTA |
| mbarrier | §10、SIG-SYNC-001/002/004布局v0/v1、511边界、有符号tx、primary/conditional、false report和对象落地 | 不用无类型done或单parity覆盖全部状态 |
| 完成单位 | §10–11、§14及FABRIC用例显式bytes/arrivals/16B units | 不混淆TMA与Fabric计数 |
| TMEM与permit | §12、SIG-TMEM-001/005记录allocation/permit、属性匹配与释放前完成 | permit不代替free，dealloc不代替前置同步 |
| group2 | §12、SIG-TMEM-006/CLUSTER-001继承S0两个不同可互通endpoint及双边存活 | 不生成任意CTA配对或未定义同SM适配 |
| 参与者/移动 | SIG-TMEM-002/003/004独立warp quarter、同base、pack/unpack、red/spcompress、cp/shift和片段终点 | 不将TMEM地址当byte地址，不用首片代表整体 |
| scale/Cshift | §13、SIG-MATRIX-001/002/006分开AB/scale/BLOCK/Cshift、C只一次、禁用旧D不读 | native tuple继续联合合法化，beat边界属项目适配 |
| Ti16/profile | §13、MATRIX准备与用例明确raw关闭、decoded为扩展，native与PROJECT_EXACT判据分开 | 未开启未知raw编码 |
| sparse/collector | MATRIX-003/005覆盖logical/packed K、metadata/LUT、source版本、A-read/full与重读miss | 不凭collector命中假设提前回收B/D |
| TMA与Fabric | §11、§14及ASYNC/FABRIC用例区分source/full、多目的、report与counter长尾 | 没有将局部完成替代最终完成 |
| credit/公平 | §4配置、§15、LIFE/ENV区分微架构压力参数与ISA限制，保留服务公平假设和escape进度 | 外部永久stall不自动判DUT死锁 |
| reset/drain | §6、§15、ENV-004/LIFE-004记录旧epoch、cancel确认与外部副作用 | 过滤旧包不冒称撤销旧store |
| 覆盖scope | §16分别记录GENERATOR与DUT_SCENARIO，P0不采动态CV，P1/P2不填DUT | 不把计划生成数量变成实际执行覆盖 |

轻量只读元数据复核：25features、106testpoints、75CV；本范围选择的11类feature关联50testpoints，全部PLANNED/NOT_RUN；全表没有P1/P2测试关联DUT_SCENARIO覆盖点。这是计划结构检查，不是50个功能测试执行结果。

### 15.2 SR-1：race-free不保证唯一数值结果——需修正

SIG-MEM-003的expected_result写“race-free程序结果确定”。无非原子data race并不意味着只有一个可见结果。例如两个thread对同一对象执行atomic.exch，分别写1和2，即使都遵守atomic规则，最终值仍可为1或2；浮点atomic累加还可能因合法顺序产生不同舍入结果。

应限定：只有全部相关冲突/归约次序和数值语义均被约束成唯一结果的deterministic子集，才比较单值。其余包括合法race-free atomic并发，使用allowed-outcome、关系或线性化模型，不以一个host顺序模型强制唯一结果。建议同步修订正文§9的概括及SIG-MEM-003在主表和JSON的预期。已通知主笔；待实际修订后追加关闭记录。

### 15.3 SR-2：Fabric arrive/expect模板顺序需明示

SIG-FABRIC-002将模板写为issue→submit→arrive/expect→primary wait→report。原文PTX§9.7.11.3.2（PDF398/印386）明确submit须早于所追踪phase推进，并允许一个合并arrive expect_tx操作覆盖多个Fabric操作。

建议明确为原子arrive.expect_tx，或分别expect_tx并保留必要arrival阻止phase提前结束，最后arrive。若实现把斜杠解释为先独立执行最后一次arrive、后expect，而此时tx=0、completion尚未来到，phase就可能提前结束，后续expect/完成被错配。模板应分别探索completion早/晚于登记的允许顺序，并用单因素负例捕捉提前phase推进。

这是去除模板歧义的澄清项，不宣称原文已经明确要求错误次序；已通知主笔采用一种有证明的规范recipe。

### 15.4 其余审查边界

未发现本轮指定资源/异步/TMEM/MATRIX范围中的其他确定阻断项。计划所写独立checker、多顺序审计、runtime monitor与真实SM观察仍属未来工作；没有用旧MALU通过记录替代发生器或SM验证。SR-1/SR-2的修订状态将在实际读取后关闭，不因主笔答复意图而提前记为完成。

## 16. 定点修订关闭记录（2026-11-08）

按主笔通知进行定点只读复核，没有扩大为新一轮全稿审查：

- **SR-1已关闭。** 主文§9、SIG-MEM-003表格及testpoints.json明确race-free不等于singleton；确定子集仅在允许集合已证明为单例时逐值比对，并发atomic/litmus使用allowed-outcome或可验证线性化关系。vplan_features.json中GEN-MEM-01的stimulus/checks已同步。
- **SR-2已关闭。** 主文§10与SIG-FABRIC-002、testpoints.json明确原子arrive.expect_tx，或先expect_tx且保留pending arrival再arrive；覆盖complete早/晚到。不能先释放最后arrival再登记事务期望。
- **kernel group一致性已明确。** §12补明同kernel中带cta_group的相关tcgen05操作保持group一致，随机发生器不能跨1/2任意切换。此项与S0双端放置及动态pair账本一致。

本轮指定资源、异步、TMEM、MATRIX、cleanup与coverage-scope范围已无尚待修正的确定阻断项。git diff --check未报告格式错误。结论仅说明验证计划合同可供评审冻结；25features、106testpoints与75CV仍是计划，发生器、参考程序及SM/SoC动态测试仍未运行，不据此开启任何执行覆盖或功能通过状态。
