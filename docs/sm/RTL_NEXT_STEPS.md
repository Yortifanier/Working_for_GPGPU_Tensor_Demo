# SM RTL 接入与实现顺序

本文是后续编码合同，依据当前工作区的 [tcgen05 接口](../../design/core/src/if/sp/eu/tensor/tcgen05/tcgen05_if.sv)、[命令类型](../../design/core/src/common/tcgen05_pkg.sv)、[endpoint 顶层](../../design/core/src/rtl/sp/eu/tensor/tcgen05/tcgen05.sv)和[既有 SM 架构](SM_ARCHITECTURE.md)。旧架构文档中的实现状态是其发布时的快照；本文件补充新的 Tensor RTL 接入事实，不改写其固定来源哈希。

**当前已有 Tensor endpoint、TMEM、MALU、移动/矩阵执行及相关测试源码；没有完整 SM RTL。** launch、SIMT/ITS、指令前端、实际 GPR/RF scoreboard、core 共享 SMEM 服务端、mbarrier 对象服务、普通 SALU/VALU/LSU 等仍须实现。现有 Tensor 测试模型不能当作这些模块的硬件实现。具体已通过配置以各检查报告为准，本文件不新增测试通过声明。

## 1. 接入边界与首个可运行里程碑

沿用项目 S0：一个 core 对应一个 SM，最多8个 resident CTA owner、64个 warp slot、每 warp32线程；每 SM 一套逻辑 Tensor endpoint，SMEM共享256KiB，TMEM由endpoint动态分配，物理配置上限576列。RF容量继续用32-bit word单位的`R_SM`参数表示。上述是项目组织与预算，不是 NVIDIA 物理 Tensor Core/MALU 数量。

首个里程碑命名为 **SM Tensor shell**：真实 launch/context 表、RF与scoreboard、SMEM和barrier服务，连接现有tcgen05 endpoint，执行有限内部IR程序并正常退出。它必须能运行有真实数据依赖的“准备SMEM→alloc→MMA→commit/等待→LD到RF→dealloc→退出”流程；只从TB直接驱动`tc_cmd_t`不算SM shell已经完成。

完整 SM 在此基础上增加普通算术、分支/调用、线程状态、普通LSU、作用域/proxy和系统服务。不能把有Tensor入口的wrapper称为完整SM，也不把MALU扩充成SALU、VALU或SFU。

## 2. launch、owner与generation合同

### 2.1 SM context表必须保存的记录

| 记录 | 内容与来源 | 生命周期 |
|---|---|---|
| CTA身份 | kernel/launch ID、CTA xyz、cluster ID/rank、owner slot | 从admission到全部异步及远端责任关闭 |
| 版本身份 | owner_generation16、SM reset_epoch32 | generation单调增长；epoch只能在协调reset期间改变 |
| warp/thread映射 | 分配的全局warp slot、CTA内warp编号、有效thread数、每thread状态 | 禁止按owner简单乘固定warp数推导真实驻留 |
| RF reservation | 分配基址/字数、每thread寄存器界限、控制/predicate/CC元数据 | 不能在最后一个普通thread exit时提前释放 |
| SMEM reservation | physical base、visible_bytes、allocation_bytes、owner generation | Tensor、LSU、TMA/DSM、barrier访问同一owner的同一字节对象 |
| Tensor/kernel模式 | 固定capabilities、CTA group1/2、数值profile、peer映射 | 从成功初始化到release，不在运行中随指令任意改变 |
| 返回与回收责任 | command tag表、RF片段责任、barrier/event、peer、外部存储引用 | 全部关闭后才允许slot复用 |

CTA admission先联合预约warp、RF、SMEM、控制/返回信用与cluster条件，成功后再发Tensor context初始化；不能先启动线程再等基础资源。SMEM以owner相对地址对外，物理base只保存在SMEM服务端context表。

### 2.2 与现有endpoint的具体时序

1. 选择空owner slot，确定**非零且大于该slot历史值**的`owner_generation`；预留SMEM/RF/warp，建立cluster路由记录。
2. 将`owner_smem_bytes[owner]`设为本CTA可见shared大小，配置允许的`capabilities`。这些值在整个owner generation存活期间稳定。
3. 发送项目控制命令`TC_CTX_INIT`，携带owner、generation，以及该kernel固定的`cta_pair`模式。当前top在INIT接入时记录`owner_pair`；不能先以group1初始化、等ALLOC时才改group2。
4. 等待对应`rsp`成功后发布CTA可运行。INIT失败则不启动CTA，按失败原因清理尚未发布的reservation。
5. group2的两端CTA都必须成功初始化且peer路由已发布，再允许联合alloc或矩阵操作。`peer_owner/peer_generation/pair_local_is_odd`由可信context/cluster表填写。
6. 退出进入drain，完成所有必要wait、结果消费、dealloc及barrier/peer关闭。随后发送`TC_CTX_RELEASE`，等待成功响应后回收SMEM/RF/warp。

首版SM controller选择对**同一owner**的INIT/RELEASE按响应串行化：release响应返回前不发送该slot的新INIT，不并行复用同一tag或generation；不同owner可以独立前进。这是SM首版的资源回收策略，不是依赖外部规避endpoint中的迟到响应错误。当前endpoint已按generation限定旧RELEASE对issuer/fault的清理，新INIT覆盖group并清新代fault，旧RELEASE不再清除新代group；对应定向回归的实际结果由主报告记录。SMEM/RF/warp的回收仍等待完整生命周期响应与外部责任关闭，不能因为allocator内部owner_live先清零就提前复用物理资源。

generation到`16'hffff`、外部事务序号或tag空间耗尽时，进入明确的quiesce/拒绝新工作路径；不能直接回绕。CTX_INIT/RELEASE是项目集成命令，非PTX新增指令。

## 3. tcgen05_if的端口归属

| 真实通道/输入 | SM一侧的模块 | 接收/完成含义 |
|---|---|---|
| `cmd_valid/ready, cmd` | `sm_tensor_issue_bridge` | 握手后descriptor和规范化命令属于endpoint；不能再从可变RF读取旧operand |
| `rsp_valid/ready, rsp` | `sm_tensor_return`与tag/scoreboard表 | 按身份处理命令结果；COMMIT的成功rsp仅是登记成功 |
| `rf_in_valid/ready, rf_in` | RF source collector | ST的每个32-thread b32片段；accepted后才可释放对应已捕获源的保护 |
| `rf_out_valid/ready, rf_out` | RF writeback adapter | DATA/META/RED片段，只有真实写回完成才能ack |
| `smem_req/rsp` | core共享SMEM服务端 | owner相对、32-bit对齐word访问，支持write和WSTRB；每个返回echo完整64-bit txn_id |
| `event_valid/ready, event_data` | mbarrier/cluster通知服务 | 每个已展开目标的arrive-one或错误诊断；不是普通命令response |
| `peer_cmd/rsp`、`peer_mem_req/rsp` | cluster peer router | endpoint发出的远端控制和数据访问，必须到达匹配peer的service端口 |
| `service_cmd/rsp`、`service_mem_req/rsp` | 同一router的入站路径 | 保留独立进度及返回信用，不经普通warp发射队列绕行 |
| `owner_smem_bytes[8]` | launch/context与SMEM allocator | 可见范围，不是8份独立256KiB SMEM |
| `capabilities, reset_epoch` | target配置与SM lifecycle控制 | 按实际已验证路径开放能力；epoch在非reset运行期间稳定 |

`capabilities`在现有接口中是整个endpoint的一份配置，不是`[owner]`数组。首版SM启动后保持该配置稳定；驻留kernel需要不同功能限制时，由前端在同一固定endpoint能力集合内额外收紧，不能随当前发令owner切换全局capability而改变其他在途工作合同。

所有valid/ready通道在valid受阻时保持payload稳定。不能把“消费者暂时不执行”作为拒收RF写回或完成通知的理由；它们需要在接收原指令时预留空间。

## 4. 指令前端、指令发生器与collective bridge

PTX是虚拟ISA。首版SM使用明确版本的内部IR/项目编码；不声称译码NVIDIA cubin，也不让SM直接解析PTX文本。定义`sm_pkg`中的opcode、操作数绑定、active/predicate mask、owner/warp/thread身份、目标寄存器及动态instance ID，再通过独立lowering生成`tc_cmd_t`。

“指令发生器”在验证环境中负责产生合法程序、数据、schedule与负例；它不是硬件issue模块。既有SM发生器vPlan/testplan是计划，不能以当前手写Tensor TB替代发生器实现或把全部106项改成已运行。

`sm_tensor_issue_bridge`必须完成：

- 用`{owner,generation,warp,dynamic_instance}`汇合alloc/dealloc/permit和LD/ST/wait的warp collective，核对参与者和一致operand。相同PC的不同循环实例不能混合。
- group2管理操作还要取得另一个CTA对应warp的真实到达证据。`peer_participants=32'hffffffff`来自汇合结果，不能为了通过检查而常量填充。
- MMA/CP/SHIFT/COMMIT保留真实single-thread issuer。`thread_lane`不能统一改0，否则不同thread的MCS/commit责任会混到一个stream。
- 捕获全部必需scalar、64-bit descriptor、vector source绑定。描述符来自两个32-bit GPR时，两半必须来自同一动态源版本。
- 保证同issuer的动态接入顺序；COMMIT不能越过尚未被接受的更早MMA。控制逃生队列独立于普通执行资源，但不能借此破坏顺序。
- 输入tail warp、线程已退出、predicate或collective参数不满足规定时，走项目合法化诊断；不把缺少线程补0伪装成合法collective。

首版可以只开放统一控制流IR profile，但必须标明其范围。后续独立线程调度需要per-thread PC、predicate/CC、等待、退出及call/return状态；一个warp共用一个PC不能宣称已实现ITS。

## 5. RF、scoreboard及tag表

### 5.1 必需的side table

`tc_cmd_t`不携带SM的物理GPR基址，`tc_rf_fragment_t.index`也只是相应vector中的索引。SM必须保留下表，不能把fragment.index直接当GPR号。

| key/状态 | 必需信息 |
|---|---|
| transport identity | endpoint、owner、generation、16-bit tag；SM内部另保留IR instance ID |
| issuer | warp slot、真实thread_lane、active/collective实例 |
| cluster/event绑定 | 源CTA的cluster实例与rank映射版本、每目标的owner/generation及barrier offset；持有到全部目标责任关闭 |
| 源绑定 | scalar/descriptor/vector寄存器、已捕获片段bitmap、源读保护 |
| 目的绑定 | DATA/cdata、META、RED各自的RF基址、thread mask、预期片段数及已写回bitmap |
| 结果责任 | command rsp是否已接收、功能状态、commit目标集合及已ack目标集合 |

同一tag不能在仍可能返回RF片段、命令response或event时复用。COMMIT多个目标共享同一tag；释放责任必须按全部目标累计，不能在第一条event后清表。零目标mask没有event，tag表按零event责任处理，但不能将registration ack写成MMA full-done。

### 5.2 RF流的可执行规则

LD/ST的各shape/repeat先计算每thread的寄存器数及DATA/META/RED各自长度；接受前一次性预约完整目的范围和返回责任。当前流每片含32个thread的一个b32寄存器；ST送入的index、kind、mask、last、tag及owner generation都须匹配。

`rf_out_ready`的首版定义为：该片段所覆盖的RF字在当前握手边沿真正提交。若RF端口需多周期写入，adapter可保存一个片段并保持ready低，到最后一部分写回完成时才ack。不得只入一个临时FIFO就ack，然后让endpoint的wait::ld早于约定的RF写回完成。若未来要允许早ack，必须增加等价的独立完成合同并验证，不能只改ready逻辑。

scoreboard在完整目的vector写入、身份匹配且命令成功后发布ready；cdata、metadata和redval分别追踪。ST的源可以按已捕获片段释放读保护，但ST完成仍须等所有TMEM写ack。中途错误可能已写部分RF/TMEM；目的必须标poison/未就绪，并交给owner错误处理，不能靠后续依赖“碰巧未读”关闭测试。

先实现一个RF返回仲裁器，让Tensor、普通执行单元和LSU都通过明确的writeback信用请求端口；不要让Tensor ready取决于等待该结果的warp是否被scheduler选中。

## 6. SMEM与TMEM地址合同

### 6.1 共享SMEM服务端

`tc_mem_req_t.byte_addr`在SMEM路径是**目标owner的相对字节offset**。SMEM服务端用`{owner,generation}`选择base并检查可见范围，再访问全SM共享数据池；不同CTA的offset0不能别名。服务端对返回echo完整64-bit txn_id，不自行截成8/16/32位。

现有Tensor memory fabric已经进行owner/range检查和word仲裁，但没有实现core共享SMEM的物理数组、launch分配、通用LSU/TMA/barrier服务。TB内SMEM数组是外部服务模型，不能复用其host过程冒充可综合SMEM。

第一版可以用有界、串行的word服务实现功能闭环，明确低于拟议64-bank带宽；接口不承诺固定延迟。随后按微架构细化64-bank、fragment assembly、byte mask、RMW和公平仲裁。先确保所有client争用同一容量和真实对象，再提高服务率。

native ALLOC会向`smem_addr`写返回TMEM地址，group2另写peer CTA的`peer_smem_addr`。这些地址是shared目的位置，不是返回GPR号。服务端必须处理write和WSTRB；只实现SMEM read会破坏alloc。弱store可见性、其他warp消费指针和proxy顺序仍需按程序的同步规则建立。

### 6.2 TMEM对象

TMEM属于Tensor endpoint，不从launch的SMEM池划出。对原生TMEM地址，bridge解析lane/column并核有效位和范围；不能把它当普通byte pointer送LSU。MMA、scale、metadata和LUT地址交给已选layout recipe，不在SM bridge重新做一套线性映射。

SM layer保存live allocation返回值、匹配的nCols/exclusive与owner generation。只在已经排除本地/peer在途访问后请求dealloc；`relinquish_alloc_permit`仅放弃未来申请权，不释放live TMEM。不要在CTA launch时为每个CTA复制整个TMEM，也不要因TMEM容量独立就忽略Tensor返回/SMEM端口争用。

## 7. cluster peer与mbarrier

### 7.1 peer router

router维护`{cluster,CTA rank}`到`{endpoint,owner,generation}`的映射，并验证同一pair的rank只相差最低bit。`pair_local_is_odd`由这个映射导出，不能由普通程序伪造。两个CTA的INIT、peer active发布及退出必须由cluster admission协同。

控制通道仅供内部PAIR_PREPARE/PUBLISH/ROLLBACK、FREE阶段和PIN/UNPIN等服务；普通IR不能直接注入这些opcode。保留入站service与出站execution的独立请求/响应空间，不能让自己的出站请求占住接收peer访问必需的返回通道。

当前group2资源事务和parent/child PIN由Tensor模块承接；SM仍负责peer lifetime和路由。parent完成前remote PIN、未完成peer memory response或event引用都能阻止owner回收。出站请求被router接受只转移责任，不证明peer side effect已经完成。

### 7.2 mbarrier服务

SM必须新增真实的barrier agent和8-byte对齐shared对象访问路径，保存init/inval、phase、expected/arrived以及相应wait/report责任。对象内部编码是项目实现，不冒充NVIDIA opaque b64编码；它必须与同一SMEM字节对象及原子更新互相一致。

现有`tcgen05_commit_fanout`已经把multicast展开为逐目标event：

- `status==TC_OK`时`arrive_count=1`；非OK诊断为0，不能更新普通barrier计数。
- `target_valid==0`使用本地owner；为1时按`target_cta`映射到cluster目标CTA。multicast输出的`cta_mask`已经onehot，**barrier agent不能再按原mask二次展开**。
- `restricted`表示SMEM-A read责任，只允许释放相应源使用条件，不发布D/MMA full-ready，不清整个allocation或CTA owner。

首版`event_ready`选择在目标barrier更新真正提交后才ack。若router/queue需要提前接收，必须先取得独立的目标owner/generation pin，并持有到实际RMW完成；不能在metadata入队后立即允许目标SMEM复用。mbarrier更新服务需要独立进度信用，不等待消费该barrier的warp先恢复执行。

`tc_event_t.owner/owner_generation`标识源命令owner，`target_cta`只有cluster rank，没有目标owner generation或cluster ID。SM return/event side table必须用源身份和tag找回提交时绑定的cluster实例及目标版本，不能拿当前可变rank表把迟到event路由到复用后的CTA。接收方确认目标仍属于该绑定generation后才更新barrier；路由或目标生命周期出错走诊断/abort，不伪造成功arrival。

普通tcgen05 fence、mbarrier、CTA/warp同步与`fence.proxy.async`分别实现。当前项目Tensor fence可能采用保守的本地完成排序；SM不得因此声称已建立跨thread、generic/async proxy或跨CTA的全部可见性。

## 8. 错误、重试、退出与reset

| 返回/事件 | SM行为 |
|---|---|
| `TC_OK` | 按该命令的真实完成域更新账本；COMMIT rsp仍只为登记ack |
| `TC_BUSY` | 项目重试/资源等待；保留动态指令和源snapshot，让其他warp、free和完成服务前进 |
| `TC_NO_PERMIT/TC_ORDER/TC_BAD_ALLOC` | 合法化/资源协议错误；不能默默换地址或nCols重发 |
| `TC_BAD_OWNER` | 拒绝旧generation或错误owner，不能把旧包改成新generation重试 |
| `TC_MEM_ERROR/TC_MALU_ERROR/TC_PRIOR_ERROR` | 保留失败身份、标poison、隔离owner并关闭或取消引用；禁止无条件重放已可能有副作用的指令 |
| `TC_UNSUPPORTED/TC_BAD_CMD/TC_RANGE` | 明确项目诊断，回传前端/运行时；不称为PTX必有的硬件trap |
| `TC_SEQUENCE_EXHAUSTED` | 停止新接入并进入协调quiesce，不回绕重用 |

有错误的commit事件`arrive_count=0`可能意味着正常barrier永远不会到达。SM必须提供错误唤醒/owner abort路径，不能让受影响warp继续等一个不会成功的普通phase，也不能伪造arrival解锁。

正常drain停止新launch，但允许现存CTA完成结果LD、commit/wait、dealloc、permit及退出。保持RF写回、peer入站、SMEM返回和barrier服务可运行，不能用“停止全部cmd”制造自死锁。每个owner的drain账本覆盖Tensor之外的普通LSU/TMA/DSM等责任。

hard reset之前先停止新launch，协调peer和外部存储drain/cancel，确认旧请求不会再写新资源。在reset保持期间设置新的`reset_epoch`，再解除reset；运行期间不改变该输入。现有fabric外部64-bit ID包含epoch、sequence及lane身份，可过滤迟到不匹配响应；**过滤响应不等于撤销已发生或将发生的外部write**。

## 9. 待写模块与目录

以下路径是新实现计划，尚未创建这些SM模块。

| 计划路径/模块 | 第一版职责 |
|---|---|
| `design/core/src/common/sm_pkg.sv` | IR、launch/context、RF绑定、错误/epoch、scoreboard类型 |
| `design/core/src/if/cp/sm/` | launch、drain/abort、kernel完成与配置接口 |
| `design/core/src/rtl/cp/sm/sm_context_table.sv` | 8 owner、generation、resource与cluster记录 |
| `design/core/src/rtl/cp/sm/sm_launch_ctrl.sv` | 联合admission、INIT/RELEASE顺序及回收状态机 |
| `design/core/src/rtl/sp/rf/sm_regfile.sv` | 参数化RF、32-thread片段读写与端口仲裁 |
| `design/core/src/rtl/sp/rf/sm_scoreboard.sv` | 源保护、完整vector目的、poison和tag side table |
| `design/core/src/rtl/sp/sm/sm_ir_frontend.sv` | 版本化IR读取、译码及源/目的绑定，不解析PTX文本 |
| `design/core/src/rtl/sp/sm/sm_tensor_issue_bridge.sv` | 动态collective汇合、descriptor snapshot、有序cmd与ST片段 |
| `design/core/src/rtl/sp/sm/sm_tensor_return.sv` | rsp/RF片段/commit多目标责任与scoreboard唤醒 |
| `design/core/src/rtl/sp/lsu/smem/` | shared allocator、真实word数组、byte写/RMW、barrier/proxy服务 |
| `design/core/src/rtl/mss/cluster/` | endpoint路由、rank/owner映射及目标pin transfer |
| `design/core/src/rtl/cp/sm/sm_tensor_shell.sv` | 第一阶段闭环集成，实例化现有Tensor endpoint |
| `design/core/src/rtl/sp/sm/sm_warp_scheduler.sv` | warp/thread可运行、等待、分歧及进度选择，后续形成完整SM |
| `verif/core/src/rtl/cp/sm/`与对应filelist/flow | IR程序、RF/内存oracle、协议monitor与真实运行证据 |

## 10. 代码顺序与逐阶段验收

| 阶段 | 必须写出的具体结果 | 进入下一阶段的验收条件 |
|---|---|---|
| S0 类型/合同 | `sm_pkg`、launch与内部IR格式、tag/RF绑定表；冻结RF容量参数和SMEM分配粒度 | 各字段能直接映射当前`tcgen05_if`；source/RF/owner/epoch不缺身份 |
| S1 context/存储 | context表、SMEM分配与真实数组、INIT/RELEASE controller | 两CTA offset0隔离；资源不足不启动；release前不能复用；generation/epoch负例 |
| S2 RF/bridge | 真RF与scoreboard、单warpIR frontend、Tensor issue/return | ST所有片段捕获；LD/cdata/meta/red全片写回才ready；response乱序按tag正确匹配 |
| S3 单SM shell | 一套真实barrier agent、受限IR程序的完整launch→Tensor→退出 | 真实SMEM→MMA→commit更新→wait→RF消费→dealloc闭环；不是TB直接poke结果 |
| S4 双SM/cluster | 两个shell、peer router、双端admission与barrier目标pin | group2 alloc两端同列、分片MMA、odd issuer、远端busy/dealloc、multicast逐目标一次与正常回收 |
| S5 普通执行与控制 | SALU/VALU/convert、branch/call/exit、普通LSU与线程等待 | 源/目的/CC/predicate依赖，分歧与同PC不同实例；未支持ITS时capability明确关闭 |
| S6 内存模型/系统 | proxy、scope、atomics、TMA/DSM及后续SoC服务 | 有真实可见点及错误/取消模型的litmus、资源压力和迟到返回测试 |

每阶段保留独立结果，不能因S3完成就宣称S5/S6完成。将真实测试映射到既有SM vPlan/testplan的SIG/CV，逐项增加证据；没有执行的用例保持NOT_RUN。

优先新增以下有故障触发条件的检查：held RF阻塞下仍能接受完成控制；COMMIT在普通工作满载时前进；同owner旧RELEASE响应不影响新generation；peer PIN存活时释放被阻止；multicast中途反压不重复arrival；旧epoch响应不会写新RF/SMEM；错误事件不推进普通barrier；两个CTA声明的SMEM总量超池时只admit可容纳集合。

## 11. 开始编码前必须固定的有限事项

先以项目选择固定内部IR版本、`R_SM`/RF allocation granularity、SMEM per-CTA可见上限、最初支持的控制流profile、barrier对象实现及router公平/信用约束。它们不是要求用户重新批准已有工作，而是对应代码和测试需要的明确配置记录。

物理Rubin每Tensor Core的MALU数量仍不能由PTX指令shape或项目`DOT_ENGINES`参数倒推。SM接入只依赖已验证的功能和信用合同；后续算力配比、带宽与PPA另立测量，不因增加SM wrapper就宣称达到Rubin吞吐。
