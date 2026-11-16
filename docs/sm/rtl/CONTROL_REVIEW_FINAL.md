# SM Sched / Instr Ctrl 最终只读审查

日期：2026-11-16。范围：当前 `sm_pkg.sv`、`sm_ctrl_if.sv`、`sm_instr_ctrl.sv`，并读取 scheduler/scoreboard 的接口与状态推进。仅新增本文，没有修改RTL、TB或runner。本次是独立源审；动态结果须引用主agent最终生成、与源码hash匹配的报告。

当前profile为显式 **UNIFORM_CONTROL**。15个执行域标识是路由接口，不表示已经新增FMA、SFU、TMA等后端；集成测试中的后端BFM不算其硬件实现。错误发生前已接纳的操作允许drain，不承诺精确异常或副作用回滚。

## 1. 发现项与当前处置

### C1：FAULT warp最后一次错误retire与detach同拍

检查初稿存在可达反例：warp已因一个错误处于FAULT，先前接纳的另一flight随后也以错误完成。scoreboard清live并注册retire脉冲后，下一周期 `warp_busy=0`，detach可返回OK；同一clock边沿先把warp置FREE，末尾retire错误处理却又按旧owner/generation把它改回FAULT，导致成功detach没有释放slot。

当前源码已修：retire错误更新要求warp不是FREE，并排除同拍成功的该warp DETACH。这样旧retire不覆盖本次成功生命周期操作。主agent已要求集成TB加入“已FAULT + 最后一笔error + 同拍detach”的定向回归；最终动态关闭以该回归报告为准。

### C2：fetch / warp lifecycle入口缺少epoch

检查初稿的decoded-fetch和warp命令只带owner/generation/warp。reset会清owner历史，允许新epoch重新使用owner/gen1/相同PC；旧epoch迟到的相同字段fetch无法区分，可能被赋予新epoch token后执行。仅在执行完成token中包含epoch不足以关闭此前入口。

当前 `sm_pkg` 已在fetch、warp命令及各自响应增加32-bit epoch。Instr Ctrl先检查请求epoch等于 `reset_epoch`，不匹配返回BAD_CONTEXT；响应echo请求epoch，便于上游准确识别被拒的旧请求。主agent已安排旧epoch入口负例，动态结果仍以最终报告为准。

以上两项均为具体身份／生命周期问题；当前已读源码包含修正，本文不将已修反例继续描述为现存RTL缺陷。

## 2. 已核对的主要不变量

| 检查点 | 代码对应与结论 |
|---|---|
| owner/generation | 同owner仍有warp存活时只接纳同一generation；全部warp释放后要求新generation严格增加，65535不回绕。owner_active包含EXITED/FAULT，不能把尚未detach的资源当作空闲。 |
| 入口与PC | fetch核owner/generation/epoch、RUN状态、expected PC和4-byte对齐；每warp仅一个待选指令。PC在实际take后推进，branch/exit按各自规则处理。 |
| active mask | 普通执行mask须为驻留active集合的子集；BRA/WAIT/EXIT要求整个active集合。该profile不宣称已实现per-thread分歧PC或ITS。 |
| 序号 | 全局ticket在实际执行reserve/take时增加；动态instance也包含非执行类控制操作。两者接近上限时明确拒绝／FAULT，不静默回绕。 |
| credit先取得 | 非零mask执行须同时通过scoreboard probe、dispatch槽空间和reserve_ready；实际take后建立稳定queued packet。不能只因被scheduler选中就算后端已接收。 |
| ready/valid | 对外dispatch寄存器在反压时保持；warp/fetch响应为独立注册槽；complete/source服务不依赖warp再次被scheduler选择。 |
| 生命周期 | EXIT/BRA/WAIT在该warp无未完成flight后执行；detach仅允许EXITED/FAULT且flight为空。retire错误与同拍detach仲裁已按C1修正。 |
| 错误 | 失败retire清后续buffer并将warp置FAULT；已reserve/queued的其他操作仍可drain。此策略不能包装成精确异常。 |

没有从这些静态不变量推导全PTX执行、无条件系统死锁自由、数值正确性或物理吞吐结论。

## 3. 保留的集成前提

1. `reset_epoch`和capabilities在非reset运行期间稳定，reset与上游代码源、后端、RF/存储服务协调。过滤迟到包不撤销外部已提交的写入。
2. 单个共享dispatch槽会产生跨执行域head-of-line阻塞；当前受限profile依赖后端在既定公平假设下最终接收。完整SM不能让一个待接收请求必须依赖被该槽挡住的后续issue才能前进，应继续按执行域信用／队列与服务合同细化。这是结构与后端合同边界，不是本次已运行的死锁反例。
3. fetch的OK表示指令缓冲接纳，不表示已经执行。上游按 `next_pc`、fetch响应及缓冲背压协议供给，不自行将同PC旧请求视为下一动态指令。
4. `function_id`的具体操作与类型/修饰tuple仍由后端／未来lowering定义；当前capability只表示执行域入口开放，不证明该域所有指令都实现。
5. `writes_committed`只在真实目的片段写入后可置位；source释放只在原值已捕获／不再重读后发送。RF、collector和各实际后端尚未完成时，BFM对这些信号的驱动只验证控制协议。

独立审查未在当前已读范围发现其他确定的PC、mask或握手阻断项；这个结论不代替正式回归和后续真实后端接入验证。

## 4. 主agent动态关闭补记

冻结源码的[最终回归报告](checks/results_all.json)已实际完成12次正常仿真及3次独立预期断言违例。Instr Ctrl在4/4两seed、64/16和1/1下分别通过647、640、763、488项检查。集成TB的多flight场景直接构造C1所述错误retire与detach同拍，检查成功后slot仍为FREE；C2包含旧epoch warp命令和fetch的拒绝及响应身份检查。两项发现已在上述定向范围关闭。报告的源码和运行日志hash已校验后归档；本补记不扩大为ITS、完整SM或真实后端的验证结论。
