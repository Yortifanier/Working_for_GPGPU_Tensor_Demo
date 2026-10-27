# SMEM 本体：容量、bank 服务率、ECC 与信用独立审查

角色：agent2；日期：2026-10-27（Asia/Shanghai）。审查对象为root拟定的v1.1方案：每endpoint 256KiB有效SMEM，64个32-bit 1R1W physical banks，每bank1024rows；Tensor最多两路128B/cycle请求，LSU/TMA/barrier/peer共享。本文不修改主稿/RTL，不执行commit/push。

## 1. 总评与必须写清的条件

该容量和地址映射在数学上自洽，没有“64 banks无法提供256B/cycle”的阻断。**256B/cycle只可能是无冲突、无其它读竞争的理想聚合读峰值**，不是每个client独占256B，也不是任意两笔128B都能同拍完成。

v1.1必须明确：owner到物理地址的映射、每bank读/写独立仲裁、同址读写规则、ECC物理容量、partial-write/atomic的RMW锁、返回buffer预约，以及barrier/peer控制逃逸信用。否则名义1R1W或队列深度可能掩盖功能错误与进度环。

这64个bank是本项目物理选择。CUDA资料常见的32-bank软件性能模型不能被套成项目必须只有32个物理bank，也不能反过来声称本项目64-bank实现改变了PTX共享地址空间语义。

## 2. 容量与地址映射

`64 × 1024 × 32bit = 2,097,152bit = 262,144B = 256KiB`。

对**owner转换后的物理byte address paddr**：

- byte select=`paddr[1:0]`；
- bank=`(paddr>>2)&63 = paddr[7:2]`；
- row=`paddr>>8 = paddr[17:8]`，前提是已验证`0≤paddr<2^18`。

该映射一一覆盖256KiB，没有遗漏或额外地址。连续256B包含同row的64个bank，跨256B时row递增。

### 2.1 owner转换不能省略

不同CTA的shared offset可以都从0开始。若直接对CTA相对offset使用上述公式，多个resident CTA会错误alias同一物理数据。因此需先执行等价转换：

`paddr = smem_base[owner,generation] + cta_relative_offset`，

并检查offset落在该owner的allocation内、加法无溢出、结果落在总容量内。亦可采用显式分区或等价映射，但必须有同样隔离保证。peer请求使用destination owner的映射；旧generation返回不得写入复用后的CTA区域。

256KiB是endpoint总有效容量，不能同时为8个owner各承诺256KiB；CTA admission/驻留信用要与SMEM分配总和联动。SMEM matrix descriptor的CTA可见编码与内部物理base不能混成同一地址对象。

## 3. 端口与峰值服务率

每bank每cycle至多一次32-bit读、一次32-bit写。因此理想最大读=64×4=256B/cycle，理想最大写也为256B/cycle；1R1W允许二者并行，但这取决于宏和同址行为被实现正确。

| 请求模式 | 理想本周期能力 | 必须保留的限制 |
|---|---|---|
| 两笔128B连续对齐读，分别命中banks0–31/32–63 | 合计256B读 | 没有其它读占用；response与重组路径也接收64word |
| 两笔128B读命中同32-bank集合但不同row | 最多完成32word=128B，其余重放 | 不能因有两个请求端口就凭空增加bank R端口 |
| Tensor占满64个R端口 | Tensor可达256B | LSU/barrier/peer等额外读必须等待或替代部分Tensor读 |
| 64个full-word TMA写与Tensor读不同word | 理论上可同时256B写+256B读 | 写入编码/互连需满足；proxy/lease依赖仍有效 |
| 同bank同word读写 | 取决于定义的RDW/bypass/序列化 | 不依赖SRAM宏未指定的read-during-write结果 |
| partial byte/half store开启word ECC | RMW事务 | 额外读周期、写周期和锁会降低普通吞吐 |

地址swizzle、matrix recipe、warp散布访问和不对齐请求会改变bank占用。接口宽度只表达可接收/重组能力，不能保证每种layout都获得同样服务率。相同word的只读请求可以在不破坏请求版本/权限的前提下广播；不同row不能广播。

持续读写峰值还要求每bank各有足够的ECC、数据crossbar和返回吞吐。若64个读口只共享一个每cycle处理一word的ECC decoder，聚合读峰值实际只有4B/cycle，不能仍宣称256B。

## 4. ECC 数据宽度与面积口径

若每32-bit word独立使用SECDED，Hamming校验位至少6个（2^6≥32+6+1），加overall parity共7 check bits，物理codeword39bits。

| ECC组织 | 有效容量 | 数据/ECC原始位容量 | 微架构影响 |
|---|---:|---:|---|
| 无ECC | 256KiB | 256KiB | 不提供ECC能力 |
| 32+7 SECDED | 256KiB | **312KiB** | 每bank codeword独立，最符合当前32-bit bank边界 |
| 宏取整到32+8/40-bit | 256KiB | **320KiB** | 第8check/填充位用途须说明，不能称数学上需要8个SECDED位 |
| 64+8 SECDED | 256KiB | 288KiB | 每codeword跨两32-bit word，partial/单word更新会耦合bank并引入额外RMW，不能免费替换32+7 |

上述仅是数据和check位，不含锁、队列、tag、冗余列、测试或ECC编解码逻辑，不是面积/功耗数字。若v1.1只冻结接口、不实现ECC，必须明确ECC关闭；若作为默认可靠性能力，资源表应计入312KiB或实际宏取整值。

单bit纠正后读返回应携带正确数据及所需状态；双bit不可纠正必须通过明确错误/poison路径完成请求，不能静默返回损坏数据，也不能永远扣住bank锁或response信用。

### 4.1 后台scrub的旧值覆盖风险

corrected read形成的scrub任务若晚于同word的新写回执行，会把旧数据重新写回，造成丢更新。需在任何新写入时取消匹配地址的pending scrub，或用版本/条件校验；只在无intervening write时scrub。可用每bank小scrub队列比较地址实现，不必无依据为所有word添加巨大版本RAM。

RMW已将纠正数据合并成新的写入时，不再对旧值排scrub。scrub必须低优先、可取消、有有限队列；不能占尽正常写或atomic完成的保留信用。

## 5. partial write、atomic和barrier RMW

### 5.1 partial write

开启per-word ECC时，byte/half store不能只改数据byte而保持旧check bits。必须读取并纠正旧word→合并byte mask→重新编码→写回，并在该序列期间保护word不被另一writer改动。若依赖宏原生partial-ECC写功能，应以实际宏保证替代此RMW，不作默认假设。

完整32-bit写一般不需读旧数据；不应把全部TMA full-word写都强制成RMW而无解释降低带宽。普通byte-enable且无ECC时是否需要RMW取决于所选宏。

### 5.2 原子和64-bit对象

32-bit atomic需要读、计算、写及唯一linearization point（建议commit写确认）。64-bit atomic或64-bit mbarrier状态涉及两相邻32-bit banks；需同时获得两word的锁、读/写资源与返回信用，保持整体原子性。8-byte aligned对象不会跨非法word边界，但仍跨两个bank。

**禁止**先持有bank A锁再无限等待bank B；两bank请求应全有或全无grant，或按严格全局顺序加锁并有明确撤回/进度规则。不能把两个独立32-bit提交称为64-bit atomic。

RMW arithmetic能力要单列。一个全局共享atomic ALU若II=1，只能提供每cycle一个原子算术操作，不能因为有64banks就宣称64atomics/cycle。64-bit操作若分两次32-bit运算，锁和信用必须持有到两部分都完成。

### 5.3 完成不能只指入队

LSU store/TMA arrival/barrier更新的ack必须对应其约定的写入/可见性点。收到request、银行grant或写入中间buffer，不自动等于SMEM数据已对Tensor async读取可见。跨proxy fence与mbarrier责任仍在相应系统接口保留。

## 6. 队列、返回信用与冲突重放

以下是进入实现需要冻结的计划，不把任意示例深度当作已经证明的充分容量。

| 资源/状态 | 最低信息与原则 | 信用释放点 |
|---|---|---|
| ingress事务记录 | owner/generation、client/tag、byte范围、op/size/mask、各word pending/issued/done | 整个事务返回或明确错误终止 |
| bank read请求 | 物理row、transaction ID、word slot、broadcast引用 | read数据被其已预约response位置接收 |
| bank write请求 | row、word data/mask、owner/tag、顺序/RMW属性 | 约定写commit/ack |
| RMW/atomic记录 | word或word-pair锁、旧值/operand、状态与预留write/response槽 | 最终写commit及结果捕获 |
| response重组 | 每个已发read有唯一word位置与完成bitmap；返回可乱序 | consumer valid/ready握手或下一级已承担所有权 |
| control/escape池 | barrier/完成通知和peer协议有保留request+response空间 | 相应控制ack，不依赖普通数据队列腾空 |

root现有32个outstanding tags与8×128B response staging是不同资源：tag存在不等于data返回有空间。若内存/互连可回压，允许更多未返回事务，但每次实际bank read issue前都应预约返回位置；若返回不能回压，则必须在接受对应请求时预约全部必要数据槽，不能只在tag满时停止。

两路128B请求可各包含32个word。冲突重放必须只重发未issued部分，不能重复已提交atomic或已完成word。partial replay的mask、实际完成数和响应标签必须跨仲裁周期保持；超时不等于可无条件再次执行非幂等操作。

建议每bank至少有一个可完成的RMW记录，并在其开始读前预留最终write/ack空间。具体可采用64个分bank记录或较小共享池；较小池会限制并发，但不是功能错误。深度必须写入资源表，不能只写“有队列”。

barrier/peer控制可使用独立小队列和全局信用池的保留份额。保留份额不是额外bank端口：其grant必须抢占或公平分享对应读写服务率，因此会减少Tensor有效吞吐，属于正常预算。

## 7. 必须防止的进度环

| 隐藏环 | 必须采取的措施 |
|---|---|
| Tensor持续占用读口→mbarrier更新永远等读→Tensor命令/SMEM区域无法退休 | control保留信用+有界年龄/公平grant，不能永久Tensor最高优先 |
| 所有response槽被普通数据占满→barrier/peer ack不能返回→数据依赖无法释放 | 分离控制返回通道或保留response slots，不能仅拆request队列 |
| RMW读已开始并持锁→无write槽→排队writer等同锁 | 开始前同时预留write与completion资源 |
| 64-bit atomic各先持一bank→互等另一bank | word-pair原子预约/无hold-and-wait |
| peer请求持本地bank锁并等待远端数据/ack→另一侧反向持锁等待 | 不在等待外部资源时持本地RMW锁；先缓存所需operand和返回信用 |
| ECC scrub/纠错处理占满write/control池→正常更新和错误返回停住 | 可取消低优先scrub；不可纠正错误有独立可完成路径 |

公平性需要同时覆盖bank grant、共享atomic ALU、response重组/发送和peer/barrier出口。仅对入口轮转，不能证明整个请求有界完成。下游无限停顿时系统允许回压；不能把无条件有界latency当成可保证性质。

## 8. 验证与接受标准

1. 地址穷举/性质：所有2^18有效byte恰映射一次；owner范围隔离、generation错误拒绝；跨row、bank63→0、不对齐尺寸逐byte正确。
2. 服务率：两路无冲突128B可在所定义pipeline中持续得到64word/cycle；相同bank集合不同row只能按真实端口重放；加入LSU/TMA/barrier竞争后统计峰值下降，不能仍报独占值。
3. 同址读写：宏前后仿真或明确模型校验read-old/read-new/bypass；byte RMW与其它writer、32/64atomic混合不丢更新或撕裂。
4. ECC：每codeword逐bit单错纠正、双错检测、partial写后check一致；scrub与新写竞态、错误时资源释放。
5. 协议/credit：响应乱序、任意consumer停顿、队列满、atomic/RMW结束、控制逃逸和peer交叉压力；assert每次bank issue已有返回credit、锁不泄漏、重放不重复提交。
6. 进度：在下游公平响应假设下，barrier/peer/已接受RMW能够完成；不要求在下游永久不ready时无条件完成。

没有新的SMEM RTL或综合结果。本记录可支持v1.1的可落地计划与风险清单，不支持SMEM已经实现、256B所有client同时获得或某频率/面积达标的声明。

## 9. v1.1 主稿只读复核结论

已实际读取 `TCGEN05_TENSOR_MICROARCHITECTURE.md` v1.1 的§7.2–7.9、相关接口/完成条目及§22资源表。**本轮未发现必须修正的容量、位宽、端口或信用预算矛盾；上述建议的关键边界已进入正文。** 本结论为文档审查，不是新SMEM RTL验证或无死锁形式证明。

复核项目如下：

- 64×1024×32-bit为256KiB有效数据；physical p先经过owner/generation转换，再用bank p[7:2]、row p[17:8]、byte p[1:0]。8个owner共同分享总池，launch前完成连续分配和驻留信用，未按每CTA重复承诺容量。
- 两路128B理想读峰值明确受bank集合与所有client竞争限制；满256B Tensor读已占全部R端口。不同row的一读一写和同word旁路/锁规则分开，未凭1R1W增加额外读端口。
- 默认ECC关闭；可选32+7 SECDED的理论阵列312KiB、40-bit宏取整320KiB均正确。partial ECC写走RMW，scrub被同址更新取消/重验，且不以静默损坏数据完成不可校正请求。
- RMW有4×64B记录、64×32bit bank锁；64-bit atomic/mbarrier一次预约双bank、写回、返回和visibility资源；128-bit CAS明确需四bank且尚未实现时关闭capability。最老多bank请求可阻止新冲突锁以等待holder drain，不依赖碰巧同时空闲。
- 已接受RMW在开始前取得visibility与response责任，锁在实际提交后释放而不等待远端consumer取ack。collector失效sink不等待Tensor CQ或消费指令，避免持锁等下游反向释放。
- 64个assembly slots的Tensor32+LSU8+TMA8+peer8+control8保留份额合计正确；数据16KiB与metadata2KiB、客户request Q8.5KiB、owner512B/RMW256B/locks256B、notification512B/scrub128B均与条目乘法一致。32个Tensor tags、8个client staging与服务端32个保留assembly slots已区分。
- 新增64×32B=2KiB producer tracking，issued/bank-commit/visibility前缀与两组8-bit完成窗口分开。`issued−visibility_prefix<8`防止尚未失效确认的孔洞被窗口复用；fence在有序admission捕获cutoff，后发写不延长已捕获集合，producer回收检查在途/失效/fence引用归零。
- control有独立request/response信用及eligible年龄优先机会；32-cycle门限未被误写成所有请求固定完成时限。TMA/peer和mbarrier真实SMEM对象路径、init/inval及owner退出drain均有责任说明。

后续RTL仍需实现并验证这些责任，尤其跨bank原子all-or-none grant、partial replay不重复副作用、不可回压返回的足额预约、scrub/新写竞态，以及producer序号环绕与cutoff比较。有限队列可在下游阻塞时反压；正文没有把持续256B、多client同时峰值或无条件有界完成作为已经实现的保证。

本次未修改主稿、RTL、测试结果或其他仓库文件，未执行commit/push。
