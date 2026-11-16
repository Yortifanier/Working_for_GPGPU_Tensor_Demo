# tcgen05 首版 RTL：接口与集成独立审查

> 历史审查记录。本文早期的WORD32单dot建议、旧engine及旧文件hash不作为当前交付实现描述。当前设计为可配置并行dot阵列、三种recipe、完整RF片段及双端服务；输入与D别名由统一结果tile保护。当前行为及最终源码/仿真证据见 [RTL_IMPLEMENTATION.md](RTL_IMPLEMENTATION.md) 与 `checks/final/`。本记录保留用于说明风险发现和修正过程。

审查/TMEM单元实现：agent2；日期：2026-11-11（UTC）。本文件记录已实际阅读的旧MALU接口/RTL、既有Tensor微架构及新WORD32_REF包的接入约束。首版集成RTL的最终行为需后续对其实际源码与仿真另审；本文不把既有MALU通过结果扩写成tcgen05已实现。

## 1. 已读源码与数值边界

已读 `malu_pkg.sv`、`malu_if.sv`、`malu.sv`、`malu_core.sv`、`malu_decode.sv`，并对照 [MALU实际实现说明](../../malu/RTL_IMPLEMENTATION.md) 和 [Tensor微架构v1.1](../microarchitecture/TCGEN05_TENSOR_MICROARCHITECTURE.md) §12/§17。新包 `tcgen05_pkg.sv` 明确内部normalized command不是NVIDIA native encoding；只实现WORD32_REF路线。不能拿MALU的 `cfg_status()` 代替完整PTX type/kind/shape/target/layout validator。

旧MALU为PROJECT_EXACT单dot引擎。`req_ready`仅IDLE，`op_ready`仅WAIT_BEAT，`rsp_valid`仅RESPOND；response握手后到IDLE，不提供同拍consume-response/accept-request旁路。LANES=4是beat缓存槽，不是四个数值乘法器。共享乘法器为FP64开53×53、关24×24，累加RAM为132×32或20×32；整数事务使用前2words。多给tag位或一次准备多个dot不增加数值并发。

只有profile=0被接受。有限浮点乘积、scale及归约无中间舍入，最后按D格式舍入；不是设备bitfit。NaN/Inf是正常数值结果，不是TC_MEM_ERROR；canonical NaN、±0与渐进下溢按project profile。整数S32输出为低32bit位模式，上32bit清零，不能误作64bit符号扩展。B1/INT4/F64/独立C/D与decoded-Ti16属于更广项目范围，不自动成为tcgen05 native tuple；raw Ti16仍拒绝。

## 2. 建议的单dot适配合同

建议先采用：`LATCH_DOT → READ_SEED → SEND_REQ → STREAM_AB → CAPTURE_RSP → WRITE_D → WRITE_ACK → RETIRE_DOT`。这是新adapter状态建议，不是旧MALU状态名。ctx记录至少保留parent/owner/generation、完整command tag、tile的m/n、目的地址、K进度、AB/scale游标、C和数值配置；MALU短tag只索引这个稳定映射，不截断外部16bit tag后丢失原身份。

| 通道 | 接入条件 | 不得提前做的动作 |
|---|---|---|
| req | 先锁定cfg/C/tag，valid&&!ready期间不变；只在真实握手后建立MALU在途责任 | 用req_valid或预取完成当作MALU已接受 |
| C seed | enable_input_d=false直接提供正式+0，不发起旧D读取；true传未缩放旧D与独立c_scale_shift | 读取未初始化/NaN旧D再丢弃；先重新量化C缩放；每个beat重复加C |
| op beat | 有效元素为前缀，count为1..LANES；锁定两个64bit元素数组、count、scale payload和last | 从32bit word数直接算logical K，或在stall期间推进游标 |
| scale | count≤min(LANES、K剩余、A到块边界距离、B到块边界距离)；同块重复payload相同 | 只按A边界切拍；从accepted SMEM word数重启块；因output stall换scale |
| last | 本beat握手后的累计logical elements恰等K才置1 | 以发送尝试次数、物理read数或内部MUL数决定last |
| response | 状态/数据/tag先捕获到有credit的稳定槽，非OK禁止D写；正确结果等TMEM写ack后再retire dot | 将MALU rsp握手直接当D写入/MMA full/commit通知 |

64bit格式若首版启用，WORD32_REF每元素是两个低word在前的32bit传输；TMEM flat索引跨lane127/新column时仍是同一个元素。OP count始终数64bit元素槽而非32bit memory words。输出按D格式有效位数写入，不擅自把两个native F16 D压在一个cell内；native布局与本project word recipe仍分别声明。

### 2.1 早错误与未接受beat

必须在SEND_REQ之后的**全部适配器状态**观察MALU错误response。BAD_CFG可以不收任何operand就返回；BAD_ENCODING可在首beat的A/B解码时返回。若adapter只有“全部K已发完”才进入WAIT_RSP并拉rsp_ready，会与永不再拉op_ready的错误MALU相互等待。

当非OK rsp_valid出现时，停止/撤销尚未接受的旧op beat（旧interface assertion对此错误abort有明确例外）；错误response即使被下游反压，也不能继续等旧op握手。清掉旧staging、drain/tag-check已发出的SMEM/TMEM读取、消费错误response后才复用映射/发送新dot。不能让旧返回填入下一笔A/B缓存。

正常rsp阻塞期间MALU保持data/tag/status，adapter亦不得改变其写回地址/上下文。单dot首版最简单的策略是在WRITE_ACK前不启动下一dot；以后要重叠计算与写回，需另有结果槽/目的依赖/owner引用的明确credit，不能只看到MALU又ready就覆盖上下文。

## 3. WORD32_REF地址、快照与错误策略

读取 `tcgen05_pkg` 所述row-major recipe后，数学dot应使用 `A[m*K+k]` 与 `B[k*N+n]`。B沿K不是一般连续word；不同格式占word数及64bit高低word要分别乘到地址步长。SMEM地址加法、M*N/K及word-span检查用足够宽的中间量，先查溢出/owner范围再缩到wire字段。

scale_A/scale_B索引按各dot的logical K和独立offset解释，不能按B的物理stride或DMA返回数前进。接口允许字段独立，不意味着原生各种format/scale/BLOCK组合都可用。TF32的project载体低13bit必须为0；不要通过静默清低位掩盖BAD_ENCODING并改变输入数学值。

所有输入都应在D写入可能覆盖它以前捕获或受保护。若A来自TMEM且和D重叠，row-by-row写D可能污染后续dot的A；首版可通过私有输入快照解决，或明确拒绝尚不支持的重叠。不能假设normalized地址各自不同。外部ST/CP/SHIFT或debug port也不能绕过lease在MMA读取过程中改源。

错误命令的D副作用政策要明确：预验证非法cfg/range应在发出memory写前拒绝；tile中后段encoding错误若前面的D已提交，不能宣称全matrix回滚。可选择全输入预验证/输出shadow，或定义owner fault/abort后的部分结果不再可正常消费；无论哪种都要测试和记录。NaN/Inf结果不能走协议fault路径。

## 4. 完成、commit与资源复用

- MCS full必须在所有dot结果写入并获得TMEM ack、所有源/目的责任关闭后推进；MALU结束某dot不是整个matrix full。
- 接受commit的有序点冻结cutoff，新接受MMA不能延长既有commit。前面被回压尚未接收的同issuer命令不能被控制旁路越过。
- A-read的判据是不会再读原SMEM A。可在全部A被不可变捕获且无潜在重读时早置位；首版若保守延到full也应保留语义独立。cp/shift与TMEM-A MMA不应虚构SMEM-A stream项。
- 提交完成通知与外部barrier对象真实更新/ack不同；normalized event可先由外部服务承接，但不得声称仅evt_valid等于PTX mbarrier phase已更新。
- dot/data token在full历史保存且自身引用关闭后可回收，不等软件将来commit才释放；commit metadata/通知payload却必须保留到event ack。不得让commit等待一份只有其通知发出后才可释放的资源。
- 若首版严格顺序执行，issued/prefix跟踪可简化，但空commit、多个issuer、cutoff和错误完成仍需独立验证。序号可采用有界回绕证明或显式exhausted fail-closed，不能用普通无符号比较跨回绕。
- 已接受执行出错也须有终结/abort与诊断政策，避免正常commit无限等一个永不退休的序号；错误不能伪装为正常成功的结果。
- allocator pending等待不能占死唯一命令入口：例如B占满容量、A第一ALLOC pending、A第二ALLOC held-valid阻塞入口时，B的dealloc仍须有可达路径。可对不支持的第二pending请求显式BUSY，或提供经证明的控制旁路；不能等待一个依赖入口后方释放命令的ready条件。

## 5. 建议定向测试（尚未运行集成RTL）

| 场景 | 独立检查与具体见证 |
|---|---|
| 非方形row-major | project fixture M2/N3/K2，A=[[1,2],[3,4]]，B=[[5,6,7],[8,9,10]]，零C，期望[[21,24,27],[47,54,61]]；能检出B stride/转置/mn游标错。该shape是WORD32_REF微型fixture，不冒充native合法MMA shape |
| C无读与Cshift | enableD=false时旧D置NaN/无初始化标记，不能读/参与；F16 A=B=[1,2^-12]、C为F32最小subnormal、s_C=15、D=F32/RNE，精确值在halfway之上，期望0x3f800001；提前量化C会错成0x3f800000 |
| 分拍不变 | K=1/3/4/5/17，LANES=1和4、输入及输出随机反压；分拍前后相同Fraction oracle，count/last仅握手推进 |
| 两侧错位scale | 若启用FP4/BLOCK16，K17、Aoffset15/Boffset0，all A=B=1，A scale先1再2、B scale先1再3，数学和37；检查首beat只能1项，所有边界单独推进 |
| 早错误恢复 | req非法或首A为非法project TF32，下一op beat保持valid且被阻塞；error必须完成、撤旧beat、drain旧fetch；随后合法dot可恢复 |
| 特殊值 | NaN、相反Inf、0×Inf、同/混号零、精确消去及所有允许rounding；整数signed/unsigned、S32wrap/sat、decoded Ti16范围。仅实际启用组合为正常测试 |
| 地址/owner | 最后lane/column、64bit跨column、range溢出、错误owner/allocation、dealloc在途；非法预检查不能产生数据写 |
| 源快照 | A/D交叠或并发ST覆盖源的支持/拒绝政策；A-read之后覆盖原A但当前运算保持私有旧值，B与D责任继续存在 |
| 完成cutoff | long MMA→commit→另一MMA；先发commit只等前者；empty commit、多个issuer和event backpressure；写ack尚未到不得full |
| reset/abort | MALU clear/stream/held-rsp、TMEM写ack、held completion；检查epoch/owner/tag、旧返回隔离，已commit副作用不能假称撤销 |

数值oracle应独立于DUT的decode/round/limb算法；控制测试从真实handshake/写ack/event记录计算，不以输入文本或旧MALU历史计数替代。

## 6. 本轮实现的独立TMEM word服务

已新增 `design/core/src/rtl/sp/eu/tensor/tcgen05/tcgen05_tmem.sv` 与 `verif/core/src/rtl/sp/eu/tensor/tcgen05/tb_tcgen05_tmem.sv`。只读/写一个32bit word，单outstanding、registered read或write ack、响应阻塞时不接新请求；无同拍响应/请求旁路。

COLS必须为32的倍数且32..576，RAM为32banks×(4*COLS)rows×32bit。映射bank=lane[4:0]，row={col,lane[6:5]}=4*col+lane/32。仅col/lane决定地址，owner/generation/byte_addr由上游鉴权/规范化，本服务不重复鉴权。col>=COLS在接触RAM前返回TC_RANGE、rdata0，无写；写按4byte strobes，zero strobe是OK no-op，write ack rdata0。rst_n仅清response/控制并关闭ready，不清RAM。

TB使用 `flat[col*128+lane]` 参考数组，未复用bank/row公式。全空间先写独特值后逆序读，再执行全部16mask、4096固定seed随机访问、越界、response hold、排队请求、三种reset并全空间重读；只读取已初始化数据。reset后的已提交write保留，尚未接受queued write不得执行。

### 6.1 实际工具记录

Verilator5.032，`--timing --assert +define+TCGEN05_ASSERTIONS -Wall`，未使用real/shortreal/DPI。对共享package未用项的UNUSEDSIGNAL/UNUSEDPARAM及异步reset被SVA同步采样的SYNCASYNCNET作命令行豁免；不豁免WIDTH/LATCH等数据/控制警告。初次TB clock的BLKSEQ已改为非阻塞时钟赋值后重编译，未靠关闭该警告通过。

实际日志在 `build/tcgen05/tmem_unit/`。以下仅证明该word-port与列出的测试，不证明allocator、matrix adapter、commit或完整tcgen05集成通过。

| 配置 | 实际状态 | 计数 |
|---|---|---|
| COLS576 | 已通过，SVA启用 | transfers225325；reads149527/writes75794；range4；partial-mask1816/zero-mask123；显式held检查6112cycles；queued1/reset3 |
| COLS32 | 已通过，SVA启用 | transfers16429；reads10263/writes6162；range4；partial-mask1816/zero-mask123；显式held检查6112cycles；queued1/reset3 |

两次编译和运行均实际exit0；源码生成的C++中包含DUT第64/69行的response/request stability断言，未只根据编译命令宣称SVA存在。上述transfers是本word-port TB的真实accepted请求计数（含range请求），不是PTX指令数或完整Tensor用例通过数。

TMEM DUT SHA-256：`a873adda29ee3bda0994e5ba40b1c1b6750d4f1dc478de551816b283d23ec1e2`；TB：`472ac1ea225fb7b5c61ca6de9b85251d2931e6e86415f62d4d60f4ec35b19860`。没有修改既有MALU RTL或旧架构文档，没有commit/push。

## 7. 首次实际engine/top源码只读复核

已读398行 `tcgen05_engine.sv` 与首轮 `tcgen05.sv`，不修改这两个其他agent负责的文件。当前算术/适配结构未发现确定阻断项；还没有本agent运行的engine或完整endpoint数值仿真，不能把下面的源审结论写成集成测试通过。

- engine采用just-in-time beat：MALU在WAIT_BEAT、op_ready为真以后才收集下一beat；每次SEND_BEAT握手后立刻回E_WAIT_MALU。它不会在旧beat仍在数值运算时并行预取下一个beat。因此第2.1节所述一般早错误风险在本结构受控：encoding error出现时engine已经回到能接错误的E_WAIT_MALU；不能据一般建议要求无必要地重写FSM。
- enable_input_d=false路径确实不发TMEM C读取；true先读低/高word，c_scale_shift只交MALU应用。C/D word stride不同在首版被显式拒绝；A-from-TMEM与D的列范围重叠也被拒绝，未偷偷宣称快照支持。
- A游标逐element递增；B游标沿K加N×b_words；m/n循环分别重置B列基址或推进A行基址。scale索引按每dot K/offset和row/column独立基址计算，beat按两侧最早边界截断。
- 64bit先低word后高word；MALU结果完整捕获以后写D，写ack返回后才到DOT_NEXT。最后一次原SMEM A高/低word捕获后才pulse A-read，且后续不会再读A；B/MALU/D写回可以仍未完成。
- memory错误是在消费单个在途response以后本地reset数值核，或在没有memory request时拒绝range；MALU NaN/Inf仍作为STATUS_OK数值结果。engine源码明确不回滚已接受的D写，top有owner fault与后续TC_PRIOR_ERROR隔离，该政策必须保留在交付说明和集成负例中。
- top在有序admission点快照MCS/A-read/ld/st计数，COMMIT注册ack和event通知分离；full在engine写ack完成后推进。错误通过terminal fault而非丢失序号处理，不能把TC_PRIOR_ERROR event作为成功barrier消费。

### 7.1 必须明确的外部合同

**无tag的外部memory response依靠全局flush。** `tc_mem_rsp_t`只有rdata/status，没有request ID、owner或generation；engine依靠跨两个memory端口合计一笔outstanding来关联。因此global reset必须同步flush/隔离外部SMEM endpoint的旧响应，或先完成quiesce。若旧SMEM response能在reset后任意迟到，它可能被新E_MEM_WAIT当作新请求结果；本RTL本身不能识别旧epoch。engine注释已有此要求，本审查已通知主agent：交付说明和TB应遵守此合同，不能宣称任意late response隔离。内建TMEM清rsp的reset合同已在本单元TB实际检查。

**总response流不保证命令FIFO次序。** COMMIT注册可在较早long MMA完成前先返回bus.rsp，因此数据执行有序不等于所有命令response有序。调用方/TB必须按完整tag+owner/generation匹配；不能用第N个response配第N个command。commit event仍受cutoff约束，单独检查。

需保留独立测试：首beat编码错误后恢复；normal/restricted commit与后发MMA；命令response乱序；32bit与64bit非方形矩阵；Cshift的halfway微小见证；block16错位offset；D部分写后fault与owner回收；响应/事件反压和allocator释放控制逃生路径。allocator同owner第二pending ALLOC的HOL问题由专项agent已报主agent，本记录未复测其修正。

首读定位hash：engine `e8b7e2691f89e7864cec531f2c23b66a360a0c73d98a31e70b65e440bdf2f5e9`；top `06be75f64a78d7fa8930625c33cc41acabf7f82eb64129a002c53999ea4b1e58`。这些文件由主agent继续修改，后续最终审查应使用对应新源码/日志。
