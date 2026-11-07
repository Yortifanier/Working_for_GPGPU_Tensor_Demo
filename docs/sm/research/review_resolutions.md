# SM 架构三轮文档审查与问题闭合

日期：2026-11-07（Asia/Shanghai）；最终主文SHA-256：`b28eaee5bf381c7dbcc8387687c62bc8030eb722935e11774cf3eaecb20fb0ba`。该hash定位本次架构冻结版本，不作为RTL源码hash。

## 第一轮：规范全集与映射

agent1从固定上传PDF的书签重建节号，再匹配正文及Syntax；215个实际指令说明节与2个控制语法节，共217个Syntax，21大类；另核对第10章35个特殊寄存器说明节。原机器证据保留Syntax/ISA/Target原文，检查器重新提取651份摘录逐项比对。主文附录217+35行均存在。

复查纠正了泛化执行域描述：st.bulk为shared::cta置零；st.async的shared与global形式分开；multimem.st.async为相应global多位置语义；ld.global.nc/ldu的global限定不被generic LSU描述掩盖。实际正向、删行/占位、篡改摘录的临时样例均检查了失败行为，临时样例未冒充主文最终PASS。

范围限定：统计为说明节和标题，不是SASS opcode或全部合法type/shape/qualifier tuple；尚无全SM实现/汇编器测试。

## 第二轮：执行域与集成技术审查

agent2通读26章及附录，检查普通算术/packed FP与MALU边界、ITS/RF/CC、mbarrier布局/报告、TMA、Fabric、scope/proxy和target条件；agent3检查既有Tensor/SMEM/MALU的一致性，独立核对217节身份/页码、35节状态和七图。

| 项目 | 问题或澄清 | 最终落实 |
|---|---|---|
| C缩放 | 仅写C+dot会漏scale-input-d和现有c_scale_shift | §16.1–16.2：true传未缩放D_old/C+独立shift，false不读旧D；C指数变换不提前重新量化，不双重缩放 |
| AB/scale/block边界 | C shift不能混为第三scale矩阵或BLOCK字段 | 数学式、正文及图06分别表达；保持AB格式/scale格式/BLOCK16/32独立 |
| CTA group2调度 | 一个SM一个endpoint与既有双端parent/child协议需明确映射 | §17：S0设备调度保证pair到两个可互通的不同SM/endpoint；说明是项目约束，未定义同SM适配 |
| 单CTA shared限制 | 256KiB物理池不能自动成为任意target的单CTA声明上限 | §12.1：target/ABI/capability上限与SM联合预算同时检查 |
| Scalar与packed atomic | 按宽度整体原子不能误覆盖逐元素packed/vector例外 | §12.3引向§13；128bit shared CAS能力未实现继续关闭 |
| mbarrier wait | conditional与acquire成功条件需明确 | §14.1：conditional用.parity，True观察才建立规定可见性，false时report未定义 |
| Fabric proxy | 不能把关系名称读成任意新fence语法 | §18：CFT=fabric、本地SMEM=async、barrier=generic；按已有方向/形式建立顺序 |
| Alias | 同节/历史名称不能都当独立硬件opcode | §3.3分别说明bar/barrier、membar/fence、wait_all和编译.alias |

三项独立技术记录均已实际复读冻结稿并确认上述项关闭。结论适用于所列文档审查范围，不是设备bitfit、全tuple合规、RTL/formal、面积/时序或吞吐验收。

## 第三轮：产物与交付

agent4负责七图、原生DOCX表格/公式、PDF、导航及排版核验；root独立复核源与产物hash、指令覆盖报告、链接及Git改动范围。首构建发现表内HTML br在Pandoc中丢失导致名称连写，构建器将其转成原生LineBreak；主文保留原始名称，避免为排版篡改指令语义。

最终页数、图表/公式数量、字体、全页文字边界、实际目检页和文件hash以[最终产物QA](document_qa.json)为准。自动文字边界检查和抽样目检不称为人工逐页校对。既有RTL与测试文件不在本轮修改范围内，未重复运行MALU数值回归。

本轮网页访问失败记录保留，引用历史已保存快照并登记来源日期；没有将失败请求写为成功网络检索。
