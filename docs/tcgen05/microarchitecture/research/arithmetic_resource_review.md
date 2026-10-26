# MALU dot-only：算术、资源复用与吞吐预算独立评估

角色：agent2。日期：2026-10-26（Asia/Shanghai）。本记录为微架构主稿提供独立建议，不修改 RTL，不代写主稿，不执行 commit/push。以下明确区分现有 **REF**、建议的 **PERF_PLAN** 和 Rubin **产品目标**。

## 1. 方案版本与核心结论

本记录最先提出的备选 T1 是一个可实现的有界时分资源预算：**8 个显式独立的 11×11 无符号 full-product term cells**，按同一资源池处理原生矩阵格式；通过配置的发射 slot 比例保留 Rubin dense 目标比。该方案不依赖宽乘法器的子字 packing，不宣称某种输入位宽天然提供某倍吞吐。

建议的 70-cycle 预算窗口，在单一格式、持续供数且后端不阻塞的条件下，分别给 TF32、F16/BF16、FP8/FP6、NVFP4 模式 **4、8、35、70 个发射 slot**；每 slot 最多 8 个有效乘积。因此 term 预算为 32、64、280、560，归一化为 **0.5:1:4.375:8.75**。

**这是项目的可配置服务预算/限额，包含对共享资源的时分分配，不是 Rubin 的物理阵列推断，也不是当前 RTL 性能。** 它不会因为乘法器有 11 位就自动实现更低精度的 packing。全部配置最终仍要经过独立数值验证、综合和可达带宽检查。

**主 agent 当前选用的空间方案为 S1，详见第 11 节；第 1–10 节的 8-cell/70-cycle 方案保留为备选 T1，不是主稿所选峰值实现，也不能将显式限额称为达到 Rubin 物理峰值。**

现有 REF 的分段单端口逐 word 累加不能支撑上述 8 terms/slot。PERF_PLAN 必须另有多 context、宽归约/累加和结果编码后端；不能只实例化 8 个乘法器就声称整体吞吐成立。

## 2. 三个基线/目标不得混淆

| 名称 | 本次能确认的内容 | 不能宣称的内容 |
|---|---|---|
| REF / PROJECT_EXACT | 现有 RTL 单个共享乘法节点；FP64 on 为53×53→106、132×32-bit RAM；off 为24×24→48、20×32-bit RAM；共享带carry的32-bit word算术；单事务 | 不是完整tcgen05前端，不是Rubin设备拟合，不具有本文PERF预算吞吐 |
| PERF_PLAN | 本文拟定的8个显式term cells、多context exact归约、scale缓存与有界slot调度 | 尚无RTL/综合/频率/面积证据，不标“实现完成” |
| Rubin dense 产品目标 | 单GPU官方TF32=2、FP16/BF16=4、FP8/FP6 Training=17.5、NVFP4 Training=35 PFLOPS | 不能推出物理lane/乘法器数量、每个tuple吞吐、native target映射或项目fmax |

Rubin 50 PFLOPS NVFP4 Inference 是 sparse 产品口径，不能与35 PFLOPS dense training混算。NVFP4产品模式还包括其规定的缩放/软件使用方式，不能把35直接泛化成每个E2M1/scale/BLOCK组合的共同保证。

参考：[官方产品表](https://www.nvidia.com/en-us/data-center/vera-rubin-nvl72/)，单GPU列与脚注2/3；[既有核验](../../../malu/research/rubin_source_crosscheck.md)。PTX9.4、Blackwell执行target和Rubin产品目标继续分开，不能把sm_107自动解释为Rubin。

## 3. 建议模块和责任

下列模块名是项目建议，并不表示NVIDIA已公开同名实现。

| 建议模块 | 主要责任 | 共享/状态边界 |
|---|---|---|
| `tensor_dot_scheduler` | 将合法矩阵操作形成dot工作项；维护原生指令和D对象依赖 | 不把全矩阵指令完成等同于一个dot完成 |
| `malu_backend_router` | 选择REF或PERF；处理明确不支持的profile/载体 | F64、完整F32乘数等项目扩展可留REF；Ti16 raw不得静默重解释 |
| `malu_perf_budget` | 固定窗口限额或混合模式DRR，按接受的有效term收费 | 不按周期、输入beat或op_count容器宽度收费 |
| `malu_perf_context` | dot ID/代次、K计数、数值模式、C、scale句柄和完成状态 | 建议初始Q=16个槽；Q为参数，且须满足反馈/退休延迟约束 |
| `malu_perf_operand_front` | 接收已展开逻辑元素，解码sign/sig/exp/class并与scale配对 | 不能把物理packed K当作logical K；原生descriptor由外层适配 |
| `malu_perf_scale_cache` | 每context当前及next A/B scale，block索引与有效性 | ABfmt、scale_fmt、block和索引分别保存并联合校验 |
| `malu_perf_term_array` | 8个显式独立11×11 full-product cells；每cell独立sign/exponent/class | 一个cell每次做一个数学乘积；不把两个子字塞进一个乘法表达式 |
| `malu_perf_exact_reduce` | 接收最多8个同context精确项，宽对齐和carry-save归约/反馈 | 与REF逐word RAM算法不同；不能混用其吞吐声明 |
| `malu_perf_finalize` | S/C合并、符号/最高位/舍入、目标D编码 | 目标II=1 dot/cycle；延迟待实现，不规定fmax |
| `malu_perf_result_queue` | 缓冲结果、保留tag/代次、向Tensor外壳报告dot结束 | 全矩阵MMA的D写入和mbarrier责任仍在Tensor层 |

dot工作项中的C是该逻辑dot的累加种子。对原生MMA，它映射相应D_old元素；不是独立标量操作。`scale-input-d`如启用，只在seed建立时作用一次，不随每个term重复施加。

## 4. term cell 的格式预算与安全条件

PERF_PLAN仅针对原生tcgen05矩阵类型的数学乘积；不把现有MALU的全部项目扩展自动塞入11-bit cell。

| 输入类别 | 解码后正规数最大有效数位数 | 完整乘积/处理 | 注意 |
|---|---:|---|---|
| F16 | 11 | 11×11完整22位系数 | 不能把乘积先舍入到F16 |
| BF16 | 8 | 完整16位系数，以公共22位承载 | BF16指数范围远大于F16，不能只因有效数短就复用F16指数截断 |
| TF32 | 11（本项目已定义载体） | 11×11完整22位系数 | 原生内部layout为implementation-defined；前端载体/转换必须另标，不假装任意F32都是TF32 |
| E4M3/E2M3 | 4 | 完整8位系数 | 特殊值、次正规数按各自格式解码 |
| E5M2/E3M2 | 3 | 完整6位系数 | 同上 |
| E2M1 | 2 | 完整4位系数 | FP4编码不是普通有符号整数 |
| S8/U8 | ≤8位幅值 | 符号分离后完整乘积 | mixed signedness按合法tuple；C为S32，不进入此乘法器 |
| decoded Ti16 | ≤11位幅值 | 完整22位幅值，sign独立 | 范围±2047；raw S1Z4M11未知，原生接入不能标完成 |

UE8M0只改变指数，系数为1；UE4M3/UE5M3有最多4位有效数，不能只加指数。在已核验的非二次幂scale组合中，A/B是E2M1：每侧`2-bit sig × 4-bit scale sig`最多6位，再用共享11×11主乘法器相乘，足够保留完整结果。

为保持一个slot中8个term的能力，可在每cell的输入侧明确放置小型 **E2M1-sig×scale-sig LUT/组合函数**，其有限映射为最多64种输入，输出最多6位；这是计入资源的专用scale预处理，不是凭位宽假定的免费packing。若决定让主乘法器分时做scale乘法，则该模式每个term消耗的乘法周期必须重新计入预算，不能继续使用相同slot吞吐。

所有指数相加保留完整范围。C/D转换、非正规数、NaN/Inf、signed zero、最终rounding由明确数值profile决定；参数表只说明资源安全，不替代数值契约。PERF若沿用PROJECT_EXACT，必须保持完整数学乘积和全dot精确归约后最终舍入，不能无标记改成每packet舍入。

## 5. 可实现的exact归约/context方案

### 5.1 数学状态与范围

PERF无F64乘数时，可以沿用已证明的`B=−300`、640-bit有符号精确固定点范围（K上限65535）：完整F32项目乘积最低到2^-298；原生scaled低精度组合最低不低于约2^-286，最大有限scaled乘积小于2^286，加K项仍在范围内。若PERF严格只接原生类型，范围余量更大；任何新格式/scale扩展都要重做范围证明。

每context保持两个640-bit carry-save向量S、Ccarry，值为`S + Ccarry`（Ccarry在此是压缩器状态，**不是外部累加种子C**）。负乘积用全宽有符号表示注入；不能只在局部22位补码后丢弃符号扩展。NaN、正/负Inf、zero-sign和错误状态独立保存，不进入有限固定点加法。

每个发射slot只更新一个context，含1..8个有效terms。8个完整系数先按指数对齐到公共网格，再与该context的S/Ccarry进入有明确位宽的多操作数compressor网络。该网络昂贵，但结构是有限且可综合的；不得把8路宽对齐与compressor的成本隐藏成“复用REF accumulator”。

### 5.2 延迟与context数

若归约反馈延迟为`L_acc`，同一context再次发射的间隔至少`L_acc`；计分板或旁路必须执行该约束。建议先以`L_acc=4`为**设计预算**，用Q=16个context交错掩盖反馈；它不是已验证四周期实现或频率承诺。

每context原始S/Ccarry容量为1280bit，Q=16时合计20,480bit，另加元数据、特殊值和队列。context存储至少需要满足一份归约读、对应退休写及finalize读取的时序安排；可用寄存器/分银行热context结构或显式仲裁，不能直接声称映射成一个单端口RAM。

finalize目标吞吐为每周期一个dot结果。对原生dot最小K=8且最多8terms/slot，平均dot关闭率不会超过1/cycle；短于8的项目dot若也路由PERF，需要接受tail/编码瓶颈或新增打包，不继承此界。

若finalize/退休时间为`L_retire`且输出不阻塞，一个保守的context预算条件为`Q ≥ L_acc + ceil(r_dot × L_retire)`。Q=16在`L_acc=4、r_dot≤1、L_retire≤12`的预算下足够；参数改变必须重新检查。输出长期停顿没有有限Q能保证无限供数，满时必须反压，不能覆盖仍未退休的context。

### 5.3 指令边界和数值一致性

原生MMA的D可见格式/指令边界必须保留。不能把多条MMA跨边界合成一次未舍入长dot，再声称与逐条写回D逐bit等价。PERF内部可任意拆packet，但PROJECT_EXACT的单个dot结果不应依拆法改变；设备拟合profile若有特定分组，则另立规则和验证。

ctx token应含context ID和generation，乘积、归约、finalize及response均携带它。reset/abort后旧代次结果不能写入新事务。TMEM D对象依赖和全矩阵完成由Tensor外壳维护，不由MALU用一个“空闲”信号代替。

## 6. scale caches 与带宽

8-term packet在BLOCK16/32模式中最多跨两个A scale block及两个B scale block。允许任意起始offset时，每个context至少预留current/next两份A scale和两份B scale的可用入口；否则必须在边界减小发射宽度，并如实降低吞吐。

cache key至少包含dot/context代次、A或B角色、logical block index、scale_fmt和layout解析后的引用。cache保存decoded sig/exp/class；block16/32是运行时字段。不得仅按payload相同就合并不同tile，也不能在本block某些terms未消费时覆盖该scale。

稀疏前端需在进入MALU前恢复每个保留乘积的logical k和scale映射。压缩位置不等于原始K坐标；不允许用packed数组下标直接推进scale。native descriptor共同的scale type限制和target门禁仍在外层合法检查。

瞬时8-term输入数据带宽至少为`8×(wA+wB)`有效bit/slot，实际容器/padding另算。FP16/TF32等原生K不同，C/D和metadata开销也不同；最终供数带宽须按矩阵复用和layout核算。scale cache能摊销访存，不等于scale载荷、预处理或跨边界选择没有成本。

## 7. 70-cycle有界预算的严格定义

| 模式 | 每70周期允许的8-term slots | 理想平均terms/cycle | 对F16/BF16归一化 |
|---|---:|---:|---:|
| TF32 | 4 | 32/70≈0.457143 | 0.5 |
| F16/BF16 | 8 | 64/70≈0.914286 | 1 |
| FP8/FP6 Training组 | 35 | 280/70=4 | 4.375 |
| NVFP4 Training组 | 70 | 560/70=8 | 8.75 |

可用phase-accumulator均匀释放slot许可：每cycle分别增加4/8/35/70，达到70时允许一个slot并减70。持续ready且完整packet时，相邻许可最大间隔分别18/9/2/1周期。未接受的slot不收费；实现应设置有限credit/debt上限，防止长时间停顿后出现未预算的无限burst。

表中是**同一模式独占时采用项目配比限额的工作点**。FP16同样使用11×11 cells，硬件并没有数学上不能发8terms/cycle；较低额度是显式资源预算选择。该透明限制比将配比伪装成自然packing倍率更可审查。

### 7.1 混合backlog不得超额承诺

四种模式同时要求上述完整70-cycle额度时，需要`4+8+35+70=117`个slot，超过70个可用slot。因此只能选择以下明确策略之一：

1. **同质配比限额模式**：以单一模式/工作阶段评估上表；并发竞争时允许降速，不提供同时保底承诺。
2. **混合加权DRR模式**：以117个已接受slot为一个完整权重轮，各模式获得4/8/35/70个slot，资源池无空转时总发射仍≤8terms/cycle。份额比保留，但各自绝对terms/cycle变小。就绪流可借用空闲份额；借用后的实际比例应单列，不能仍称严格产品比。

推荐主稿同时定义这两个配置的目的，禁止将“单流限额上限”“混合公平份额”和“物理峰值”用同一个吞吐字段表示。若主稿只保留一个模式，应写清选择，不让调度器默默改变含义。

### 7.2 term issue不等于dot completion

一个dot长度K时，无其他瓶颈的平均完成率上界约为`q_term/K`。例如原生TF32 K8、F16 K16、FP8 K32、FP4 K64，对应不同K，即使term比为目标比，dot/s比也不是0.5:1:4.375:8.75。

按常见dense MAC=2ops的统计，吞吐上界写成`2×q_term×f_clk`，不是`q_dot×f_clk`，更不是直接把term cell数量称为PFLOPS。scale预处理若不计入产品FLOPS，应另列其资源/能耗，不把辅助乘法计入有效矩阵工作量。尚无f_clk与PPA，所以本文不给绝对TFLOPS/PFLOPS。

## 8. 可选空间扩展及为什么不是第一步必选

若后续需要更高绝对吞吐，可显式扩展为70个同构term cells，并按TF32/F16/FP8/FP4分别允许4/8/35/70个term/cycle。该整数分配同样保留目标比，不需要packing假设。但它要求相匹配的归约分银行、context更新、至少足够的finalize吞吐与scale/数据供给；不能沿用8-cell后端后只改发射掩码。

该路线在高精度模式可能大量闲置同构cells，其面积效率尚未知。因此本记录将其作为有明确代价的后续空间方案，不能用Rubin比例倒推出“应有70个实际乘法器”。任何子字分解/共享部分积优化应在独立数值、进位隔离和综合证明之后再替换同构cells。

## 9. BF16/TF32、Ti16与profile风险

- BF16/TF32的宽指数与F32累加范围必须保持；不能用“BF16尾数8位”“TF32尾数11位”推断只能用窄指数累加器。
- TF32 raw载体由项目转换/适配明确，不能无来源断言PTX固定1+8+10内存位域。现有REF低13位清零协议可作为项目模式保留，但不能自动接受任意F32 raw。
- Ti16 raw S1Z4M11缺完整编码依据；decoded接口范围检查不等于原生接入完成。该缺口不能以提高吞吐预算或乘法器11位刚好够为由略过。
- PERF若改变归约组、舍入点、FTZ或NaN/Inf规则，必须改变numeric profile并重新建立oracle。不能一边复用REF向量一边取消其exact承诺。
- 设备拟合需固定GPU/指令入口/编译目标；论文中的B200模型不推广Rubin、FP6/FP4、blockscale或Ti16。

## 10. 验证/综合进入条件

1. REF保持现有独立Fraction oracle与实际回归证据；PERF作为新实现单独验证，尤其packet拆分、context交错、long cancellation、负零与定向下溢。
2. 对70-cycle许可数、117-slot DRR份额、credit上限、非就绪不收费、无饿死给出精确监测；分别统计valid terms、accepted slots、dot close、D写回与MMA整体完成。
3. 在scale边界offset、两个cache入口更替、稀疏logical k映射、多context同D依赖、reset/abort代次过滤与结果反压下做交叉测试。
4. 综合前资源表至少列：8个11×11 cells、显式scale预处理、8路宽对齐、多输入宽compressor、Q份S/Ccarry状态、finalize与队列。不能只统计乘法器忽略宽归约的主成本。
5. 尚未有后端综合和存储映射证据，不报告fmax、门数、DSP/SRAM宏数量、面积、功耗或达到Rubin峰值。

原生格式/scale/target来源为上传PTX9.4 §9.7.18，尤其表50/53–55（PDF700–704、724–726；印688–692、712–714）、block scaling表70–71（PDF781–782；印769–770）。REF源与验证边界见[项目实现说明](../../../malu/RTL_IMPLEMENTATION.md)，数值范围和独立审查详见输出研究记录 `/workspace/output/malu/rtl_review_arithmetic.md`。本文为设计建议，不是完成声明。


## 11. 主稿空间方案 S1 的独立位宽/资源/吞吐审查

主 agent 选择 S1 作为 **尚未实现的空间资源预算**：8 个 base groups，每 group 两条 full-product 高精度通道；F16/BF16 共16 terms/cycle、TF32 共8、FP8/FP6 共70、FP4 unscaled 共140。与F16/BF16归一化为0.5:1:4.375:8.75。以下审查不把该 raw/MUL 入口预算提升为端到端保证。

### 11.1 显式砖块模式与计算完整性

- 每条11×11高精度通道可按`[4,4,3]×[4,4,3]`分解为9个最多4×4乘法砖，正确汇总全部移位部分积成22位full product。高3位分片必须补0，不能把不存在的第12位带入计算。
- low-float模式每条通道显式使用其中4砖形成4个独立sig4×sig4乘积，因此16通道形成64个low terms；再加6个显式low booster得到70。其余砖按该模式停用/门控，是项目选择而不是由11/4自动得到的packing倍率。
- 每个4×4砖在FP4模式改为两条**真正隔离的2×2乘积路径**，停用交叉项并单独取两份4-bit结果，才得到128+12=140个FP4 raw terms。若只是把两个数塞进同一4×4整数相乘，交叉项不会自动消失，该解释将是错误实现。
- 每group只开放一个TF32解码/通路的决定，使TF32为8而F16/BF16为16；这是明示的资源/使能分配，不是两种格式有效数同为11位却自然出现2倍差异。
- BF16保持完整指数范围和16位乘积系数，TF32/F16保持22位系数；不能在重组砖结果时提前按输出F32/F16舍入。原生Ti16 raw仍为缺口，decoded幅值11位可复用硬件并不解决native编码问题。

### 11.2 FP4共同分段的整数化证明

对E2M1有限值，令`q=2x`，其合法值为`{0,±1,±2,±3,±4,±6,±8,±12}`。于是：

- 每个`qA×qB`的幅值最多144，按**有符号9位**或8位幅值+sign承载；不能装入signed8，因为+144不在范围内。
- 16项共同scale分段的和幅值≤2304，signed13足够；32项和幅值≤4608，**signed14足够**。
- `SA_sig×SB_sig≤15×15=225`，以unsigned8承载。
- 最坏32项blocksum再乘scale系数的幅值≤`4608×225=1,036,800<2^20`。使用14-bit幅值输入×unsigned8→22-bit幅值、sign独立的统一后端安全；如果直接signed乘法，必须正确zero-extend unsigned scale，不能让bit7被解释成负号。
- 注入640-bit exact accumulator的指数应为`eSA+eSB−2`，其中−2来自原始`qA qB/4`；遗漏该项会让结果大4倍。

FP4原2×2 sig乘积并不是q的完整8-bit乘积；应结合每个输入指数做有界左移，还原到共同1/4数值单位。需要计入每term的解码/移位和sign扩展，不能将140个“2×2 raw products”直接当成140个已经对齐的有符号整数项。

这一factorization在PROJECT_EXACT有限数数学下成立；若设备profile规定不同中间舍入，不能无证明复用。scale NaN必须独立分类，即使blocksum恰好为0也不能将NaN吞成0。C只进入最终dot累加器，不注入每个blocksum。

### 11.3 9条fractional-scale backend的资源成本

一个base group两条11×11通道共18个4×4砖。FP4 raw模式只用其中8砖（每通道4砖各拆两个2×2），剩10砖。一个14×8系数乘法可分成`[4,4,4,2]×[4,4]`，需要8个4×4砖；同时预计算一份4×4 scale-sig product需要另1砖。因此 **每base可用9个剩余砖承担一条scale backend+scale系数预计算**，仍剩1砖，位宽层面自洽。

但还必须提供模式mux、8份部分积的完整移位求和、blocksum、寄存器和tag/指数管线。不能因砖数够就假定该14×8网络II=1或满足目标频率；II=1是设计目标，待RTL/综合验证。

6个low booster在FP4 raw模式全部忙于12条2×2路径，**没有8+1个闲置砖可免费形成boost scale backend**。建议独立列出9个额外4×4等价砖和对应重组/缓存成本，或提出明确的跨base共享仲裁并据实际带宽降速。这样raw部分144+6=150砖，若base scale backend复用闲置砖且boost后端额外9砖，算术乘法砖预算为159；这不是总面积，也不包含大量加法/对齐/控制。

这些base闲置砖只在对应low/FP4配置下可用。混合格式或mode切换必须跟踪已发FP4的scale/backend工作，并为砖、部分积重组和结果寄存器保留到完成；不能同周期又将同一砖无条件分配给完整11×11高精度通道。需要明确的resource reservation、drain或分时仲裁规则。159砖仅是配置可放下的结构预算，不表示全部模式可同时按各自峰值运行。

### 11.4 何时9条backend能跟上140 raw terms/cycle

在A/B使用**同一分段边界**、BLOCK16、scale系数和数据持续ready且每backend II=1的理想条件下：8个base各16raw terms/cycle，对应各1个完整16项block/cycle；boost为12terms/cycle，对应平均0.75block/cycle。合计8.75blocks/cycle，9条后端在平均能力上够用。BLOCK32平均为4.375blocks/cycle，能力余量更大。

该结论有明确限制：

1. BLOCK16必须用16项共同scale段，不能先把32项相加后只乘一个scale。14-bit blocksum可统一容器宽度，但不同block不能合并。
2. A/B offset错开时，合法共同段是两侧边界的**交集**。例如BLOCK16的相位相差8，段长约8，需求变成`140/8=17.5`scaled segments/cycle，超过9条。需要限制/规范化原生offset、对任意项目offset降速，或扩展backend；不能声称当前9条覆盖任意offset仍有140完整terms/cycle。
3. 即使共同段≥16，短dot尾部、context切换、cache miss和封包边界也可产生部分block与突发。必须有partial-block上下文与输出队列/credit；不要用平均比掩盖突发冲突。
4. scale_sigA×scale_sigB的预计算每个新pair都需要带宽；它不能与同一砖正在执行的其它算术同时发生。上述8+1砖划分明确为并行资源，若改为分时，必须重新计算II。
5. UE8M0确可将scale作用归入指数，但仍有NaN分类和cache/索引成本；不能因没有fractional乘法就删除这些责任。

### 11.5 dot所有权、累加器与结果能力

建议一个dot在存活期间固定归属某个base group或boost group。F16/TF32/FP8/FP4分别在该group内使用2/1/8/16 terms/cycle，boost使用6/12低精度raw terms/cycle。这样不需要把同一dot跨8组stripe后再做昂贵的跨group partial合并；全矩阵tile由许多不同dot分摊各组即可。

每group仍需按其模式接收完整系数/指数和匹配scale：FP8有变指数的8项宽归约；FP4 fractional路径提供完成后的scaled block；共享本group的640-bit exact context accumulator，按最强入口准备对齐/压缩能力。REF逐word累加不能替代这项新结构。

采用native常见K=8(TF32)、16(F16)、32(FP8)、64(FP4)时，入口预算对应平均dot关闭率分别为 **1、1、2.1875、2.1875 dots/cycle**。因此若要持续S1 raw预算，结果编码和D供给至少需要3条II=1 dot-finalizer的平均能力及匹配seed/D带宽；只有1条finalizer会成为端到端瓶颈。K改变时重算，不沿用这个关闭率。

3条finalizer仅满足平均数，不能保证多context突发无阻塞：9个group可在同周期产生多个关闭事件，已接近末尾的contexts也可能连续关闭。需要预留closure credit、closed-context状态和排队，不能在结果队列满时覆盖context。

context预算可按每group反馈延迟和退休延迟保守计算。若`L_acc=4、L_retire≤12`、每group最多1packet/cycle且FP8/FP4 base平均0.25dot/cycle，则每group至少4份交错反馈context加3份待退休context，初始可以估8份；9groups共72份S/Ccarry状态约92,160bit（11.25KiB）加元数据。**这只是预算例子**，不能在未实现反馈、仲裁与排队前写成容量充分的证明。长期下游停顿必须反压。

### 11.6 S1结论

没有发现S1的11×11分砖、140个隔离FP4 raw乘积或14-bit/14×8位宽存在数学阻断。主稿必须把以下项写成进入实现的检查点：signed9的q-product、共同scale段边界、boost额外资源、14×8无符号/符号处理和−2指数、backend/归约/finalizer II、context与closure credit。

**可表述为：**“S1规划MUL入口资源预算8 TF32 / 16 F16-BF16 / 70 FP8-FP6 / 140 FP4 unscaled raw terms per cycle，在所列scale/backend与供数条件下继续评估有效吞吐。”

**不可表述为：**“现有RTL已达到Rubin比例/140个带任意scale的完整dot terms per cycle/某fmax或面积”。主稿应以S1为选中候选，将第1–10节T1仅列为有界时分备选，避免两套数字混成同一实现。
