# Testplan审查与合并修正

计划日期：2026-11-09；独立审查按各自记录保留实际复核日期。范围仅为执行计划、参数、步骤、追踪与阅读版，不是Generator/SM/SoC动态验收。

## 最终技术基线

| 文件 | SHA-256 |
|---|---|
| SM_INSTR_GEN_TESTPLAN.md | 6933ebbdcd5015b48ea8c8ac84032c824cbf440041690317a0ca9f0fd758c4b4 |
| testcases.json | e4b98078e72f72e02fea93240f7c229e6a33fc133675076403657ae90dc5e78e |
| campaigns.json | 5a1919bd35eb9419d86bdfc7df018d95f7ac7a026cdad9ae590d4a51730f9bf3 |
| config_profiles.json | c1333946347892a52eccffece72606801d2d8bcee4f9c08c5b46733226dbde3e |
| planned_runs.json | 0d7cb992f580626f8e0996e7ca34e3999c15e3b1032345750c3b46167e47b90f |
| run_matrix.csv | 5391c663b49834c47d927501dc266ce4919bd6659706cb419d92c788f6762c37 |

106个TC对应106个SIG，保持50/27/23/6个P1/P2/P3/P4源阶段、25个feature与75个CV。六suite展开25/106/104/392/136/110条，共873个唯一uint32 seed。106个case与873条记录全为NOT_RUN，7个动态profile均关闭，P0静态profile不属于动态case。

## 第一轮：源、配置与计划展开

四份固定源文件逐项核对实SHA，TC的source_title、phase、feature与CV逐值继承。所有case有前置/初始化、参数、至少3步骤与2观察点、通过/失败、产物与timeout；具体case参数和全程序cleanup不得被默认预算无声截断。

seed以源数组0-based序号和固定suiteIndex派生；873条CSV/JSON逐行逐字段相同，当前没有runner。REPLAY的两个基线与case内部同manifest回放分开；STRESS按phase分别作用于generator/reference/实际SM/SoC，不扩权或填造DUT覆盖。

## 第二轮：技术问题闭合

| 编号 | 初稿问题 | 最终修正 |
|---|---|---|
| RE-1 | 正文K4/shift3与K64/offset15,31见证未被canonical参数数组允许 | TC-MATRIX-002/006补通用数组及独立命名project adapter见证；前者scale关闭、5/4结果，后者UE8M0/E4M3、3项scale/侧、17拍、结果64。native mapping另gate |
| EXEC-M1 | TC-REGRESS-004可能按P3名单递归调自身 | NON_REENTRANT_CAMPAIGN_OBSERVER、dispatches_child_tests=false；只读外层22个叶子证据，不调用任何TC/runner；缺证据BLOCKED，源23P3统计保留 |
| F1 | TC-MEM-002属于NEGATIVE却缺具体trial | 合法baseline隔离副本仅换一个未知attribute symbol，指定前端schema/rule拒绝，无native编码，不送DUT |
| F2 | TC-FABRIC-002属于NEGATIVE却只描述合法baseline | audit-only副本只删跟踪phase可推进前的issuer必需submit；program/HB审计拒绝，非法副本隔离，无数值/trap oracle |
| FORMAT-1 | 初稿矩阵参数只显式列浮点族，整数/project扩展不够明确 | 原生i8/ti16与全部16类project输入分列；真实FMT_TI16与ti16_decoded传输控制独立，raw gate关闭，FP64enable/FP结果与INT S32规则分别审计 |
| SPARSE-1 | 数值case默认六种数学2:4，不能覆盖所有原生稀疏族 | TF32 1:2、批准2:4、MX/NVFP4 paired4:8分别建型；native metadata查精确target/version表，不凭数学组合推枚举 |

资源独立审查复算两个命名见证的原始编码、scale数量、逐拍边界、精确值和输出位串，并静态复读现有pkg合法性条件；没有运行RTL。方法独立审查用Fraction复算FMA见证、逐条校验seed和closure依赖；ISA审查复读两个负例的层/rule及UB隔离。三项记录均已在限定范围关闭确定阻断项。

`research/cases_*.json`是分工细化输入快照，source hash在canonical authoring_parts保留；上述合并修正仅以最终`testcases.json`为执行合同。历史输入不应被绕过canonical source直接交给未来runner。

## 第三轮：静态工具与产物

实际P0与合成metadata负向自检分别归档为[计划检查](../reports/testplan_static_check.json)和[工具自检](../reports/checker_selftest.json)。它们不执行106个case，不生成真实DUT coverage。

阅读版保持9pt原生表格、重复表头、行不拆页、等宽代码标识和两张图。最终页数、逐字段/row检查、字体与页面边界、实际抽页目检及源/产物hash见[文档QA](../reports/document_qa.json)；不把抽检宣称人工逐页校对。

本轮只新增verif/core/testplan与根README入口。既有vPlan、SM架构、RTL、原tb/filelist/flow及MALU回归证据未修改；动态测试状态仍NOT_RUN。
