# SM 指令发生器验证方法独立审查

审查者：agent2；日期：2026-11-08（UTC）。对象是**发生器验证计划的方法**，不是 SM 指令发生器、编译器、参考模型或 SM RTL 的实现。本文只写研究输入，不修改主 vplan、构建器或 RTL，不提交仓库。

依据：[SM 架构 v1.0](../../../../../docs/sm/SM_ARCHITECTURE.md)、[PTX 9.4 指令清单](../../../../../docs/sm/research/ptx94_instruction_inventory.md)、[执行语义审查](../../../../../docs/sm/research/sm_execution_architecture_review.md)，以及现有 dot-only MALU 的实现边界。固定 PTX 为用户上传 Release9.4（2026-07-17）；本轮不联网，不把旧官网快照更新为新的访问日期。

## 1. 主结论与 feature ID 对接

发生器正确性至少有四个独立问题：生成的对象是否满足所选输入层语法/类型；是否属于目标 ISA 与项目 capability 的合法交集；合法程序能否在受支持执行模型下产生有定义的行为；实际执行的结果/顺序/完成是否被独立检查。不能以随机种子多、生成文件大、指令目录无漏项或仿真没有崩溃替代上述证明。

| feature ID | 本审查建议的核心责任 |
|---|---|
| GEN-ISA-01 | 分层输入、逐形式合法性、target/capability 与负例分类 |
| GEN-ALU-01 | 定宽整数、carry/borrow、packed、位操作及实现相关边界 |
| GEN-FP-01 | 普通 scalar/packed/mixed FP、数值 profile、精确/误差/允许集合 oracle |
| GEN-CVT-01 | 数值转换/packing、舍入、padding、随机位输入及合法类型表 |
| GEN-CTRL-01 | CFG、分歧/重汇合、每线程状态、调用/返回、进度约束 |
| GEN-COLL-01 | 逐指令的参与者、membermask、动态实例、合法退出及 guard |
| GEN-MEM-01 / GEN-SMEM-01 | 地址对象、访问范围、原子粒度、owner、冲突及可见性 |
| GEN-SYNC-01 / GEN-ASYNC-01 | phase/report/proxy、部分/整体完成、跨线程交接与生命周期 |
| GEN-TMEM-01 / GEN-MATRIX-01 | allocation/permit、fragment/tuple、C seed/shift、scale/sparse 及 dot profile |
| GEN-CLUSTER-01 / GEN-FABRIC-01 | peer/endpoint/运行时服务、完成单位、失败与跨端 owner 责任 |
| GEN-TEX-01 / GEN-SYS-01 | 关闭能力的拒绝，启用后有效对象、系统/特殊寄存器语义 |
| **建议 GEN-DEP-01** | RAW/WAR/WAW、CC/predicate、片段/部分写及重命名后的真实覆盖 |
| **建议 GEN-COV-01** | generated/admitted/completed/checked 计数点、可达 bin 与豁免 |
| **建议 GEN-REPLAY-01** | 完整制品重放、独立随机流、失败归类与保持合法性的 minimizer |

这些是拟议计划项，尚无新增测试运行或覆盖数字。后续主文若使用不同扩展 ID，应建立显式映射，不能悄悄出现未被回归收集器识别的 feature 名。

## 2. typed IR / PTX / 项目 native 的分层

| 层 | 发生器输出与检查对象 | 当前限制 |
|---|---|---|
| 语义 typed IR | opcode family、明确的类型/修饰符、线程/对象身份、依赖与预期效果 | 可先冻结语义 schema；IR 字段不等于 NVIDIA 指令编码 |
| PTX 文本 | 固定 `.version/.target/.address_size`、变量声明、CFG、指令 tuple | syntax/assembler 接受只证明该工具的接纳，不等于项目 SM 支持；编译优化还可能改变被测指令序列 |
| 项目 native/内部命令 | 经合法化与 lowering 后可由 DUT 接收的机器对象 | 当前编码/完整前端未定，不编造 opcode bitfield、CSR 地址或 native decode 对照表 |
| 系统执行场景 | launch、SM/CTA/warp 对象、存储初始化、异步/SoC 服务和故障时序 | 系统模型与 DUT 能力必须显式版本化；不能靠 IR 文本假定真实服务存在 |

在 native 编码冻结前，vplan 可以列出 native adapter 的契约与验收入口，但把实际 native 编码覆盖标为 pending/blocked，不生成假二进制来“完成”计划。每个用例声明 injection layer、reference layer、target、project profile、capability manifest 和 oracle 类型。

跨层 lowering 验证应保留 source IR instruction ID→PTX source location→lowered/native operation ID 的映射。多指令 lowering、优化删除/融合、寄存器重命名、块重排必须可追溯。PTX 上相邻的两个操作未必在 DUT 上仍是同一个 hazard；不能只在源文本里看到 `r1` 重复就宣称覆盖了物理 WAR/WAW。

## 3. 合法性 oracle 必须独立于 generator

generator 可以使用约束求解器、模板和能力索引提高合法样本率，但最终合法性 checker 不调用 generator 的 `is_legal()`，也不直接信任 generator 自填的 `expected_legal=true`。

建议的独立结构：

1. generator 输出未加背书的 candidate、显式配置和全部对象。
2. 独立 validator 从固定源证据维护允许的 type/modifier/shape/space/target/participant 关系，重算静态合法性与项目 capability；共用 enum/源节号可以，不能共用唯一一份错误的约束判断实现。
3. 执行前 planner/semantic checker 检查 CFG、数据定义、内存范围、collective、owner 与异步生命周期；其证据从程序计算，不能把 generator 的“安全标签”当结论。
4. 有汇编器时，把其接受/拒绝作额外旁证，并记录工具与 target；原生工具不支持项目扩展时，不把它的拒绝误判成项目 generator bug。
5. 故意 mutation 合法样本中的一条约束，检验 validator 能抓到违规；mutation 的预期违规点应由独立规格给出。仅运行 checker 自己构造的正例不足以验证独立性。

不要对所有字段取笛卡尔积后只靠 assembler 淘汰：这会掩盖 sparse/scale、架构专属 target、packed carrier 和参与者的关联缺口。必须统计 generator 候选拒绝原因和分布，防止约束意外过严导致某些合法形式永远不出现。

## 4. 数值 oracle：结果类型与允许集合

| 数值域 | 独立检查方式 | 关键定向边界 |
|---|---|---|
| 定宽整数 | 任意精度整数算数学结果，再按指令规则选段/扩展/wrap/sat；不依赖 host 有符号溢出 | 0、±1、MIN/MAX、乘积高位、`.wide/.hi/.lo`、进位/借位、极端 shift、packed lane 互不串扰 |
| carryless / logic | 独立 bit-vector / GF(2) 模型；与普通整数乘加分离 | clmad hi/lo、位编号、LUT 真值表、跨字片段、未找到编码 |
| 精确规定的 FP | 独立正确舍入参考（如经版本锁定的 SoftFloat/MPFR 或整数/有理数模型加完整特殊值规则） | 半 ULP、舍入进位、消去、±0、最小/最大 normal/subnormal、overflow、NaN/Inf、0×Inf、FTZ、符号和 payload 的规定/未规定部分 |
| `.approx` 数学 | 按该指令定义的误差界、范围和特例检查 | 定义域分段、极端指数、误差界两侧、NaN/Inf/零；不一概逐 bit 等同 host libm |
| implementation-specific | 明确项目 profile 或允许结果集合/关系检查 | 负数 remainder、tie-break、某些 NaN 编码等；不把 host 选择称作 PTX 唯一答案 |
| matrix/dot | 选定 profile 的独立向量数学模型，另外检查矩阵布局/参与/完成 | C seed 只注入一次、C shift 不重复/提前舍入、scale 格式与 BLOCK16/32 独立、稀疏逻辑 K 与压缩布局、native profile 与 PROJECT_EXACT 分开 |

普通 FMA 的 fused rounding、packed 每元素结果和 matrix reduction 是三个不同检查合同。host double 不是全部 F32/F64 FMA 的充分参考，更不能用普通 FMA 序列替代 PROJECT_EXACT dot 的精确归约。oracle 不调用 DUT 的 decoder、round_pack 或分段累加函数生成 golden。

除了数值，检查 predicate/CC 的定义与未改写状态。浮点 `.sat/.satfinite/.relu/.ftz/.noftz/.pzo` 不共用一个含糊的“saturate”标志；转换 `.rs` 的显式 `rbits` 必须记入样本和重放制品，不能由 scoreboard 随机再生成一套。输入与 golden 的格式、载体位、padding、有效位宽分别记录。

## 5. CC、特殊寄存器与 CSR 的区分

PTX 隐式 `CC.CF`、`.pred`、只读 `.sreg` 与项目未来控制状态寄存器不是同一对象。PTX 普通 FP 舍入/FTZ 大多由指令形式表达，不能套用一个未定义的全局 FP rounding CSR 改变其语义。

- GEN-ALU/DEP 检查跨交错 warp/thread 的 CC 隔离、带条件的 carry 链、helper clobber 与 call 边界；不能要求原文未保证的 CC 跨 call 保存。
- GEN-SYS 对 `.sreg` 按各自范围/稳定性建 oracle。`warpid/smid` 等不能一概在首次读取后缓存为永恒真值，计时/工具寄存器按规定关系或允许集合检查。
- 如后续存在 project CSR，另冻结地址、可读/可写属性、privilege、mask/reset/side-effect、context 保存与访问错误；放独立能力项。未冻结前 CSR 编码/功能覆盖为 pending，不能用 RISC-V 或别的 GPU CSR 约定补齐。

## 6. RAW / WAR / WAW 与实际执行依赖

发生器应产生显式 def-use/alias 图，并且 checker 从最终注入对象重建依赖。最小依赖身份应包含 thread/active-lane、寄存器类及范围（含多字/片段）、predicate/CC、动态执行实例；只用一个全 SM 的 `register_number` 不够。

| 依赖 | 应形成的定向场景 | 检查终点 |
|---|---|---|
| RAW | 短/长延迟 producer→consumer；多片 load/convert→ALU；predicate→branch/guard；CC 链 | 不能第一片返回就 ready；consumer 使用正确 producer 的完整值 |
| WAR | 慢操作尚未捕获的 source 被后写覆盖；descriptor/多寄存器向量的分批读取 | 发射时 source 已复制或仍受保护，后写不污染旧操作 |
| WAW | 同目的不同延迟写；masked/partial 写；异步返回与新 generation | 最终值及中间消费遵守定义的程序/操作顺序，旧返回不能覆盖新责任 |
| namespace alias | b64/b128 与承载字、packed/partial destination、不同 thread 同编号 | 仅在项目机器 IR/寄存器别名规则实际存在时检查，不凭 PTX 虚拟声明发明重叠 |
| predication | producer/consumer guard相同、相反、部分交集；predicated-off 写 | 没发生的写不是新 producer；被屏蔽 lane 保持原先定义状态 |

WAR/WAW 的机制依微架构是否重命名而异。若编译器已经消除了源级 hazard，记录“源级样本生成但 DUT hazard 未发生”，不得加进 DUT hazard 已检查 bin。形成真实执行交错可用不同合法长延迟、共享资源压力或受控返回延迟；不能由测试平台直接违反协议伪造 hazard。

架构依赖测试不等同 scoreboard 实现测试；只有 DUT 前端、调度和寄存器结构实现后，才能把相关 monitor/断言标为实际执行。

## 7. CFG、ITS 与 collective 程序构造

CFG generator 应在结构化模板与受约束图之间组合，并记录基本块、边、循环上限、每线程 guard、支配/后支配、call frame 和 object lifetime。参考解释器从实际线程状态推进，不能假设整 warp 永远同 PC，也不能把 ITS 解释为32线程任意独立发射。

- 合法主回归先保证所有被读取寄存器已定义、循环有界或有可证明进度、调用/返回匹配，内存和异步对象在使用期间存活。资源不足而未admit的CTA不能成为已驻留线程解锁的必需条件。
- 分歧、重汇合、sub-warp等待、提前退出分别建样本。`.uni` 只在相应动态 active threads 的条件和目标确实一致时使用；一致性证明不能只看某次 generator seed 的 host 标量。
- 每条 collective 使用自己的参与者规则：membermask、非退出成员、uniform 参数、aligned 条件、同一动态实例；不要建立一个笼统“mask非零即合法”的共用约束。
- 同 PC 不同循环轮次/调用实例不得误汇合；成员暂时不 active 不能自动等同已退出；guard/predicate、active mask、membermask 与 Tensor output mask 保持独立。
- barrier、TMEM alloc/free、group2 pair、WGMMA/tcgen05 和 Fabric pullred 的参与合同分别建模板。Fabric pullred 的0xffffffff与“所有lane未退出”不能被一般subset模板弱化。
- 正常样本不故意制造 ISA 未定义的 collective 缺员死锁。对合法压力下的停滞，watchdog需要记录外部公平、服务上限与等待图，不能只把固定周期超时一律判作 DUT bug。

控制覆盖至少包含“生成CFG”与“实际执行过的边/分歧/重汇合/collective实例”两层。随机程序中不可达块、被 guard 屏蔽的指令不算执行覆盖。

## 8. 存储、异步和系统模型对方法的影响

GEN-MEM/SMEM/SYNC/ASYNC 的主回归生成 race-free 或有明确定义允许结果集的程序。无同步读写竞争不能让一个顺序解释器随意选出的值变成唯一 golden；memory litmus 按禁止/允许结果集合及真实观察点检查。

空间对象包括 CTA shared owner/base/range、thread local、global、TMEM allocation、descriptor、multimem VA 与 CFT handle。地址相等/别名由相应对象解析，不由随机整数相等代替。关闭的 texture/Fabric/native Ti16 等能力只能进入预期拒绝回归，不伪装成正常可执行功能。

异步 scoreboard 需区分 issue/admit、source reusable、数据提交、proxy可见、对象更新、最终完成和 consumer检查。Tensor A-read、bulk wait.read、Fabric local-source read不能代替 full done；mbarrier v1 primary/report与conditional分开，Fabric bytes/16B计数与TMA bytes分开。

受控错误、reset或abort样本必须声明取消边界。late return/owner generation保护不代表外部副作用已撤销；不能在已经发生SoC store之后简单重置golden为初始内存，再把不一致称DUT失败。失败与取消的合法终结状态另建oracle，不能算作正常数值checked。

## 9. 负例 taxonomy 与 ISA UB 的隔离

| 类别 | 注入层与预期 | 禁止的验收方式 |
|---|---|---|
| 静态语法/类型/target非法 | 对parser/legalizer/assembler检查有定位的拒绝 | 送入未定义native编码，再要求SM返回固定PTX异常 |
| ISA合法但项目capability关闭 | 对项目入口检查unsupported及不接收副作用的合同 | 算成DUT数值失败，或算成该功能数值覆盖通过 |
| 项目运行时BAD_ENCODING/BAD_CFG | 只在已有接口明确规定相应错误状态时注入；检查status、响应、清理及正式副作用边界 | 将MALU的错误枚举直接推广为全SM/PTX统一异常 |
| 系统可报告失败/故障 | 在对应SoC模型/接口约束内注入；检查report、完成、恢复/隔离责任 | 成功与失败报告共用固定全零golden；对有副作用操作无条件重试 |
| ISA undefined behavior | 默认不进入有定义结果的主回归；可另作明确标记的鲁棒性探索 | 为UB指定唯一数值、顺序、trap或完成期望，并计为ISA功能pass/fail |
| unspecified / implementation-specific | 按原文允许集合/关系或明确project profile检查 | 当作UB全部跳过，或当作唯一设备位模式强行比较 |

静态负例尽量单点mutation，并保留原合法样本与准确违规关系。若多个约束同时破坏，不能用任何拒绝都算“目标约束被检出”；需验证诊断或独立缩减证明。负例计数、accepted-positive计数、UB探索计数、expected-reject计数分别报告。

## 10. 覆盖计数点与可达性

generated/admitted/completed/checked 必须各有事件源和统计单位，不能四个计数器都在generator循环中自增。源程序静态instruction数量与运行中动态实例数量不能直接比较成丢包率。

| 计数点 | 事件源 | 必须附带的说明 |
|---|---|---|
| generated | 落盘的样本/IR或候选生成记录 | candidate、合法program、静态instruction还是已展开动态计划；validator结果；负例单列 |
| admitted | DUT/adapter实际握手或正式接收monitor | injection层、操作ID、thread/lane mask、完整/片段；pipeline stall期间不得重复计数 |
| completed | 对应架构终点的monitor事件 | 普通writeback、store语义终点、async full、partial、error/abort分别建类别；不是统一response valid |
| checked | 独立checker实际得到足够定义信息并完成比较 | 检查类型、oracle profile、mask、比较范围、pass/fail/inconclusive；无比较不算checked |

建议终结记录按 `(run, program, kernel, CTA/generation, warp/thread, dynamic instruction/operation, lane/fragment, feature)` 关联；实现可用稳定引用压缩字段。一个指令命中多个feature bin时，不把这些bin命中数加和成指令执行数量。

coverage分母需列出：目标合法集合、已实现capability、启用oracle、可达CFG与系统服务。capability关闭、native编码未定、原文歧义、未实现oracle的bin以blocked/waived及原因显示；不能从报告悄悄删除。217个说明节的目录coverage与全部合法tuplecoverage分别定义，目录行全部映射不等于合法tuple穷举。

优先使用有意义的条件交叉：format×rounding×exception-class、opcode×dependency×lane-mask、scope×proxy×ordering、kind×scale-format×block、collective×divergence×participant。非法/不可达组合过滤必须有独立理由；全面笛卡尔积只会制造无法关闭的伪缺口。

## 11. 重放制品与独立随机流

seed不是完整重放合同。每个失败至少保存：

1. 原始seed、子流派生规则、PRNG/solver版本，generator/schema/spec/target/capability/model/DUT/toolchain的hash或版本。
2. typed IR、最终PTX/native或正式命令流、lowering/优化映射、launch与对象布局、初始寄存器/内存、显式rbits、相关scale/metadata。
3. 发生器数据流、调度/反压流、SoC延迟/故障流、reset流的独立seed；实际外部输入事件trace及稳定操作ID。
4. checker使用的oracle profile、实际观察与预期集合、首个失败断言/比较、完整状态/等待链、覆盖计数与日志。
5. 一条可运行的重放入口及参数。当前尚无发生器时，这个入口标为待实现，不编造已存在的命令。

独立子流减少“增加一项覆盖就改变所有后续延迟”的耦合，但跨版本仍要优先重放已物化制品，而不是只从seed重新生成。多线程/并行回归保存稳定排序，不能让filesystem迭代顺序或wall-clock时间暗中改变样本。

重复出现的失败先按首因、架构终点和操作身份归类；同seed重跑偶然通过不能自动删除第一次失败。无法重放时记录nondeterministic/inconclusive与缺失信息，不以“环境噪声”未经证据免除。

## 12. minimizer 必须保持合法性与同一失败

采用分层缩减：program/CTA/warp/基本块→指令/依赖链→loop次数→数据位/格式边界→内存/异步事件与延迟。每次候选都重新运行独立合法性检查、初始化/CFG/参与者/生命周期检查，再执行同一检查路径；不是删到仿真仍超时就结束。

- 保留原失败谓词，例如同一数值不一致、相同错误完成责任、同一有定义的禁止memory outcome；不得把原先数值失败缩成未初始化读取、collective缺员或不受支持opcode。
- 缩减到只剩一个CTA可能破坏group2/cluster合同，删掉fence可能把有定义失败改成data race，删掉producer可能制造未定义值；这些候选必须拒绝。
- CC/predicate与多片寄存器依赖、对象分配/释放、mbarrier init/expect/complete/wait、Fabric submit、scope/proxy与error注入窗口都是必须维护的依赖。
- 静态负例保留目标违规点；runtime负例保留规定错误接口及唯一故障；UB探索不与合法回归互相缩减/混报。
- 原始失败制品永久保留。缩减后IR/native、外部trace、oracleprofile和合法性证据另存，不能覆盖原样本后只留下“最小seed”。

## 13. 后续主 vplan 的审查门槛

主文 ready 后，独立审查至少核对：所有feature是否具有输入层、前置条件、生成策略、独立oracle、观测点、coverage和可重放证据；负例是否有定义的拒绝/故障合同；CFG/依赖覆盖是否由实际动态事件确认；模型与generator是否共享了会掩盖同源错误的判断；关闭/未实现能力是否如实标注。

只有计划、没有实现时，结论应为“vplan方法与责任已审查”。已有MALU回归不得转换成发生器、自带constraint solver、全SM、SoC、TMA/Fabric或native编码的通过率。

本轮未新增发生器/检查器代码，未执行新增随机用例、数值仿真、覆盖回归、重放或缩减；上述均为后续实现与验收的计划要求。

## 14. 主 vplan 初轮只读审查（2026-11-08）

已阅读主文24章正文及25个feature/106个test的展开表，重点核对本方法审查负责的oracle、数值、依赖、CFG/collective、负例、coverage、P1/P2门禁、replay/shrinker。另直接读取 `vplan_features.json` 与 `testpoints.json`，用独立Python脚本核对数量、状态及phase→CV scope关联；没有调用generator、SM或SoC执行环境。

本次读取快照：主文SHA-256 `6912d65708a328fbff08e205a9c82050ce909a9726536443e0bda05751ecd3ec`；features JSON `44623360505b8d6174fe7ac273b29de44e462130533c102557bd25f724a06cc2`；testpoints JSON `7caaac08a8df693cefb4168b4c80aa5aa89b461e95660187a05092d709bf5bfd`。这些仅定位评审输入，主agent后续会修订。

### 14.1 已核对的计划关系

- JSON实际为25 features、75 CV、106 tests；所有feature与test均为 `PLANNED/NOT_RUN`，没有以本次审查改成PASS。
- test主要phase实际为P1=50、P2=27、P3=23、P4=6。P1/P2引用DUT_SCENARIO CV的数量为0；每个DUT_SCENARIO CV至少有一个P3或P4 test关联。
- 主文明确区分P0元数据、P1发生器、P2参考程序、P3真实SM和P4系统；native编码未定时保持blocked；独立规则/checker不以generator同一predicate自证。
- 主文保留planned/issued/observed-complete、path-sensitive def-use、动态collective实例、异步partial/full、typed count与cleanup；重放物化制品、rbits/子流/工具版本及每次缩减重新合法化亦完整。
- 本处计数是**计划元数据关联检查**，不是106个test已经执行，更不是75个coverage point实际命中。尚未独立穷举全部ISA tuple/所有allowed completion schedule。

### 14.2 必须修正项（已发主agent）

| 编号 | 快照位置/问题 | 必要修正 |
|---|---|---|
| METH-R1 | §5把ISA_UB_QUARANTINE写成undefined/unspecified/缺少确定合同，和§8允许集合/profile判据矛盾 | UB仅用于原文明示undefined behavior；unspecified/implementation-specific另按已审查project profile/允许集合/关系检查。缺oracle属于BLOCKED/UNRESOLVED，不自动把有定义但非唯一的行为降为UB，也不预言trap |
| METH-R2 | §9及SIG-MEM-003预期称race-free程序结果确定 | 无data race不保证唯一结果，例如多thread原子返回值依合法线性化顺序不同。仅证明allowed set是单例的程序逐值检查；其他race-free/atomic程序也使用允许结果集合或合法线性化关系。主文及JSON预期同步修改 |

两项修正前，本审查不建议将计划状态定为技术冻结。它们影响参考模型选择和误报/漏报边界，不是当前尚未实现RTL的缺陷。

非阻断澄清：P1的SIG-COV-001可明确使用标记SYNTHETIC的unit-harness日志测试coverage aggregator，不能填真实DUT_SCENARIO或实际执行计数；P1数值case是在审计候选数据/期望制品，不宣称SM执行。现有§3/§16已有总门禁，补句有利于下位实现。

未修改主文或JSON；本节仅追加独立审查意见，等待主agent修正后作定点复核。

## 15. 主 vplan 定点修正复核与关闭（2026-11-08）

已只读复核主文§5、§7、§9、§15及相应展开测试行，另直接读取 `testpoints.json` 的SIG-MEM-003、SIG-COV-001，以及 `vplan_features.json` 的GEN-MEM-01刺激/检查字段。此次没有重新通读全部24章，也没有执行动态测试。

| 项目 | 复核结果 |
|---|---|
| **METH-R1：UB taxonomy** | **关闭。** ISA_UB_QUARANTINE仅用于原文明示undefined behavior；新增SPEC_UNDERSPECIFIED/ALLOWED_SET，允许profile/关系/集合检查，oracle未闭合明确BLOCKED，未继续把unspecified混成UB |
| **METH-R2：memory结果唯一性** | **关闭。** 主文§9/§15、SIG-MEM-003 stimulus/checker/expected与GEN-MEM-01均同步为单例集合才逐值；其余race-free/atomic/litmus按允许结果或可验证线性化关系，明确无data race不保证唯一结果 |
| SYNTHETIC聚合器单测 | SIG-COV-001明确仅用标记SYNTHETIC的unit-harness日志，测试unit counters，不写真实DUT覆盖或真实run执行计数；仍是P1、PLANNED/NOT_RUN |
| 实际hazard与CC | 主文§7补全source IR→lowered/native→DUT动态实例provenance；只有最终注入流实际形成hazard才计DUT依赖覆盖，源级另计；CC不强制跨call保存，helper按ABI/clobber规则检查 |

复核快照SHA-256：主文 `405f81e6a5ce9105c16f0b0b36574cf5ebd93999a180e3a973bb918f6e1120e3`；features `da3bbcdf098debda8784f5cdb6c0217725a045f21c28e50a36b3ff4d96c816c4`；testpoints `9a230465115ed9e01b8edf64da32aba41af7a2da80b12275e28a8894792018c3`。主agent后续状态/排版修订仍需更新相应快照，不将这里的hash当作后来文件的断言。

**本方法审查提出的两项必须修正均已关闭，定点复核未发现新增阻断项。** 结论仅为vplan方法/责任与元数据的一致性审查；不是发生器、oracle、shrinker、SM或SoC功能测试通过。未修改主文或JSON，未commit/push。

## 16. 冻结前覆盖采样增量复核（2026-11-08）

已只读核对主文§16及JSON中的CV-ISA-002、CV-REPLAY-002，并独立统计全部25个第二CV：均为 `scope=GENERATOR, sample_stage=CHECKED`，各自sampling_note明确独立发生器侧审计完成/分类后采样，接受与拒绝保留不同decision counters，绝非DUT结果事件。此修改消除了仅在LEGALIZED接受事件上采样reject bins的歧义，合理。

再次读取的元数据仍为25features/106tests/75CV；P1/P2引用DUT_SCENARIO CV为0。主文保留P0不采动态CV、P1/P2不填真实DUT覆盖的门禁。快照SHA-256：主文 `29e08a0a10acd72267bfcad59a362746dc34a9d6d40252519c0a9de51027fafd`；features JSON `8ee62fb376abac123d8704fad8d12c03b681e5736890373436b29a585f67a17d`。

**本方法侧冻结前增量审查无新增阻断项，前述关闭结论保持。** 本次只检查计划表述与元数据，不新增动态验证证据；未修改主文或JSON，未commit/push。
