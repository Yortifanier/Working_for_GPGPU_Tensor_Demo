# tcgen05 ISA→项目微架构正确性独立审查

角色：agent1；日期：2026-10-26。本文提出**本项目应保持的不变量、反例和验收证据**，不是 NVIDIA 已公开的内部实现。规范依据为上传PTX9.4及[架构核查](../../research/ptx94_architecture_audit.md)；主微架构文档另由主agent撰写，本记录不修改主文或现有RTL。

## 1. 审查结论的前提与分层

目前只提出实现正确性约束，尚未收到最终主微架构文档，不能提前标为该文档已审查通过。

每项设计声明应区分：

1. **ISA义务**：软件可见数据、参与者、资源、顺序和完成语义。
2. **项目实现选择**：token、queue、scoreboard、buffer、scheduler、内部位宽等具体方案。
3. **未确定事实**：Ti16 raw、原文transpose/scale alias歧义、未映射target等。不能用设计选择把未知补成“官方硬件如此”。

对PTX定义undefined/illegal的输入，项目可以采用入口诊断/拒绝；这属于项目保护策略，不是PTX承诺统一trap或错误码。

## 2. 完整command生命周期

可使用下面的逻辑阶段审查一条command，但阶段不必各占一拍，也不要求实际FSM采用同名状态：

`接收/参与者汇合 → 解码与合法性 → 解析资源/捕获依赖 → 等待操作数可见 → 获取输入/metadata/scale → 执行数值或搬运 → 写回 → 分别发布完成事件 → 释放内部占用/退休`

### 必须保持的不变量

- **C1：身份不串单。** command身份在全部派生任务中保持一致：kernel/CTA generation、issuer、CTA group、allocation generation、matrix/tile identity、descriptor快照、目标profile、顺序编号等。具体字段可裁剪，但必须能证明不会将新请求配置用于旧数据。
- **C2：接受不等于执行/完成。** 入队、资源保留、A读取完成、D写回完成、寄存器写回、barrier arrival和内部entry退休是不同条件。
- **C3：失败原子边界。** 若入口拒绝，则不得留下部分TMEM更新、孤立allocation、collector逻辑状态或虚假barrier到达。已被接受后发现运行期错误时，项目必须定义已产生副作用的边界及恢复流程，不能仅丢弃结果token。
- **C4：内部清理不释放软件所有权。** command退休只回收command内部资源，不能代替软件dealloc，也不能自动恢复relinquished permit。
- **C5：描述符快照一致。** 同一command的A/B、scale、metadata及D配置来自同一版本；不能在晚发微任务中重新读取已被下一command覆盖的live配置寄存器。
- **C6：reset/abort不产生幽灵回调。** 若项目定义上下文reset，旧epoch的SMEM读取返回、数值完成或barrier回调不能命中新epoch相同token索引。

**反例**：仅用循环复用的8bittag标识任务，旧MMA的DMA返回在tag回卷后落到新tile；数值核心本身完全正确，仍把旧A与新scale拼接。验收需要延迟返回、tag/epoch复用和reset后迟到回调。

## 3. TMEM ownership与allocation permit

规范：§9.7.18.1、.5、.7，PDF699–700、730–741/印687–688、718–729。

### 不变量

- **T1：地址加allocation generation。** 可访问性由合法owner、CTA/peer、column range、lane权限及allocation存活期共同决定；32bit taddr能表示某位置不代表拥有它。
- **T2：不得释放在途使用。** dealloc真正释放前，该allocation不得有可能继续读取/写入TMEM的任务。用单个“MALU done”计数器不够，ld/st/cp/shift、metadata/scale读取也会占用资源。
- **T3：matching属性。** exclusive/nonexclusive、CTA group、地址、列数和原allocation相匹配；exclusive须同nCols释放。不得把exclusive收缩成普通power-of-two allocator路径。
- **T4：nCols执行顺序约束。** 同CTA相邻申请的列数不得递增；如果项目以history检查该约束，不能在dealloc时清空history后允许更大的下一次alloc。
- **T5：permit是CTA级义务。** 任一构成线程relinquish后，该CTA后续alloc非法；不能只设置发射thread的局部禁止位。
- **T6：容量是target属性。** sm_100模型512列与sm_107 exclusive576列分别检查；不得用一组固定512列常数宣称覆盖9.4全部目标。
- **T7：allocation结果发布。** alloc向SMEM写返回地址是weak store；其他warp的可见性由正确同步/proxy规则保障，不因alloc名称中的sync自动全CTA可见。

**反例A**：旧command保存taddr=0，dealloc后新owner又申请到0，旧command才完成D写回。若无generation/生命周期保护，会破坏新owner数据。

**反例B**：全局单FIFO的头是等待容量的alloc，能够释放容量的另一CTA dealloc排在后面，scheduler不允许旁路；造成项目自己引入的永久等待。ISA允许alloc阻塞，不要求阻塞整个系统的释放路径。

## 4. CTA group2与参与者汇合

规范：§.5表57、§.7.1，PDF730–741/印718–729。

- **G1：不同指令使用不同汇合粒度。** mma/cp/shift/commit为pair内单thread启动；alloc/dealloc/relinquish则需双方各一warp collective。不能共用“一对CTA各提交一次即执行”的规则。
- **G2：一次逻辑工作只执行一次。** group2 MMA不能因两侧都可访问命令入口而重复发射；allocation也不能双方各自成功分配一块、再误当同一pair allocation。
- **G3：pair识别准确。** `%cluster_ctarank`仅最低bit不同；还需同kernel/cluster/CTA generation，不能只用rank异或1匹配来自不同实例的CTA。
- **G4：peer生命周期。** group2操作发射时peer必须active且未退出；dealloc之前双方消除并发TMEM访问。一个CTA本地“无在途command”不等于peer也静默。
- **G5：可前进的汇合。** 等peer的第一个warp不能占住对方必须使用的唯一入口/credit，从而让第二个warp永远无法到达。
- **G6：内核group一致性。** 不能把cta_group当每条command任意切换的局部性能开关。

**反例**：CTA0先到dealloc汇合，持有唯一cluster dispatch slot；CTA1释放请求必须获得同一slot才能到达。双方软件顺序合法，项目汇合锁却死锁。应通过资源依赖图或定向验证证明释放/peer到达路径不形成环。

## 5. logical K、compressed K、metadata与scale

规范：表50/70/71、§.10.7–.9，PDF700–704、774–823/印688–692、762–811。

### 不变量

- **K1：分别维护坐标含义。** `logical_k`是数学矩阵位置；`compressed_a_index`是保留值存储位置；TMEM lane/column、SMEM byte offset、scale slot和metadata index又各不相同。实现可不逐项保存，但推导必须明确。
- **K2：布局recipe绑定完整tuple。** metadata解码和scale索引由`kind × shape × sparse version × scale qualifier × target × layout`共同决定；不能在numeric fmt decoder里用一个通用除法公式代替。
- **K3：不同sparsity不可混用。** TF32为1:2；f16/ti16/f8f6f4/mxf8f6f4/i8为2:4；mxf4/mxf4nvf4为成对4:8，两个元素子组整体零或非零。
- **K4：数据与metadata同epoch。** A保留值、metadata、scale A/B及B tile版本必须一致；先到的metadata不能与下一tile的A数据拼接。
- **K5：scale factor是有效数值。** UE8M0、UE4M3、UE5M3按各自格式解码；后两者尾数不可当作只改指数。A/B scale type在原生descriptor中共用字段，不能接受任意不同类型交叉组合作为native。
- **K6：block与计数不可固化。** denseK64 block32/16为2/4个scale，K96为3/6、denseK128为4/8；大K仍受合法shape和target约束。

### 必须有的scale反例

`mxf8f6f4 sparse logicalK64`的原文`scale_vec::1X/block32`布局每行/列只有一组scale；若统一使用`ceil(logicalK/32)`会错误取两组。类似地，mxf4 sparse logicalK128的常见2X布局不能当作denseK128的4组block32。**dense的floor(logical_k/B)分组图不能无条件用于sparse。**

建议项目实现采用显式layout recipe/表驱动的索引关系，并由参考模型对每个合法tuple给出`compressed position → logical position → A/B scale slot`的独立对照。只用“全部压缩后K除2”的单一算式也不足以替代不同metadata组织和target版本。

### 尚未闭合时的保护

Ti16 raw位编码与Table53/64 transpose差异必须保留unsupported/待决状态；不能因数值阵列支持decoded整数就绕过native编码要求。原文七个2:4 metadata枚举也不能由项目擅改为习惯性的六种。处理策略应作为项目合法性说明记录。

## 6. collector、stationarity与重读

规范：§.10、.10.10，PDF755–756、823–842/印743–744、811–830。

- **R1：logical许可与physical命中分开。** fill/use/lastuse/discard表达软件可见复用序列；use并不保证内部cache命中。允许内部丢弃physical缓存后重新读取源，不意味着可以丢弃描述符/源数据identity。
- **R2：保持源保护。** 不能因A/B已fill就立即释放/覆盖SMEM。保守条件为相关MMA完整完成；若项目使用restricted A-read提前释放策略，必须只释放确已完成读取的A范围，并证明还有其他未读A的command不会再访问该版本。
- **R3：重读仍须同版本。** 重读源必须是当前command引用的同一矩阵版本；不能在下一个kernel或tile覆盖后仍认为use有效。
- **R4：lastuse不是整个MMA完成。** 可丢弃collector内容不等于D写回结束，也不释放TMEM allocation。
- **R5：编号不扩大为硬件保证。** ws的b0..b3是架构可见selector；non-ws的新B collector形式与其不同。设计可实现多个或共享存储，但不能把软件编号当作已公开的四物理bank/端口。
- **R6：ashift联合限制。** M和collector::a::fill/use的限制必须在分解为内部读、shift、MMA之前完成检查，避免非法请求先改写TMEM A。

**反例**：实现把use当作必命中，随后因为容量冲突丢掉A，执行时重读已经被producer覆盖的SMEM。单独的MMA数值单测全部通过，跨tile复用时才出现错误。

## 7. 三种数据变换不能合并

- cp把特定packed FP4/6布局展开为8bit container，并非转换为任意FP8数值。
- MMA LUT B读取3bit索引并查TMEM表，解码B只允许E4M3且不可transpose，限制layout B/C/F及target。
- ld.spcompress为F32 2:4选择/压缩并返回b2索引；不是任意mma.sp metadata生成器。组合red.spcompress中`.NaN`只控制red，而compression本身保留NaN。

**不变量X1**：三种变换各自保留输入/输出format、packing和坐标信息，不共享一个含义不明的“compressed=true”位。

**反例**：把ld.spcompress输出的F32数据和b2索引直接送到mxf4稀疏入口，忽略其成对4:8、低位元素packing和metadata layout；数据量恰好减半也不能证明接口兼容。

## 8. 完成域、barrier、寄存器依赖与退休

规范：§.6、.8.5、.11–.12，PDF732–749、843–846/印720–737、831–834。

| 事件 | 至少满足的条件 | 不能据此做的事 |
|---|---|---|
| command accepted | 身份/资源记录已保留 | 读D、覆盖源、释放allocation |
| restricted SMEM A-read complete | 所追踪的先前MMA相关A读取已完成 | 当作B读取完成、D完成或整体退休 |
| normal mma/cp/shift complete | 对应操作全部可见写入/读取责任已完成 | 自动认为consumer已做跨thread/proxy顺序 |
| ld register result available | 对应寄存器写回已就绪，可满足真实register依赖 | 自动把任意TMEM反依赖/存储复用风险视为解除 |
| wait::ld / wait::st satisfied | 当前thread此前相应操作全部完成 | 追踪其他thread全部访问或等待MMA |
| command retired | 内部entry可回收 | dealloc软件资源或恢复permit |

- **E1：commit追踪集合精确。** 必须是本发射thread此前规定类别、匹配cta_group的操作；不能误并入其他issuer后来的工作，或漏掉仍在输入读取阶段的工作。
- **E2：barrier事件不混类。** restricted A-read与normal completion可以指向不同barrier/phase；不能共用一个done bit，也不能在第一个事件时回收生成第二事件所需的context。
- **E3：arrival恰一次。** 每次commit对应的arrive count=1；multicast向指定CTA相同SMEM offset发出对应事件，不能误当D数据multicast。mask宽度、cluster rank和barrier epoch必须保持。
- **E4：register readiness不能绑定软件wait。** PTX允许真实register dependency被硬件尊重；若把ld目的寄存器永远锁到wait::ld执行，而程序先使用它再wait，会引入不必要甚至永久的阻塞。寄存器写回就绪与显式memory hazard drain应分开。
- **E5：不能提前退休。** D写回、scale/metadata读取、延迟callback、collector保护以及可观察barrier事件分别核算；只收到MALU结果不足以释放所有相关项。

**反例**：restricted A-read事件到达即把command slot重用，新command覆盖其中的D地址和barrier identity；旧MMA后来写回时进入新slot，造成错误D和错误normal barrier通知。

## 9. 依赖排序、proxy与进度

- **O1：仅按合法配对建立implicit pipeline。** mma→mma需要相同group、accumulator、shape、kind；cp→mma、shift→mma、mma→shift及shift→cp.4x256b有各自条件。不能仅比较taddr、忽略allocation generation/shape/kind。
- **O2：fence保序不等于等待。** before/after_thread_sync要与执行顺序/同步操作组合；不能用一个全局drain实现的名字掩盖错误的thread scope。
- **O3：proxy可见性单独建模。** generic SMEM写、TMA完成、async proxy读取以及TMEM结果完成是不同条件。设计若只在数据cache里看见写入却没有满足proxy交接，仍不能把ISA顺序标为已满足。
- **O4：释放路径可前进。** resource-full、barrier等待和peer汇合不能占住用于产生其解除条件的唯一credit。应给跨模块资源依赖图，而不只给每个queue的深度。

项目可以保守增加某些排序，但应检查是否引入软件本可前进而实现永久等待的环，不把“全部FIFO全串行”直接当作完整正确性证明。

## 10. feature gating必须在有副作用之前完成

原生tuple至少包含`form × kind × A/B/D type × M/N/K × ws × cta_group × sparsity/version × scale type/block/layout × transpose/negate × target`。

重点门限：

- ld.red是8.8，ld{.red}.spcompress是9.4/sm_107a；不能一个版本开关全部开启。
- Ti16四种MMA为9.4、sm_107f同family以上，但raw编码缺口仍需独立处理。
- UE5M3及UE4M3+block32有sm_107f family门限；block16不对所有kind合法。
- LUT B、non-ws B collector、restricted A-read、32bit multicast mask分别检查；不能因其中一个合法就全开。
- K96为特定架构专属目标，新增大K还有M/N/type限制；不能仅检查descriptor bit存在。
- exclusive的nCols/容量、sparse v0/v1及group必须联合校验。

**反例**：一个target允许FP4 block16，入口因此允许E5M2+UE4M3+block16；数值阵列能算出结果，但该组合并不是原生tcgen05指令能力。必须区分native能力与项目扩展。

## 11. 后续主文审查要求与建议证据

主微架构文档到达后，应逐项确认：

1. command/token与allocation/barrier generation如何关联，哪些完成域可以独立到达。
2. TMEM ownership与peer参与如何检查，谁负责解除阻塞及释放资源。
3. metadata/scale recipe如何绑定logical/packed坐标和target，特别sparse logicalK64的一组scale反例。
4. collector miss/reload、lastuse、restricted A-read与源版本保护是否矛盾。
5. 软件可见寄存器依赖、memory anti-dependency、proxy顺序与normal/restricted完成是否被合成单done。
6. 非法tuple是否在任何可观察副作用之前拒绝；运行期错误/reset如何取消或隔离旧epoch返回。
7. 每项queue/缓存/端口选择是否标为项目选择；有没有误写为NVIDIA官方内部结构。

适宜验收包括：迟到返回+token复用；group2单侧先到与peer延迟；capacity满时仍可dealloc；dealloc/realloc同地址；跨K和稀疏版本的scale/metadata错配；collector eviction后重读；A-read先到而D晚到；barrier phase/offset复用；ld结果无显式wait的真实register依赖；proxy交接遗漏的负例。

本记录提出的是正确性审查条件，不把这些测试计划写成已经运行或已证明通过。

## 12. 主微架构文档独立审查与修正复核

已只读检查主文 `../TCGEN05_TENSOR_MICROARCHITECTURE.md` 的完整26章，随后按主agent请求只复核修正涉及的§4/6/8/9/17，不修改主文、图或RTL，也未提交/推送Git。

### 12.1 本轮发现与修正

| 项目 | 初稿风险/具体反例 | 已核验的修正 |
|---|---|---|
| A-read stream的成员 | 若所有MMA都占A-read序号，TMEM-A MMA不产生SMEM读完成，后续SMEM-A restricted commit可能卡在prefix孔洞 | 仅SMEM-A MMA分配A-read seq；cp/shift/TMEM-A不入；空集合正常通知 |
| 超过8个allocation/generation | allocation hull不能把9个不同generation变成8个；D由8个相邻32列allocation组成，再加A/scale即可超过8 | coarse slow-path，逐endpoint18bit record pinmask，原子endpoint-wide lease；保留generation且不授予越权范围 |
| sparse的特殊值等价 | 省略A=0位置若B=Inf，完全跳过会丢失PROJECT_EXACT的0×Inf→NaN及零符号 | 明确结构性A=+0，省有限零乘法仍保留对应B特殊值/符号分类；其他策略另命名profile |
| commit cutoff与有序接收 | escape优先若越过尚未登记的较早MMA，当前issued watermark会漏追踪 | 同issuer按动态指令ticket在有序S0登记序号；S1–S5等待者已计入；escape不忽略程序顺序 |
| window满时控制前进 | commit若仍要求空MCS窗口/普通OpTable槽，可能被它应追踪的在途工作反向挡住 | 独立控制记录/事件credit，不以空普通窗口槽为前提；失败命令必须按错误/取消协议关闭序号 |

这些是**设计文档修正复核**，没有运行新Tensor RTL或证明其liveness。coarse lease是项目的保守慢路径，不能把此设计选择称为NVIDIA已公开内部机制。

### 12.2 已通过的关键不变量审查

- A snapshot为命令私有不可变版本，restricted A-read只在所有原SMEM A请求和可能重读义务结束后触发；future reuse失效不破坏当前snapshot。
- A-read先到不退休parent OpTable、D lease、peer child或normal full状态；full-done等待D/move写入ack。
- window8按issued−prefix限制跨度，乱序完成只置位而不跳孔洞；模序号比较和CommitWait ready锁存已说明。
- commit快照不被后来命令延长；full完成历史可留在prefix而让数据token退休，不要求等软件将来commit。
- SMEM-A A-read与normal MCS watermark分开；ld/st tracking又独立，ARF写回不依赖软件wait或consumer执行。
- alias未实现时关闭相应recipe能力，不以已有数学dot能力冒称支持原生别名；大于8范围有slow-path而非静默拒绝合法指令。
- group2仅issuing thread有parent序号，peer持child；双方相关读取/写回责任归并，重复消息幂等及epoch隔离单列。

### 12.3 exclusive资源域：已修正复核

已向主agent指出初稿§6将CTA1 exclusive也在整个pair资源域串行化，不能直接断言只影响性能。若两个endpoint各提供独立TMEM池，两个group1 CTA分别执行`exclusive alloc → cluster barrier → dealloc`，扩大排斥域可能让第二CTA卡alloc、第一CTA卡barrier。

主文§6现已明确：CTA1 exclusive只取得当前endpoint实际TMEM池/permit，不阻塞另一独立endpoint的CTA1 allocation；CTA2需要原子取得两端。主文同时保留上述cluster-barrier反例，已删除“全pair更强排斥只影响并发”的断言。本项经只读复核关闭。

### 12.4 最终审查结论

本轮指出的A-read成员、8范围fallback、sparse特殊值、S0/commit cutoff、控制信用及exclusive资源域问题均已在主文对应段落修正并复核。**当前项目拟议微架构的ISA映射、ownership和完成域说明未发现剩余阻断性内容问题。**

该结论只针对设计文档的一致性及已核查边界：新增Tensor/peer/PERF仍待实现、仿真及活性/时序/PPA验证；不是对NVIDIA内部实现的还原结论，也不是已经证明硬件正确。
