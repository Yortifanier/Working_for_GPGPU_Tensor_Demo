# SM 指令发生器 Testplan：资源执行合同独立审查

审查日期：2026-11-10（UTC）。对象版本：2026-11-09 v1.0计划。负责人：agent3。本文只记录只读审查，不改主文、JSON、构建器或RTL，不提交Git。

## 1. 范围、方法和证据边界

实际读取了最终testcases.json中MEM/SMEM/SYNC/ASYNC/TMEM/MATRIX/CLUSTER/FABRIC/LIFE九类42个用例，与原SIG阶段/coverage、authoring稿及主文§4–6、§9–12、§15–17和相应用例详表交叉核对。另读取config_profiles.json、campaigns.json、planned_runs.json，独立重算MALU及shared容量见证。

最终testcases.json是执行合同源，research/cases_resources.json仅为authoring provenance。合并后的suite调整、固定seed和来源元数据不得因原稿不同而擅自回写。此次审查不执行发生器/模型/SM/SoC；数值重算和JSON元数据核对都不是动态功能通过。

## 2. 已核对的数量与状态

| 项目 | 实际读取/重算结果 | 可支持的结论 |
|---|---|---|
| 资源用例集合 | MEM4、SMEM4、SYNC5、ASYNC5、TMEM6、MATRIX6、CLUSTER4、FABRIC4、LIFE4，共42 | SIG/TC一对一无缺项 |
| 阶段 | P1=18、P2=9、P3=10、P4=5 | 与上位源逐条相同 |
| coverage IDs | 42项均与各自源SIG原值相同 | 未借阶段升级采样真实DUT覆盖 |
| 专属步骤/观察 | 每例至少4步、2个checkpoints | 步骤结构完整，不等于已经运行 |
| 当前状态 | 42项全部NOT_RUN/BLOCKED_MISSING_IMPLEMENTATION | 无资源用例伪PASS |
| 总计划 | 106cases、8profiles、6suites、873planned runs | 是计划记录，不是873次执行 |
| 动态门禁 | 7个dynamic profile均enabled_for_execution=false | 当前不会调用未来generator/backend |

SMOKE/REPLAY/STRESS等suite不改变case的phase、profile或CV scope。实际准入还须冻结具体variant、target/capability、规则、预算及环境合同，不能因为case出现在矩阵中就运行。

## 3. 资源与异步执行合同核对

| 合同 | 对应正文及用例 | 只读结论 |
|---|---|---|
| typed对象与初始化 | §5–6、TC-MEM-001/004、TC-SMEM-001 | 完整range先检查后编码，owner/local/generic/TMEM/CFT分型，未定义数据不成为确定gold |
| 多维admission | §4/9、TC-SMEM-001/CLUSTER-001 | S0槽位、R_SM、target单CTA限、SMEM/reserved共同检查；未知量不默认为可用 |
| memory allowed outcomes | §7/9、TC-MEM-003 | 无data race不等于单例；原子返回与最终值按线性化/允许集合，确定子集才逐值比对 |
| 共享池与RMW | TC-SMEM-002/004 | 不给每client复制容量/峰值，b128关闭时无非原子假支持；late scrub锁内重读当前word |
| proxy/version | TC-SMEM-003、TC-SYNC-003 | bank commit、失效实际生效与publish分开；active snapshot和future reuse不同 |
| barrier登记 | §9、TC-SYNC-001/002、TC-FABRIC-002 | 原子arrive.expect_tx，或先expect且保留pending arrival后arrive；不得先释放最后arrival |
| barrier phase/report | TC-SYNC-001/002/004/005 | v0/v1、511边界、signed tx、逻辑phase/parity、primary/conditional及false report分开；对象commit而非FIFO接受才ack |
| 完成单位 | §9/12、ASYNC/FABRIC组 | bytes、arrivals、16B units分别typed；counter bytes另计且中间增长不代表full |
| TMEM生命周期 | §10、TC-TMEM-001/005 | permit与allocation分账、非递增含相等分配、512/576 target、exclusive/释放属性匹配；dealloc不补漏前置等待 |
| TMEM移动/参与 | TC-TMEM-002/003/004 | warp quarter、同base、pack/unpack、red/spcompress、cp/shift、RF片段各有独立检查与终点 |
| group2 | §10/12、TC-TMEM-006/CLUSTER-001 | even/odd跨可互通不同endpoint/SM，双边资源/存活、单parent、同kernel group一致性，无半发布/释放 |
| Cshift与Ti16 | §11、TC-MATRIX-001/002 | Cshift与AB scale/BLOCK分开；native合法kind仍受联合限制；raw Ti16关闭，decoded单列项目扩展 |
| sparse/collector | TC-MATRIX-003/005 | logical/packed/compressed K、metadata/LUT/scale分开；miss不能提前解锁源，A-read不清B/D/full |
| 系统合法故障 | TC-FABRIC-003/004、TC-CLUSTER-002/004 | 报告失败按定义合同结算，不冒充UB或正常零数据；非幂等副作用无盲重试 |
| 全允许顺序 | TC-LIFE-003 | 有界模型声明边界/90逻辑事件顺序例，notification交付独立，探索截断不能宣称all-schedules通过 |
| cleanup/回滚 | §6、TC-LIFE-001/002/004 | body前预留尾部/执行者，CFG全路径闭合，候选回滚不清已发布账本；满载时仍允许必要收尾 |
| reset/abort | TC-LIFE-004及相邻TC-ENV-004 | 正常drain、abort、reset分合同；旧包隔离不等于撤销已commit外部store |

以上项目未发现把下位v1.1队列数当成PTX合法性限制、把P1/P2模型事件当真实DUT事件、或把full与partial统一结清的确定错误。

## 4. 两个 PROJECT_MALU_ADAPTER 见证的独立核算

### 4.1 无AB block scale的C缩放见证

F16项目输入A=B=1，K=4，C=8，s_C=3：

    D = 4 × 1 × 1 + 8 × 2^(-3) = 4 + 1 = 5

这些值和结果都可精确表示，未涉及不明的native矩阵中间精度。enable-input-d=false时adapter不得读取/参与旧D，即使旧D预置qNaN；正式Cseed为零，因此结果为4。该见证属于项目MALU adapter；K4和独立项目请求不能直接写成tcgen05的native shape。

### 4.2 BLOCK32的offset切拍见证

对项目合法低精度scaled组合、K=64、Cshift=0、LANES=4、BLOCK32、A/B首offset15/31：

    first_op_count = min(4, 32-15, 32-31, 64) = 1

第一拍只取1元素，否则跨B块。A的64项分块为17/32/15，B为1/32/31，故两侧均需3个scale payload，而非无offset时的2个。后续游标按整笔logical K推进，不因beat或stall重置。若采用E4M3×E4M3、UE8M0、F32 C/D、scale全1与C=0的已批准项目组合，数学D为64；实际编码须由已核验格式构建器生成。

两见证必须是独立命名/分支配置：F16+Cshift3不与scaled低精度/BLOCK32强行组合，更不宣称存在同时接纳全部字段的native tuple。正文§11已经明确这一边界。

## 5. RE-1：正文见证未进入最终case参数——需同步

初次读取最终JSON时：

- TC-MATRIX-002的project_logical_K为1/15/16/17/31/32/33，Cshift为0/1/15，没有正文K4、s3。
- TC-MATRIX-006的K为1/15/16/17/31/32/33/65，BLOCK32_offsets为0/1/31，没有正文K64及A offset15。

主文§4规定case参数优先，suite随机化也只作用于case明确声明的维度，因此两正文见证在初稿的canonical执行配置中不可实例化。应将两个独立的命名PROJECT_MALU_ADAPTER witness写入testcases.json，并使其选择规则/通用参数允许这些值，或明确独立witness优先规则。scaled见证还须分配与offset一致的3项A/B scale。

已通知主笔；本记录不改JSON。此项是正文与执行合同同步问题，不是否定上述算术。修订实际读取前保持待关闭。

## 6. 未知参数、超时与结果分类

实际核对config_profiles.json和campaigns.json：exact_target、合法形式/项目capability hash、R_SM、单CTA shared上限等仍未冻结；SM_PROGRESS与SOC_PROGRESS的no_progress_window_cycles、hard_simulation_cycle_budget均为null，budget_status为PROVISIONAL_CALIBRATION_REQUIRED。主文§4/15及entry gates明确必须先解析、校准，null不是0，也不是默认无上限而继续准入。

GEN/REFERENCE/SM/SOC的300/900/1800/3600秒是host侧实验预算，非ISA或NVIDIA指令时延。普通P3不能用host耗时推断某条指令超周期或DUT死锁。无诊断的超时保留TIMEOUT_UNCLASSIFIED；缺工具/能力/服务标BLOCKED；外部服务未兑现公平与内部credit环等待需用wait graph、已接受义务和assumption证据区分。

正常soft-drain继续当前程序必要tiles、load、commit/wait/free与barrier，不是停止全部后续指令后等待full。abort/reset走正式cancel/隔离及外部副作用合同。零accepted/零checked、全disabled或仅P0成功均不能关闭106个动态case及873个planned run。

## 7. 初审结论

指定42个资源case及主文相关章节的执行步骤、typed义务、初始化/cleanup、group2、允许顺序、raw Ti16门禁、timeout分类和动态状态总体一致。除RE-1的正文/最终JSON见证同步项外，未发现本轮范围内其他确定阻断项。

本结论属于计划与数据合同审查；不代表发生器、独立参考模型、SM/SoC已实现或任何动态case已通过。后续见证同步后仅定点复核并在本记录追加关闭结论。

## 8. RE-1定点关闭复核（2026-11-10）

已实际读取两个case的最终JSON命名见证、主文§11及两case详表，并静态复读现有malu_pkg.sv的cfg_status相关约束。没有运行RTL，也没有调用DUT解码函数作数值golden。

TC-MATRIX-002已将K4和Cshift3加入通用候选，并增加PROJECT_F16_K4_CSHIFT3：F16 A/B、F32 C/D、AB scale关闭、PROJECT_EXACT。独立有理数/位模式重算确认0x3c00为F16的1，C=0x41000000为8，true结果5编码0x40a00000；false分支旧D=0x7fc00000但读取义务为0、正式Cseed为0，结果4编码0x40800000。现有项目配置规则允许这组类型及Cshift，不能据此推导native K4 shape。

TC-MATRIX-006已把K64、BLOCK32 offset15加入候选，并增加独立PROJECT_E4M3_K64_BLOCK32_OFFSET15_31：E4M3 A/B编码0x38为1，F32 C/D，UE8M0两侧各3项0x7f为unity scale，C=0、Cshift=0。逐拍重算[1,4×15,3]的17拍，每拍均不跨任一A/B块边界、总项数64；A分块17/32/15、B分块1/32/31与scale数量一致。独立结果64的F32编码为0x42800000。静态cfg_status条件允许E4M3/UE8M0/BLOCK32及15/31 offset，实际接口/RTL执行仍未发生。

两个见证具有独立entry和native_gate，没有将F16+Cshift3与低位block scale拼成一个native tuple。相关phase、coverage IDs和fixed_seed保留，最终case总数106、planned run总数873不变；所有用例仍NOT_RUN/BLOCKED_MISSING_IMPLEMENTATION。git diff --check未报告格式错误。

**RE-1已关闭。** 本轮指定42个资源用例及相关正文的计划/执行合同范围内，已无尚待修正的确定阻断项，可冻结评审稿。结论仍不包括generator/reference/SM/SoC动态执行、全部ISA tuple合规或性能通过；未知target/R_SM/周期预算门禁继续有效。

## 9. 全格式与按kind稀疏规则补漏复核（2026-11-10）

按主笔要求仅定点读取当前最终TC-MATRIX-001/003、主文§11及详表，并交叉核对Tensor架构§9.1/§12.1与malu_pkg.sv的is_fp/is_int/is_fp_result/cfg_status；未扩展其他审查范围，未改JSON或主文。

TC-MATRIX-001的native tuple_families已包含i8与ti16，不再只有浮点kind；raw ti16继续关闭。项目输入候选现在完整列出F16/BF16/TF32/F32/F64、E4M3/E5M2/E2M3/E3M2/E2M1、S8/U8/S4/U4/TI16/B1，与package中实际格式枚举集合一致。浮点C/D限定F16/BF16/F32/F64，整数C/D为S32，FP64还受ENABLE_FP64及实际backend门禁。项目F32/F64/INT4/B1能力不被转写为tcgen05原生类型。

最终格式枚举使用真实FMT_TI16；另有project_Ti16_transport明确a_fmt/b_fmt=FMT_TI16、ti16_decoded=true、raw_capability=false、范围[-2047,2047]。不存在FMT_TI16_DECODED伪枚举，decoded语义通过独立控制表达。这与cfg_status对raw拒绝、decoded及类型/饱和限制的结构一致。

TC-MATRIX-003已移除统一六种2-of-4模式，改为sparse_pattern_by_kind：TF32为1:2；规定f16/i8/ti16/f8f6f4/mxf8f6f4族为2:4；mxf4/mxf4nvf4为保持元素pair的成对4:8，不是任意4-of-8。native_metadata_policy明确按精确kind/target/version表验证，不由六种数学位置组合推导原生metadata枚举或删去规范特殊项。上述分型与既有Tensor架构及固定PTX核验记录一致。

项目integer/B1模式独立要求S32 C/D、AB同宽及相应binary flags、block_scale_en=false、c_scale_shift=0；完整数学结果后执行允许的S32 wrap/final saturation。TI16和B1 saturation关闭，B1的AND/XOR-popcount按项目模式分别核对，整数/B1不注入浮点NaN/Inf。cfg_status确有上述类型、宽度、sat、binary_xor和scale/Cshift检查，计划没有据此开启native INT4/B1或raw Ti16。

两case的phase/CV/fixed_seed分别仍为P1/CV-MATRIX-001/1397555256与P2/CV-MATRIX-001/1397555258，106cases/873planned runs数量不变，动态状态仍NOT_RUN/BLOCKED_MISSING_IMPLEMENTATION。主文及canonical参数已同步，原authoring稿保留来源历史，不能覆盖这些合并补漏。

**本次全格式与稀疏分型补漏已核对一致，无新增确定阻断项。** 复核仅为计划、来源和静态配置合同，不代表实际执行或全部格式组合已经通过。
