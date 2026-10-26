# PTX ISA 9.4 tcgen05 架构规范核查

核查角色：agent1；日期：2026-10-26。仅记录体系结构可见对象、操作、参与者、合法性、地址/数据布局及顺序/完成契约。**不设计微架构，不据PTX推断乘法阵列规模、pipeline、调度器、内部bank/端口、累加器实现或吞吐。**

## 1. 固定原件与证据边界

主来源[P1]：用户上传 `/workspace/attachments/4971c15f-29fd-4875-95d3-ed0c693d3482/ptx_isa_9.4.pdf`。封面为 *PTX ISA, Release 9.4, NVIDIA Corporation, Jul 17, 2026*；1002个PDF物理页；SHA256=`4be2905e240b70a8b176b4d6fb162714f2fc361a9503572d848ff723abf289c3`。本轮实际读取本地PDF及其`pdftotext -layout`抽取，复用前轮已经渲染核对的关键表格。

引用格式“PDF699/印687”分别指阅读器从1开始的物理页和原文页脚。相关正文满足PDF页=印刷页+12。`§9.7.18`覆盖PDF699–846/印687–834。不得把当前网页中变化的表编号替换为此上传原件的页码。

本文事实均为[P1]中的软件/指令契约。以下内容另外隔离：

- 旧`mma.sync`/`wgmma.mma_async`属于不同指令家族，不能无标记继承其类型、warp collective、精度或目标条件。
- 仓库MALU的`PROJECT_EXACT`、独立C输入、shared multiplier及分段累加存储是项目选择，不是tcgen05架构规范。
- 产品名、SM target、PTX release是三个维度；本文件不把sm_107a/f直接等同于某个营销产品，也不从K或格式位宽推算算力。

## 2. 核心体系结构对象

| 对象 | 可确定的架构含义 | 证据 |
|---|---|---|
| TMEM | 专用于Tensor操作的片上二维存储，横向row称lane，纵向称column | §.1，PDF699/印687 |
| TMEM cell | 在sm_100a/sm_100f的说明中每cell32bit，模型为128lane×512column/CTA | 同上；**有目标限定** |
| TMEM address | 32bit：bits31:16为lane index，15:0为column index；不是普通byte pointer | §.1.1，PDF699/印687，图185 PDF700/印688 |
| SMEM | A/B源矩阵及部分descriptor所描述的地址空间；mma/cp的SMEM访问属于async proxy | §.4.1及§.6.5，PDF720–722、738/印708–710、726 |
| registers | 64bit SMEM descriptor、32bit instruction descriptor；ld/st的warp分布寄存器片段 | §.4及§.8 |
| CTA pair | 同一cluster中`%cluster_ctarank`仅最低bit不同的两个CTA，分别even/odd；互为peer | §.5.1–.2，PDF732/印720 |
| mbarrier | 用于观察mma/cp/shift完成的对象；commit向其登记追踪并触发arrive | §.6.2.2及§.12.1 |
| allocation permit | CTA分配TMEM的许可，与某块allocation本身的生命周期不同 | §.7.1，PDF738–740/印726–728 |
| collector | ISA显露的A/B矩阵复用许可语义；reuse为opportunistic，不能视为软件可任意覆盖源存储的承诺 | §.10，PDF755–756/印743–744 |

`128×512×32bit=256KiB`只是在上述sm_100架构视图下计算的可寻址容量，不证明每个CTA有物理独立复制的256KiB宏。**“所有tcgen05目标都只有512列”不成立**：9.4的exclusive allocation另列sm_107的576列条件，见下一节。

TMEM lane不等同于CUDA thread lane。ld/st片段映射把warp线程寄存器与TMEM区域联系起来，但不能据同名lane断言一一对应的物理ALU。

## 3. TMEM资源、所有权与生命周期

来源：§.1.2 PDF699/印687；详细§.7.1 PDF738–741/印726–729。

1. `alloc`动态申请列，按32列单位、每列全部128lane；地址写入发射warp所给SMEM位置`[dst]`。`dst`是存放结果地址的SMEM位置，不是TMEM数据本身。
2. 非exclusive：nCols∈[32,512]且为2的幂，即32/64/128/256/512；同CTA执行顺序中的连续申请列数不得递增。
3. 9.4新增exclusive：nCols为32的倍数，不要求2的幂；sm_100/sm_103/sm_110最多512，sm_107最多576（表60，PDF739/印727）。因此§.1.2的power-of-two总览必须由§.7.1的exclusive特例补全。
4. exclusive申请阻塞至没有其他live allocation；在其存在期间不能有其他allocation。该allocation和permit的所有权由CTA1或CTA pair共同持有，必须以**相同nCols且同为exclusive**的dealloc匹配释放。不要将这一资源规则延伸为未经定义的全GPU/跨kernel全局锁。
5. `alloc`在资源不足时阻塞；`dealloc`是**可能阻塞**，不能依赖其一定等待或一定立即返回。CTA2的双方必须在尝试联合释放之前同步TMEM访问，避免peer仍使用allocation。
6. 所有kernel内申请的TMEM必须在kernel退出前显式dealloc。dealloc之后warp可以退出，无需额外的“为了dealloc本身”的退出同步（§.5表58，PDF731/印719）；这不免除释放前保证无并发访问的义务。
7. `relinquish_alloc_permit`放弃该CTA后续申请权：任一构成线程执行后，该CTA再执行alloc为非法。**它不代替dealloc，也不自动释放live allocation。**
8. CTA1由一warp执行allocation管理；CTA2由每个peer CTA各一warp联合执行，第一warp可能等另一warp。各warp参与者必须满足`.sync.aligned`与nCols一致，已退出线程/非一致分支会产生undefined behavior。
9. alloc写SMEM结果按memory model属于weak store；不能因为存在`.sync`就假设任意其他warp已看到结果。

§.7.1中的exclusive具体target note与表60容量表粒度不同，文档应分别引用，不能只用一个“SM版本大于某数”谓词替代所有feature合法性。

## 4. 全部tcgen05功能清单

下表展开ld的主要复合形式及wait/fence语义；它不是另一套“新微操作”分解。

| 指令/形式 | 架构效果 | 发射/参与者 | 完成观察与证据 |
|---|---|---|---|
| `tcgen05.alloc{.exclusive}` | 申请TMEM列并向SMEM写地址 | CTA1一warp；CTA2各一warp | 阻塞申请；§.7.1 PDF738–741/印726–729 |
| `tcgen05.dealloc{.exclusive}` | 释放先前allocation | 同上 | 可能阻塞；释放前消除双方并发访问；同上 |
| `tcgen05.relinquish_alloc_permit` | 放弃CTA后续分配权 | 同上 | 不能再alloc；不是free；同上 |
| `tcgen05.ld` | TMEM→warp分布寄存器，可选pack16 | warp collective | 异步数据操作，`wait::ld`；§.8.3 PDF742–746/印730–734 |
| `tcgen05.ld.red` | load同时按每lane的columns做min/max归约 | warp collective | 同ld；**PTX8.8引入** |
| `tcgen05.ld.spcompress` | load同时F32 2:4稀疏压缩，返回数据和2bit索引metadata | warp collective | 同ld；**PTX9.4，sm_107a** |
| `tcgen05.ld.red.spcompress` | 上项同时返回归约结果 | warp collective | 同ld；§.8.3 PDF743–746/印731–734 |
| `tcgen05.st` | registers→TMEM，可选unpack16 | warp collective | 异步，`wait::st`；§.8.4 PDF746–748/印734–736 |
| `tcgen05.wait::ld` | 阻塞至本线程之前发射的ld完成 | warp `.sync.aligned` | 不追踪mma；§.8.5 PDF748–749/印736–737 |
| `tcgen05.wait::st` | 阻塞至本线程之前发射的st完成 | 同上 | 不追踪mma；同上 |
| `tcgen05.cp` | SMEM→TMEM异步复制，可选低位类型展开与warp multicast | CTA1或pair中单thread启动 | commit+mbarrier；§.9.2 PDF751–753/印739–741 |
| `tcgen05.shift` | 在warp对应TMEM区域按row下移32-byte元素，最后row除外 | CTA1或pair中单thread启动 | commit+mbarrier；§.9.3 PDF753–754/印741–742 |
| `tcgen05.mma` | dense A的矩阵乘加，含可选block-scale/collector/LUT等形式 | CTA1或pair中单thread启动 | commit+mbarrier；§.10.10.1 PDF823–830/印811–818 |
| `tcgen05.mma.sp` | structured sparse A的矩阵乘加 | 同上 | 同上；§.10.10.2 PDF830–837/印818–825 |
| `tcgen05.mma.ws` | weight-stationary卷积矩阵乘加 | 仅CTA1，single-thread启动 | 同上；§.10.10.3 PDF837–840/印825–828 |
| `tcgen05.mma.ws.sp` | 上项并使用structured sparse A | 同上 | 同上；§.10.10.4 PDF840–842/印828–830 |
| `tcgen05.fence::before_thread_sync` | 将之前async tcgen05操作与后续tcgen05/执行顺序操作排序 | 每个需要建立顺序的thread | **fence不是完成wait**；§.11.1 PDF843–844/印831–832 |
| `tcgen05.fence::after_thread_sync` | 将之后async tcgen05操作与之前tcgen05/执行顺序操作排序 | 同上 | 与跨线程同步组合；同上 |
| `tcgen05.commit` | 给mbarrier登记本发射线程之前mma/cp/shift的完成追踪 | CTA1或pair中单thread启动 | 等待用mbarrier机制；§.12.1 PDF844–846/印832–834 |
| `commit...sync_restrict::shared::read::mma::a` | **只**在之前mma的SMEM A读取完成时arrive | 同上 | **不是MMA整体完成**；9.4、sm_107f同family以上；PDF845–846/印833–834 |

`.ld.sync.aligned`、`.st.sync.aligned`中的sync表示warp到达同一指令，不表示该异步传输已经完成。§.6.1把commit归在“Synchronous instructions”，§.12.1描述又用asynchronous措辞；架构说明应避免用“同步”一词混淆**发射/排序类别**与**被追踪事件的完成**，不能把commit写成阻塞等待MMA。

## 5. CTA group、参与者及访问权限

来源：§.5表57、§.5.1–.2，PDF730–732/印718–720；§.8.1 PDF741/印729。

- 有`.cta_group`的tcgen05操作，kernel内必须用同一个值。`.cta_group::1`作用于本CTA；`::2`作用于当前及peer CTA的TMEM。
- `mma/cp/shift/commit`为single-thread启动。在CTA2，一对CTA中一个thread发射即可；peer必须已active且未退出，不能让双方各自盲目再发一次同项操作。
- allocation管理的CTA2是**双方各一warp collective**，不能因为mma是single-thread就把alloc/dealloc也处理成single-thread。
- `ld/st/wait::{ld,st}`为warp collective。每个warp只能访问其warpgroup中的1/4 TMEM lanes，但可访问全部columns：warp0→0..31，warp1→32..63，warp2→64..95，warp3→96..127。要覆盖整TMEM需warpgroup，不是任意单warp。
- load/store中同warp全部线程必须用相同base taddr且保持活跃；`.aligned`要求一致控制流。
- `.fence`是thread需要为自己的访问建立顺序，不能只让一个thread fence后假定其他thread的所有TMEM访问已被覆盖。
- CTA pair按cluster rank最低bit配对，不是“cluster内随便选两个CTA”，也不表示整个cluster的所有CTA共同参与同一次MMA。

## 6. 三种descriptor与地址/shape的架构关系

来源：§.3、§.4，PDF711–730/印699–718。

| descriptor | 位宽/载体 | 表达的架构信息 | 注意 |
|---|---|---|---|
| SMEM matrix descriptor | 64bit register | Matrix start、leading stride相对offset或absolute地址、stride dimension、base offset、swizzle、LUT B分段等 | 表51 PDF722/印710；不是普通byte pointer |
| instruction descriptor | 32bit register | M/N/K编码、A/B/D类型、sparsity、transpose/negate、scale类型/ID/layout等；结构依kind不同 | 表53–55 PDF724–726/印712–714 |
| zero-column mask descriptor | 64bit register | `.ws`的B矩阵列取原值或强制0；按M分成1/2/4个submask | §.4.3、表56 PDF727–730/印715–718 |

### 6.1 SMEM descriptor

- `matrix-descriptor-encode(x)=(x & 0x3ffff)>>4`。matrix start、leading byte offset、stride byte offset必须16-byte aligned。
- leading stride的bit52区分相对byte offset和absolute byte address模式；absolute模式在K数据为48B的情形可拆为两个位于128B边界内的chunk。
- absolute模式只允许128B swizzle/16B atomicity、K-major、base offset=0；transpose bits必须0；该descriptor target note指向sm_103a（§.3.1.2–.3及§.4.1.1）。
- swizzle编码为0=no swizzle，1=128B/32B atomic，2=128B，4=64B，6=32B；3/5/7非法。base offset与重复pattern边界配合，不能把所有layout默认成0。
- bits46:48固定001；保留位必须依表51；bit53在LUT B路径选取48B读块中的前/后24B。这里是可见descriptor规则，不是公开内部SMEM端口。

### 6.2 instruction descriptor

- M、N可在descriptor指定；若某kind只有唯一K，K对应bit必须0；多个K时按表50和相应descriptor编码。
- 一般kind为A/B分别编码type；scale kind的A/B scale **共用**一个Scale Matrix Type字段。不同A/B scale格式若作为自定义接口，应另列项目扩展。
- sparsity selector、scale ID、scale layout、LUT分段位有目标约束，不能只验证M/N/K而忽略这些字段。
- 对mxf4/mxf4nvf4，sparsity version bit12在sm_100a/sm_103a/sm_110a为v0、sm_107a为v1，否则undefined（PDF727/印715）。
- zero-column mask使整列B按0参与，不等同于输出TMEM lane write-disable；二者不能共用一个语义。

## 7. 数据移动shape、寄存器片段与packing

§.2.3 PDF705–711/印693–699；§.8.2–.4 PDF742–748/印730–736。

| 操作 | 基本data movement shape |
|---|---|
| ld/st | `.16x64b`、`.16x128b`、`.16x256b`、`.16x32bx2`、`.32x32b` |
| cp | `.4x256b`、`.32x128b`、`.64x128b`、`.128x256b`、`.128x128b` |
| shift | 隐含`.31x256b` |

这里的shape是TMEM lane数×每lane数据位宽；不是MMA的M×N×K，也不是物理乘法器阵列尺寸。ld/st `.num`为x1/x2/x4/x8/x16/x32/x64/x128，是base shape的repeat factor。

表61/63：每thread `.b32` register vector长度，对`.16x32bx2/.16x64b/.32x32b`为num；`.16x128b`为2num（最高x64）；`.16x256b`为4num（最高x32）；不存在所有shape都合法x128的保证。`.16x32bx2`第二次访问地址是`taddr+immHalfSplitoff`。

`ld.pack::16b`可把相邻columns的两个16bit片段打包成一个32bit寄存器；`st.unpack::16b`作反向。不要与MMA D默认packing混淆：§.10.4.1说明D的subword元素**不**在一个TMEM32bit word内紧凑打包，例如F16 D占每word低16位。

### 7.1 ld reduction / sparse compression

- `.red`支持每lane沿column的min/max，F32或S32/U32，shape为32x32b或16x32bx2，num至少x2；F32可abs/NaN。
- `.spcompress`仅32x32b、F32、sp::2:4、metadata index=b2，num为x4..x128。返回cdata向量长度num/2、mdata长度ceil(num/32)。选两元素的准则由min/max和可选abs指定。
- `.red.spcompress`的`.NaN`只适用于reduction部分；spcompress本身始终保留NaN。这是API保证，不是“任意NaN策略可选”。
- 该load压缩结果的metadata并不自动证明可以不经format/layout适配直接作为任意`mma.sp` kind的metadata。

### 7.2 cp与shift

- cp的64x128b必须配warpx2::02_13或warpx2::01_23；32x128b必须配warpx4。前者分别以warp(0,2)/(1,3)或(0,1)/(2,3)成组multicast，后者到全部4warp。
- cp可把`.b4x16_p64`或`.b6x16_p32`展开到`.b8x16`。这包含布局/padding展开，不等于把FP4/6数值转为任意FP8标准编码。
- shift地址lane需32对齐，向下移动32-byte元素一row、最后row除外；CTA2会作用于双方。它与MMA `.ashift`相关但不是同一条指令。

## 8. MMA矩阵对象、形态及合法格式

§.10总览PDF755–756/印743–744；表50 PDF700–704/印688–692；具体§.10.10.1–.4 PDF823–842/印811–830。

基本形态为`D=A×B+D`：A为M×K、B为K×N、D为M×N。A在TMEM或SMEM，B在本CTA且可涉及peer的SMEM，D在TMEM；scale和sparse metadata在TMEM。`enable-input-d=false`时为`D=A×B`，没有通用独立C格式字段。

`scale-input-d`让旧D乘`2^(-s)`，s∈[0,15]，仅kind::f16/tf32合法；它不是microscale A/B。非blockscale形式的disable-output-lane向量在CTA1/2分别4/8个32bit mask，控制TMEM结果lane不更新；它不改变点积输入含义。

| kind | A/B元素类型 | D格式 | block scale |
|---|---|---|---|
| f16 | F16 | F16或F32 | 无 |
| f16 | BF16 | F32 | 无 |
| tf32 | TF32 | F32 | 无 |
| f8f6f4 | E4M3/E5M2/E2M3/E3M2/E2M1 | F16或F32 | 无 |
| mxf8f6f4 | 上述低位浮点 | F32 | UE8M0 |
| i8 | S8/U8 | S32 | 无 |
| mxf4 | E2M1 | F32 | UE8M0 |
| mxf4nvf4 | E2M1 | F32 | UE8M0/UE4M3/UE5M3 |
| ti16 | S1Z4M11 | S32 | 无 |

tcgen05表50**没有**FP64、INT4、B1行，也没有任意完整FP32 A/B乘数行。不能把旧mma家族的格式支持并到这张原生表。

Ti16类型名是`.s1z4m11`，16-bit signed integer，范围[-2047,2047]，不是旧会话中的e1z4m11；原件没有给完整raw负数编码。TF32在§5.2.3 PDF55/印43明确internal layout implementation-defined，不能把本项目低13bit=0协议写成PTX唯一物理编码。

### 8.1 shape约束摘要

| kind | 常规dense K / sparse logical K | 其他限制概要 |
|---|---|---|
| f16 | 16 / 32 | non-ws CTA1 M64/128、N步8；CTA2 M128/256、N步16 |
| tf32 | 8 / 16 | 同类M/N规则 |
| f8f6f4 | 32 / 64；另有dense64/sparse128扩展 | 大K有type、M/N、target条件，不能作为任意FP6/4形状 |
| mxf8f6f4 | 32 / 64；另有dense64/sparse128扩展 | M/CTA组合按表50；无ws |
| i8 | 32 / 64 | CTA1 N={8,16,24,32,48,…256}，32之后步16；CTA2 N步32 |
| mxf4/mxf4nvf4 | 64 / 128；另有96/192及dense128 | M/CTA、target与K联动；无ws |
| ti16 | 16 / 32 | CTA1 M64时N步8，M128时N步16；CTA2 N步32 |

ws仅CTA1，M32/64/128；dense N64/128/256，sparse N64/128；仅f16/tf32/f8f6f4/i8/ti16有ws行。详尽组合以表50为准，不能把本摘要解释为未列维度的全笛卡尔积。

§.2.1.1 PDF704/印692：K96仅sm_103a/sm_107a；f8f6f4/mxf8f6f4的denseK64/sparseK128与mxf4/mxf4nvf4的新增大K需sm_107f同family更高。M/N/K是软件可见tile，不给出物理并发lane数或每cycle吞吐。

### 8.2 stationarity、collector、LUT

- 默认形态在说明中称activation-stationary，主要复用A；`.ws`称weight-stationary，collector主要复用B。该命名是矩阵供数/复用契约，不是要求特定内部寄存器文件拓扑。
- fill/use/lastuse/discard给出collector复用许可；reuse是opportunistic，即使use也可能重新读源。因此在MMA完成前，源矩阵不能因“已经放入collector”而被改写。
- 9.4新增non-ws mma/mma.sp的B collector限定形式；`.ashift`用于TMEM A row移动，M只能128/256，且与collector::a::fill/use互斥（PDF828–829/印816–817；sparse说明PDF835–836/印823–824）。
- 9.4 `.decompress::lut::b`限kind::f8f6f4/mxf8f6f4：B的SMEM内容是3bit索引，TMEM LUT提供8bit值，同一8-column slice共享8个候选值；B只允许E4M3且不能transpose。LUT禁用layout B/C/F，target sm_107f（§.10.8 PDF812–815/印800–803；指令说明PDF827–830/印815–818）。不要与cp的4/6→8bit展开混为一谈。

## 9. block scaling的架构约束

§.10.7 PDF774/印762；表70/71 PDF781–782/印769–770。

实数关系为`D=(A×scale_A)×(B×scale_B)+D`。scale_A为M×SFA_N，A每row沿K分chunk；scale_B为SFB_M×N，B每column沿K分chunk。scale矩阵在TMEM。

| kind | 元素 | scale格式 | block选择 |
|---|---|---|---|
| mxf8f6f4 | 低位浮点五类 | UE8M0 | block32 |
| mxf4 | E2M1 | UE8M0 | block32 |
| mxf4nvf4 | E2M1 | UE8M0、UE4M3、UE5M3 | block16或block32 |

UE5M3，以及UE4M3+block32，要求sm_107f同family以上。mxf4省略scale_vectorsize默认为block32；mxf4nvf4必须显式给出。scale格式和A/B元素格式是独立维度，但不是任意交叉组合均合法。

表70的scale_vec::1X/2X/4X分别是1/2/4个scale；blockN表示覆盖粒度，不能固定映射为某个scale计数。K96特例block32/16为3/6个，K128特例为4/8个。logical K、sparse压缩K与scale布局的引用口径需分开，见§.10.7.3–.15及本文件第12节的原文差异记录。

B scale需要复制到各32-lane TMEM partition；sm_107f上通过tcgen05.st写A scale时可不需要相同复制（§.10.7 PDF774/印762）。这是布局契约，不是可推算的物理广播网络。

## 10. sparse、transpose与可见TMEM layout

### 10.1 sparse

§.10.9 PDF816–823/印804–811：数学A为M×K，压缩存储M×(K/2)，metadata指定保留值回填位置。

- TF32是**1:2**，有效metadata4bit值仅1110、0100，其余undefined。
- f16、ti16、f8f6f4、mxf8f6f4、i8为**2:4**。
- mxf4/mxf4nvf4为**成对4:8**：8元素中4个保留，2元素子组必须整体零或整体非零，不是任意4-of-8。
- 原件PDF817/印805给2:4 metadata七项`0100,1000,1100,1001,1101,0110,1110`；不能自行按“普通任取两项应为六种”删改原文。需要具体target进一步核验语义，不伪装已解决。

### 10.2 transpose/negate与major-ness

§.10.1–.3表64–67 PDF756–758/印744–746：D及TMEM A使用相应row-major可见组织；SMEM A/B的major-ness与swizzle配合。32bit transpose只允许128B/32B atomic swizzle；8/16bit transpose排除此模式；kind本身还可禁止transpose，例如mxf4/mxf4nvf4不支持。

**已知原文冲突**：表53的ti16 transpose字段只列No Transpose=0，而表64列ti16 transpose A/B支持Yes。只能记录冲突，不将任一猜测写成已核验统一结论。

### 10.3 layout A–G是可见数据映射

§.10.5，表及图211–224，PDF764起/印752起：

| M/CTA/ws条件 | Layout ID | 原文organization | TMEM lane对齐 |
|---|---|---|---|
| M256，CTA2 | A | 4×1 | 0 |
| M128，CTA2，dense | B | 2×2 | 0 |
| M128，CTA2，sparse | C | 4×1、half utilization | 0或16 |
| M128，CTA1 | D | 4×1 | 0 |
| M64，CTA1，ws | E | 2×2 | 0 |
| M64，CTA1，non-ws | F | 4×1、half utilization | 0或16 |
| M32，CTA1，ws | G | 1×4 | 0 |

layout C/F中A、D及metadata必须用同一TMEM lane对齐。表中的organization是PTX对矩阵数据映射的公开命名，不足以反推出真实乘加阵列拓扑。

4/6bit packing随kind、denseK和SMEM/TMEM位置不同：mxf8f6f4在K32可使用padding/8bit container，K64可紧凑；mxf4/mxf4nvf4的E2M1是两个元素/byte、无padding。不能把一种格式的一个wire布局当所有操作的唯一布局（§.10.4 PDF759–763/印747–751）。

## 11. 顺序、同步与完成契约

§.6 PDF732–738/印720–726；§.11–.12 PDF843–846/印831–834。

### 11.1 两套完成机制，不能混用

| 被观察的异步操作 | 登记/等待机制 | 不代表什么 |
|---|---|---|
| mma/cp/shift | commit登记，mbarrier arrive-on(count=1，cluster scope)及barrier等待 | commit发射不是完成；wait::ld/st不追踪这些操作 |
| ld | 本线程wait::ld | 不是MMA完成等待 |
| st | 本线程wait::st | 不是任意其他thread的全局TMEM fence |
| mma的A SMEM读阶段（9.4 restrict） | sync_restrict commit对应barrier事件 | **不是该MMA整体完成，也不能据此读结果D或释放D** |

commit的mbarrier使用generic proxy；默认16bit ctaMask，可显式16b/32b，32b要求sm_107f同family以上。multicast在每个目标CTA的SMEM中相同offset触发barrier，不是把计算结果本身复制到所有CTA。

### 11.2 有保证的pipeline依赖

§.6.2 PDF733/印721列出：

1. mma→mma：同cta_group、accumulator、shape、kind。
2. cp→mma：同cta_group。
3. shift→mma：同cta_group。
4. shift→cp.4x256b：同cta_group。
5. mma→shift：同cta_group。

只有满足相应条件的组合才有规定的issue顺序执行保证；不能泛化成“同一个thread全部tcgen05天然按序完成”。commit与所追踪的mma/cp/shift、wait与相应ld/st还有implicit pipeline关系。

### 11.3 跨线程与跨proxy

- before/after_thread_sync与barrier、mbarrier或满足memory model的执行顺序操作组合，建立thread scope内tcgen05顺序。fence本身不是barrier，也不是完成wait。
- tcgen05.mma/cp的SMEM访问在async proxy；generic proxy对同一位置的写入与其交接需`fence.proxy.async`等正确跨proxy机制（§.6.5 PDF738/印726）。不要把TMA传输完成、proxy可见性和MMA完成合成一个事件。
- tcgen05.ld的真实register依赖会被尊重，但不自动建立任意memory-access顺序；反依赖或TMEM复用需要wait::ld（§.6.4.5 PDF737/印725）。
- 一条可用于说明依赖的架构级链：源SMEM可见性/producer完成 → cp/MMA发射 → commit → barrier完成等待 → after_thread_sync等所需排序 → warp collective ld → wait::ld → 使用寄存器结果 → 消除所有并发访问 → matching dealloc → relinquish/退出。具体是否省掉某一步取决于合法pipeline与thread/proxy关系，不能不加条件套成所有kernel的固定序列。

## 12. PTX9.4新增项及仍未确定的内容

### 12.1 9.4增量清单

release notes PDF973/印961，以及各指令自己的PTX ISA Notes：

- alloc/dealloc `.exclusive`。
- ld/ld.red `.spcompress`（F32 2:4压缩，sm_107a）。
- mma/mma.sp/mma.ws/mma.ws.sp `.kind::ti16`（sm_107f同family更高）。
- mma/mma.sp增加UE5M3 scale（同family目标条件见表71）。
- 普通mma `.decompress::lut::b`，以及non-ws mma/mma.sp的`.collector::b::*`（sm_107f）。
- commit `.sync_restrict::shared::read::mma::a`、显式`.multicast::cluster::16b/32b`（32b有sm_107f目标门限）。

**不属于9.4新加**：基础tcgen05为8.6；mxf4nvf4为8.7；block16/block32和ld.red为8.8。不要把“9.4文档中存在”写成“9.4首次引入”。

### 12.2 显式保留的未知/原文不一致

| 项目 | 目前可确定 | 不应补写的内容 |
|---|---|---|
| Ti16 raw | 名称S1Z4M11、16bit容器、[-2047,2047]、D=S32 | 未公开完整负数/零raw映射；不能猜普通S16或sign-magnitude |
| Ti16 transpose | 表53/64表述不同 | 不假装无歧义 |
| blockN scale count | 表70明确K96=3/6、K128=4/8 | fallback“except96”与K128特例重叠；历史alias与dense/sparse K口径不能混用 |
| exclusive与TMEM容量 | sm100视图512列；exclusive sm107列576 | 不外推每个代际全部TMEM容量或物理宏划分 |
| commit同步术语 | §.6.1类别与§.12.1异步完成描述须分别理解 | 不写commit阻塞至MMA完成 |
| 浮点数值微架构 | A/B/D格式与操作数学关系 | tcgen05节未给完整逐bit舍入/内部累加顺序；不抄旧mma或设备论文的内部位宽作为ISA |
| 资源和性能 | ISA布局、合法shape、目标条件 | 乘法器数、SRAM bank、内部队列深度、II/latency、频率、PPA、各格式吞吐比例 |

体系结构文档可以定义未来实现必须维持的上述可见行为，但应在此停止；后续微架构设计需要另立文档及选择依据。

## 13. 主文档独立内容审查与关键表格复核

本轮已只读检查 `../TCGEN05_TENSOR_ARCHITECTURE.md` 的规范事实、target、shape、生命周期、同步、引用边界和5幅PNG。没有修改主文档，也没有提交或推送Git。

### 13.1 Table50大K关系的精确边界

直接核对PDF701–704/印689–692后：

| 项目 | 能确定的行 | 不应强行归一化的部分 |
|---|---|---|
| f8f6f4，CTA1 | M64/M128的基础K32；M128的大K64；type列给K64仅E4M3/E5M2的注释 | N列“8..256步8 OR 16..256步16”是合并cell，单从排版不能无歧义证明K32↔步8、K64↔步16的一一绑定，应保留原条件说明 |
| f8f6f4，CTA2 | M128/M256的K32；M256的K64；N16..256步16 | 同时保留原type及target条件 |
| mxf8f6f4，CTA1 | M128，denseK32/64、sparseK64/128，N8..256步8 | type列仍列五类低位浮点，没有f8f6f4那条“onlyFP8”注释，不能跨kind复制该限制 |
| mxf8f6f4，CTA2 | denseK32可M128/M256，denseK64仅M256；sparse仅M256，K64/128；N16..256步16 | 不把denseM128错误带入sparse行 |
| mxf4/mxf4nvf4，CTA2 | denseK64可M128/M256，denseK96/128仅M256；sparse仅M256，K128/192；N16..256步16 | K96架构专属目标和大K family门限分别保留 |

mxf8f6f4的denseK64并非“全部只允许FP8”的另一证据：表64专门说明该kind的E3M2/E2M3/E2M1在denseK64时不可transpose；表68另有FP6、denseK64、6bit container布局。合法输入类型与transpose限制应分开。

### 13.2 Ti16 negate、transpose与整数sat

表53的Negate A/Negate B在各kind的value列使用**跨两行合并单元格**。Ti16列的“No Negate=0 / Negate=1”共同适用于A/B，不能按文字的纵向位置误读成A只能0、B只能1。因此**未发现Ti16 negate与表64的矛盾**；实际保留的冲突只有transpose：表53 Ti16只列NoTranspose=0，表64却给支持Yes。

| kind类别 | 表53 bit3 saturation字段 | 可确定结论 |
|---|---|---|
| i8 | No Saturate=0，Saturate=1 | 暴露整数saturation选择 |
| ti16 | 0（NA） | 不能启用该原生saturation bit |
| tf32/f16/f8f6f4 | 0（NA） | 不应借整数saturation字段表达浮点策略 |

ws的`collector_usage`明确暴露`b0/b1/b2/b3`四个软件可选编号（§.10.10.3，PDF838–839/印826–827），可以写入架构上下文；它不证明四物理bank、四端口或四路并发。

### 13.3 5幅图的概念审查

- 01架构边界、03资源生命周期、04异步完成：逻辑责任与完成域区分成立，未发现将物理阵列、队列或固定流水时延当规范的情况。04已正确隔离restricted A-read与整体MMA完成，after_thread_sync及ld/wait也保持独立。
- 02存储图需让独立读图者明确：原生加数是`D_old`、结果是同一对象的`D_new`。若简写C，必须显式标注`C=D_old`；不画成通用独立C/D对象。64bit SMEM descriptor由寄存器承载，不表示descriptor本身驻SMEM。
- 05 scale图的K0..63、block16四组/block32两组只作为**dense K64示例**成立；应明确图题/脚注的dense限定。sparse logicalK不能直接套用该图。例如mxf8f6f4 sparseK64的scale_vec1X/block32布局只有一组scale，需按压缩K与对应layout解释。

上述图注澄清意见已发主agent统一修改；本audit没有自行覆盖主文或figure资产。若主文选择保留Table50的baseline表并明确大K条件/原文歧义，优于编造一个看似完整但未经原文支持的交叉积。
