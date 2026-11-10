# SM指令发生器 Testplan：ISA与执行分类独立审查

审查日期：2026-11-10。审查对象为合并后的 `testcases.json` 中 ISA/IR/CVT/SYS/NEG/TEX 六组24个用例，以及主文第1–7、12–14、17章。另对全106例进行源身份/阶段/feature/CV核对，对873条计划记录进行身份与准入核对；不声称逐项完成其他82例的所有数值及资源协议语义审查。

## 1. 初审读取基线

- 主文：`verif/core/testplan/sm_instr_gen/SM_INSTR_GEN_TESTPLAN.md`，SHA-256 `dcfdf14c8b6b1924d6e98a5eb005934404d61d8a50e678e41160b531c0d193e2`。
- 合并用例：`verif/core/testplan/sm_instr_gen/testcases.json`，SHA-256 `3237edb516067f4a6e131e1aa6bc95180d5875bc9624b29d775c1e1ece81587b`。
- 四项 `source_files` 的磁盘文件SHA与记录一致；源vPlan未修改。

## 2. 已完成的独立核对

| 项目 | 读取/核对结果 | 实际含义 |
|---|---|---|
| SIG→TC | 106个唯一case与全部106个源测试点一对一 | title/source_title、phase、feature_ids、coverage_ids逐值一致 |
| 源阶段 | P1/P2/P3/P4分别50/27/23/6 | 不是执行数量 |
| case状态 | 106项均NOT_RUN/BLOCKED_MISSING_IMPLEMENTATION | 未由静态检查改写为通过 |
| 动态profile | 7项均enabled_for_execution=false | exact target、合法形式库和capability未解析仍BLOCKED |
| 静态profile | P0仅metadata validator开启 | 不产生SM或generator动态覆盖 |
| 计划矩阵 | 873唯一run ID、873唯一uint32 seed，CSV同为873行 | 每run的源SIG、phase、profile、timeout保持case身份 |
| suite覆盖 | profile_override全部null | suite不提升源phase或CV scope |
| NEGATIVE | 52个case、每例2个独立基线、104条计划记录 | 不是52次或104次DUT非法指令执行 |
| NEGATIVE阶段 | P1=38、P2=9、P3=4、P4=1 | 含前端拒绝、检查器fixture、定义fault和项目robustness等不同层 |

已确认主文明确区分217说明叶子、215实际指令说明、2控制语法、35节sreg与34个directive；不将说明节、tuple、case和计划run数量混算为opcode或真实执行覆盖。

## 3. 指定24例的语义与准入

- ISA：target/family/type/modifier按独立已审查形式过滤；规范合法、项目启用、lowering证明、外部服务与实际接收分别检查。未知target/profile不得继承默认支持；缺工具或证书不得以非零exit当负例PASS。
- IR：typed语义往返与JSON字节顺序分开；未冻结native后端仅输出/审计IR，不能将PTX UTF-8或JSON当fetch二进制。lowering保留CC、predicate与副作用；真实adapter接收不等于指令完成。
- CVT：NaN/Inf样本只在能编码该值类的合法格式使用，finite-only FP与整数不伪造NaN。显式rbits参与回放。寄存器总量253是约束上界，不假定正好253必有合法recipe。
- 稀疏选择：tie-break以允许集合、索引和值关系检查；合法解压逐位置补零。`index > num_target` 按原文为implementation-specific，不当作UB；`index == num_target` 的原文边界解释保持review gate，不擅自唯一化。
- SYS：sreg只读/稳定性、driver数据、PM undefined与target-specific timer分类；per-CTA global依赖directive/driver，不能译为SMEM。stack属于每thread local frame；quota和系统事件按实际合同，不建立通用FP CSR。
- NEG：UB隔离于普通功能执行，implementation-specific/underspecified/unknown rule不是同一类。单因素mutant需要合法baseline、独立差分与预先声明的检查层/rule。`NONISA_ROBUSTNESS`只在书面项目fault合同下注入，不宣称PTX UB硬件一致性。
- TEX：默认关闭门禁是P1拒绝证据；P2模型和P4真实服务分别准入。P4正向需要完整启用对象/取样/格式/边界合同，不以global load或关闭门禁代替采样执行。

## 4. 初审发现与必须关闭项

### F1：TC-FABRIC-002 缺少NEGATIVE witness

初审该case虽然列入NEGATIVE suite，却只构造合法submit/expect/wait程序；现有parameters、steps和checkpoints没有主动的单因素拒绝trial或定义fault。仅列出“submit遗漏”为fail_criteria，不等于已经定义要生成的负例。

建议：保留合法baseline，隔离复制后仅删除一次必需的 `fabric.submit`，明确program/HB合法化层与 `submit before tracked phase advances` 规则；精确检查“跟踪phase可能推进前缺少必需submit”的程序前置条件，该副本只作audit拒绝，不能送普通执行、期待硬件trap。也可移出NEGATIVE，但需同步case/suite/矩阵及所有计数。

### F2：TC-MEM-002 未实例化“未知属性”负例

初审parameters只列合法属性，步骤最后泛称“输出未知属性的拒绝原因”，没有定义哪个字段发生何种单因素变化、由哪一层以哪条规则拒绝。这不足以落实该case的两条NEGATIVE计划run。

建议：从合法typed属性baseline仅替换一个属性为未注册symbolic token，交给IR schema/属性合法化层拒绝；不猜native保留位，不把构造非法机器编码作为PTX测试。记录baseline、mutant差分、expected layer与rule。也可移出NEGATIVE并同步所有关联和计数。

## 5. 初审结论

指定源身份、profile门禁、24例ISA分类及计划/执行口径未发现其他阻断项。F1/F2需在最终冻结前关闭；随后应重新生成计划矩阵与静态报告的输入hash。本记录的核对仅是计划审查，实际动态执行数仍为0。

## 6. 定点修正复核：F1/F2关闭

本次仅定点读取两项修正的parameters/steps/checkpoints、主文对应详表及它们的计划记录，不重复全稿审查。读取快照：testcases SHA-256 `46d04e772e9f4acd812ffd21f9aff5265f084ab96165f27886fd9ff10ab71c52`；主文SHA-256 `89703225c76ba8feabdffecda4f569e6f59070bd8e6b2af7053faeb085763d70`。

| 初审项 | 实际修正与复核 | 状态 |
|---|---|---|
| F1 / TC-FABRIC-002 | 从完整合法baseline隔离复制，仅删除跟踪phase可能推进前issuer一次必需submit；PROGRAM_LEGALIZER_HB_AUDIT_ONLY按MISSING_FABRIC_SUBMIT_BEFORE_TRACKED_PHASE_ADVANCE拒绝。DUT_execution_allowed=false，非法副本无numeric或trap oracle。步骤、观察点和主文详表一致。 | CLOSED |
| F2 / TC-MEM-002 | 从独立合法属性baseline隔离复制，仅把一个symbol改为TESTPLAN_UNREGISTERED_MEMORY_ATTR_v1；SEMANTIC_IR_FRONTEND_SCHEMA按FRONTEND_SCHEMA_UNREGISTERED_MEMORY_ATTRIBUTE拒绝。无native编码、不lower、不发DUT。步骤、观察点和主文详表一致。 | CLOSED |

两case仍为源P1_GENERATOR_UNIT，CV-MEM-002/CV-FABRIC-002未扩展；profile均TP-GEN-BASE，原fixed seed保持1397555233/1397555267。定点核对它们共10条DIRECTED/NEGATIVE/REPLAY计划记录，phase/profile/case seed与NOT_RUN状态一致。以上是元数据与计划程序复核，未执行任何动态case。

最终限定结论：**F1/F2均已关闭；原指定ISA/IR/CVT/SYS/NEG/TEX与主文审查范围内无残留必须修改项。** 前述初审待关闭状态由本节关闭记录取代；873条计划run仍不代表执行证据。未修改主文、合并JSON或源vPlan。
