# SM指令发生器VPLAN：ISA追踪独立审查

日期：2026-11-08。此文件核对计划追踪，不是发生器、SM模型或RTL执行报告。

## 来源与结构

- 指令来源：`docs/sm/research/ptx94_instruction_inventory.json`，SHA-256 `77f932724a2ab3c91f7d3ab8b60269b6e274afcf43db2c82bed3056f542c126a`。
- 特殊寄存器来源：`docs/sm/research/ptx94_special_register_inventory.json`，SHA-256 `7dfe04b4778c9490864ce705318d353ad17241596ef8d632ea0cf3fc8ac43465`。
- `instruction_traceability.json/.csv`：217个说明叶子，含215个实际指令说明与{}、@两个控制语法；21个§9.7类别均有条目。
- `special_register_traceability.json/.csv`：35个第10章说明节独立列出；两表共252个唯一source section。
- JSON均使用顶层entries；source_refs为仓库相对路径加#节号。CSV的names、feature关联、计划项及policy保留JSON数组/对象编码，避免同节多个名称被分隔符误拆。
- 仅引用root冻结的16个GEN-* feature IDs；通用test_family不是SIG/CV test ID，不代替主VPLAN的testpoint或coverage定义。

## 全部条目的状态与安全边界

- 全部status=PLANNED、execution=NOT_RUN，executed_tests=0。无PASS状态，无RTL通过宣称；217/35/252均不是合法tuple数量。
- 正向只取经独立核验的版本/target/profile合法形式，source target Notes仍由固定inventory提供；本追踪表不制造完整tuple目录。
- 关闭能力预期是生成/合法化入口CAPABILITY_DISABLED，不将其写成PTX规定硬件异常。非法/未定义组合只作为发生器/前端拒绝输入，不生成可执行UB并假设trap。
- Ti16 raw编码/transpose及sparse collector语法歧义只阻塞受影响形式，不把整个matrix家族记为unsupported。decoded项目传输与native语义分开。

## 必须保持的语义区别

- 经典cp.async group、bulk/TMA、WGMMA、tcgen05各自完成；wait_all包含提交；restricted A-read与normal/full独立。
- shared-only st.bulk零初始化与st.async的shared/global形式、global multimem.st.async分别建模。
- bar/barrier、membar/fence的target/修饰条件在计划check保留；{}、@不是独立执行opcode，directives不塞进217条opcode执行计划。
- matrix/warp fragments、logicalK/compressedK、metadata、scale/collector/LUT均需按已核验形式关联；寄存器packed算术和dp4a/dp2a不冒充Tensor。
- 35节特殊寄存器按真实launch/driver/工具状态检查；PM undefined、timer target-specific、可变调度ID、共享分配和per-CTA global切片不虚构数值oracle。

结论：四份追踪文件在说明节级别覆盖完整，规划状态与执行状态分开；下一步仍需主VPLAN feature/testpoint/CV关联检查、合法tuple目录与模型实现。

## 文件回读核验

已实际用CSV reader和JSON parser逐单元格回读四文件：217+35行一致，252个source section唯一，所有源inventory整体SHA与磁盘文件一致；section/names/pages/entry_kind/domain逐项回查原索引一致。CSV/JSON值差异0。该结论仅证明追踪文件的结构、来源和规划状态一致，不计为任何指令激励、checker或RTL测试PASS。

## 主VPLAN关联复核与修正关闭（2026-11-08）

复核25个feature、106个计划case和217+35条追踪。初审发现共享matrix模板使8条§9.7.16和2条§9.7.17的非TMEM接口错误关联GEN-TMEM-01；已获主agent授权，仅从这10条related_feature_ids删除该关联，保持GEN-MATRIX/COLL及相应ASYNC关联、主feature IDs和其余字段。此项是追踪模板关联错误，现已关闭。

- GEN-TMEM-01现只关联§9.7.18的12个说明节、14个标题名称；真实tcgen05四种MMA及alloc/dealloc/permit、ld/st/wait、cp/shift、fence/commit关联完整。ld.red与ld{.red}.spcompress仍保留在同一ld说明节的计划检查中，不另造标题计数。
- 所有252条追踪的primary/related feature均存在于25个主feature中；主feature引用的case ID存在于106项计划目录。
- 两对CSV/JSON实际逐值回读差异0；217+35源节号、名称、页码、instruction kind/domain及源inventory整体SHA再次核对一致。252个source section唯一。
- st.async的shared::cluster/mbarrier与global release形式分开，multimem.st.async保持global release；st.bulk为shared区域置零，未混成泛用memset。
- deprecated shfl/vote保留target门禁；35节sreg独立，不把range展开数或34个第11章directive说明叶子混算为opcode。raw Ti16、未启用前端/SoC/texture等仍受capability gate，禁用证据不计正向DUT覆盖。
- 215实际指令说明+2语法、35特殊寄存器的口径保持不变；全部status=PLANNED、execution=NOT_RUN。计划静态结构核对不是106项动态测试执行，亦非完整合法tuple证明。

结论：本次指定ISA追踪与feature关联范围内无残留必须修改项。下一次静态报告应使用修正后的CSV/JSON重新生成其文件hash；未修改主VPLAN、features或testpoints。
