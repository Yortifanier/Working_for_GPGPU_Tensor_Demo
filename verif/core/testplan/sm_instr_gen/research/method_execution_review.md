# SM 指令发生器 testplan：计算与执行方法独立审查

审查者：agent2；日期：2026-11-10（UTC）。本审查只读主文、配置与计划JSON，只写本研究记录，不修改主文/JSON，不提交仓库，不联网。

## 1. 实际审阅范围

本轮阅读 [主文](../SM_INSTR_GEN_TESTPLAN.md) §7、§8、§13–17，以及七个计算/方法feature的28个合并case与ENV/COV/REGRESS的12个case。另读取 `config_profiles.json`、`campaigns.json`、`planned_runs.json`，独立检查seed、phase/profile、状态和源case保持关系。没有声称独立通读其余66个case的全部技术内容；存储/TMEM/系统等专项由对应审查记录负责。

七个feature为ALU、FP、DEP、CTRL、COLL、REPLAY、REDUCE。通过直接比对 `research/cases_compute.json` 与合并 `testcases.json`，这28例的 source SIG、title、phase、config_profile、parameters、initial_state、steps、checkpoints、pass/fail criteria、coverage IDs、timeout及当前状态均保留。root新增seed/suite/来源元数据和全局wrapper由本轮另查。

当前文件是执行级**计划**，没有generator/参考模型/driver/SM/SoC运行。本次Python只读取JSON并计算集合、整数seed和有理数见证，不构成功能case执行或覆盖命中。

## 2. 已实际复算的数值与计划关系

| 项目 | 本次独立结果 | 证据限制 |
|---|---|---|
| F32 FMA见证 | `(1+2^-23)(1-2^-23)-1 = -1/70368744177664 = -2^-46`；乘积与1的距离小于1下侧半ULP `2^-25`，RNE先乘到F32取1，再加−1得0 | 用Fraction复算数学关系；只支持该明确见证，不替代所有FMA/NaN/FTZ硬件验证 |
| case/profile/suite/run | 106 / 8 / 6 / 873 | 计划条目数，不是已执行数 |
| seed与身份 | 873个run ID、873个seed均唯一；每条符合 `0x534D0000 + source_index + suite_index*0x100000 + repeat_index*0x10000` | 检查了本快照算术，不声称PRNG或发生器确定性已经运行 |
| seed范围 | 1397555200…1402863717，均在uint32内 | 没有溢出或当前矩阵seed碰撞 |
| run层phase | P1=357、P2=201、P3=249、P4=66，合计873 | 独立基线计划数，不包含对其内部replay动作冒充的新运行数 |
| run一致性 | 每条run的phase/profile/timeout与其TC相同，case_fixed_seed符合源身份；均NOT_RUN/BLOCKED_MISSING_IMPLEMENTATION | 没有实际admit/complete/checked事件 |
| 动态执行开关 | 所有PLANNED_DYNAMIC profiles均false；106cases均NOT_RUN | 只有P0工具可运行，不把其PASS写成功能结果 |

本次复算没有发现FMA见证、873唯一seed推导或phase/profile映射错误。

## 3. 计算、依赖、控制与oracle审查

普通ALU使用完整整数/定宽结果和独立CC模型，clmad用GF(2)；普通FMA、packed每元素、SFU逐形式误差与matrix dot profile分开。FP见证的精度和RNE前提写明，NaN/Inf/±0、有限-only格式、carrier/padding、target与修饰符仍经合法表过滤，未用统一epsilon或MALU模型替代普通FP。

RAW/WAR/WAW按最终注入流和source→lowered/native→DUT provenance检查。重命名/优化已消失的依赖只记源级生成；片段ready、source capture保护、producer/lane/generation及CC clobber分别观察。P1的IR/期望/audit不填真实DUT hazard coverage。

CTRL/COLL的全路径def-use、循环ranking、每线程call/return、`.uni`相应site证明、动态同PC多轮实例及成员/退出规则均保留。ITS测试明确驻留与公平假设，不以未驻留CTA解锁或任意固定周期作为保证。尚无动态SM验证证据。

主文§7与ENV/COV/REGRESS的oracle/状态分类正确区分：race-free不等于唯一结果；仅已证明singleton逐值比对，其余atomic/weak-memory按允许集合或可验证线性化关系。明示ISA UB、unspecified/implementation-specific、项目robustness、可报告系统失败与缺oracle/BLOCKED未重新混为一类。

## 4. 预算、压力与门禁

各profile的默认body1024、cleanup128、loop8是**待校准harness预算**，不是ISA限制。计算case中ALU-004的4096 instructions/warp、FP-004的2048 operations/warp、CTRL/COLL的16轮等variant需要显式审查过的case预算覆盖；主文与profile的case-overrides规则已明确，不得截断witness或cleanup来适配默认值。无reviewed override就BLOCKED，而不是声称所有variant按默认profile直接可运行。

timeout host预算与SM/SoC cycle/fairness合同分开；相关cycle字段未解仍null，gate保持关闭。REF的semantic-step预算、shrinker候选/时间预算须按实际case/model成本校准。现在没有运行，不能据这些预算宣称收敛、无死锁或性能达标。

STRESS policy按phase划分：P1为软件约束/候选工作量，P2为模型交错/账本工作量，P3为实际合法admission/返回压力，P4为系统流量和定义的fault。它不改变case phase/profile，不令P1/P2产生DUT覆盖，不临时猜FIFO深度；缺pressure recipe则阻塞该run。此边界合理。

## 5. Replay、seed与保真缩减

REPLAY suite的2次repetition已明确定义为两个独立基线：其planned run seed按矩阵不同；**每个基线内部的replay复用原manifest/data/schedule/seed，不再派生新seed**。campaign wrapper要求恢复独立初态、同phase replay、保存两份证据；未获准候选不得被wrapper送入DUT。

确定性的刺激制品比hash，非singleton执行结果仍按允许关系检查，保故障replay/缩减须保留原failure signature。原始/缩减包、显式rbits、工具/模型/能力/source/bin registry版本与环境schedule均保留。生成重放与故障重现未混成“同seed就证明可复现”。PRNG/子流具体实现版本及派生规则仍需未来manifest和后端合同冻结，本次只证明已写的run-level seed算术一致。

shrinker每个候选重新独立审计CFG、def-use、成员、HB/owner/typed义务与profile，再检查原predicate，不以新UB/新timeout或临时弱化signature充数。P1合成fixture和P2 reference failure须保持来源标记；不能传播成实际SM缺陷/覆盖证据。

## 6. ENV/COV/REGRESS的证据隔离

- ENV-001联合预算包括target/RF/granularity与shared池，8×32KiB只有其他条件允许才可接受；9CTA/8×64KiB为指定不同约束的拒绝见证。
- ENV-002使用SYNTHETIC事务和logical-event schedule；ENV-003把公平链、外部starvation和注入reference内部环等待分开，不从固定窗口直接证明死锁；ENV-004保留外部已commit副作用与cancel责任，旧包过滤不冒充撤销store。
- COV-001是SYNTHETIC unit counter测试；COV-003是reference合并/冲突/零checked测试；COV-004损坏日志只动隔离侧拷贝，真实原件和DUT覆盖不得被改写。GENERATOR/CHECKED未被冒充DUT结果checked。
- REGRESS-001明确P0 metadata PASS不是本P1 TC执行，REGRESS-002预声明统计方法/阈值并分离rare quota，REGRESS-003合成truth table不写真实run PASS，REGRESS-004仅可关闭已启用P3范围、不代替P4。

## 7. 需主agent消除的执行歧义

**EXEC-M1：TC-REGRESS-004的自包含campaign调用边界。** 当前其step2写“按本testplan的P3 case名单运行”，该TC本身又是23个P3 case之一，且属于DIRECTED/RANDOM/STRESS suites。若未来runner直接把该句实现为递归调用全部P3 case，会形成 `REGRESS-004 → P3名单 → REGRESS-004` 循环。

此处不声称当前已存在有bug的runner；本目录尚无runner。执行级计划应在冻结前明确：该TC是**non-reentrant campaign observer/closure检查**，只消费外层campaign已经生成的P3证据；或其子任务显式排除自身及所有campaign orchestrator，并使用预冻结无环执行图。23个源case统计、source phase/CV和当前NOT_RUN状态无需更改。

意见已发送主agent。除这一处执行边界，本审查范围未发现其他必须修正项；待定点确认后可关闭本方法侧冻结审查。

## 8. 审阅快照

| 文件 | SHA-256 |
|---|---|
| SM_INSTR_GEN_TESTPLAN.md | dcfdf14c8b6b1924d6e98a5eb005934404d61d8a50e678e41160b531c0d193e2 |
| testcases.json | 3237edb516067f4a6e131e1aa6bc95180d5875bc9624b29d775c1e1ece81587b |
| config_profiles.json | c1333946347892a52eccffece72606801d2d8bcee4f9c08c5b46733226dbde3e |
| campaigns.json | 5a1919bd35eb9419d86bdfc7df018d95f7ac7a026cdad9ae590d4a51730f9bf3 |
| planned_runs.json | d672c11a90f26b6238d971ed45657497bd60bc06731f8e8c72414a36461b2307 |

hash只定位本次读取输入，后续主agent修订需采用对应新快照。未修改主文、配置或用例JSON，未执行动态功能测试，未commit/push。

## 9. EXEC-M1 定点修正复核与关闭（2026-11-10）

已只读复核主文§13和合并JSON中TC-REGRESS-004的parameters、prerequisites、steps及checkpoint。该TC已明确为 `NON_REENTRANT_CAMPAIGN_OBSERVER`，`dispatches_child_tests=false`；4步骤只加载外层已完成证据、检查scope/hash/cleanup/coverage/triage并产生自己的闭合检查结果，不调用任何TC、runner或observer。缺少必需上游证据为BLOCKED，不会为“凑齐证据”启动子campaign。

独立集合检查确认：源P3共有23例，上游名单恰有22个唯一身份，**精确等于P3集合减TC-REGRESS-004**，没有自身。排除observer/orchestrator角色与显式依赖DAG准入写明；CSV/JSON行序只是枚举，不是执行调度顺序。原source phase/CV、23源P3=22叶子+观察器以及NOT_RUN状态保持。

**EXEC-M1关闭；本方法审查范围内无剩余必须修正项。** 本次为定点计划复核，不重新宣称全文/其他66例专项审查或动态测试通过。读取快照SHA-256：主文 `89703225c76ba8feabdffecda4f569e6f59070bd8e6b2af7053faeb085763d70`；testcases `46d04e772e9f4acd812ffd21f9aff5265f084ab96165f27886fd9ff10ab71c52`；planned_runs `906947d425693aa3f363678b83ba9f373e440a9a2fe2d0602b222b8b88c23e38`。

未修改主文/JSON，未执行generator或RTL，未commit/push。
