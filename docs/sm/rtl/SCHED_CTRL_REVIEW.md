# Sched / Instr Ctrl 首版 RTL 合同审查

日期：2026-11-16。依据既有 [SM 架构](../SM_ARCHITECTURE.md) §4–7、§16、§22 和 [接入准备](../RTL_NEXT_STEPS.md)。本文是编码前合同与用例建议，只读核查，不代表调度器、执行后端或 SM 已通过仿真。未修改既有架构、RTL、TB 或 filelist。

## 1. 范围与架构要求

SM 主干应为 **指令前端 → Instr Ctrl/依赖管理 → Sched/dispatch → 执行域 → 实际写回/事件服务**，而不是在 Tensor endpoint 外仅加 launch wrapper。

后端至少分别标识 SALU、VALU/整数、FMA、SFU、转换/重排、LSU、数据搬运、TMA、Tensor，以及本地控制/同步服务。逻辑分类不要求每类独占乘法器或物理 issue port；资源复用必须保留其数值、源快照、返回和状态合同。一个已译出的 class 或空的 ready/valid 接口不等于该后端已实现。

架构 §5 要求 ITS 语义以及每线程 PC、predicate、CC、等待和退出状态。如果首轮仅实现每 warp 一个 PC、统一控制流、单 warp active group，应明确为 **UNIFORM_CONTROL_PROFILE，ITS 关闭**；不能以能调度多个 warp 宣称已实现 ITS。即使关闭 ITS，predicated-off lane 仍不得产生 RF、store、atomic 或异步事件副作用。

SALU 只能在编译证明或项目入口明确保证数据 uniform 时广播。控制流 `.uni` 不证明任意 ALU 输入 uniform，逻辑上的 scalar PTX 指令也不能直接解释成一次 warp 广播。

## 2. 各模块承担的具体责任

| 模块 | 输入、状态与动作 | 不能代替的功能 |
|---|---|---|
| 前端/fetch adapter | 项目 IR、PC/version、owner/generation/epoch、warp、动态指令序号；迟到 fetch 按身份过滤 | 不解析 PTX 文本，不声明 NVIDIA cubin 译码 |
| Instr Ctrl | 检查 opcode/class/capability、active/predicate mask、源/目的完整范围、控制流和动态实例；建立稳定 instruction record | 不用 backend ready 代替合法化；不将 decode 成功称为执行成功 |
| scoreboard | GPR、predicate、CC 的 RAW/WAW；未捕获源的 WAR；完整向量及跨 word 对象；producer token 和 poison | busy bit 不是值存储，也不替代 RF/RF 写回 |
| Sched | 从真正 eligible 的 warp/active group 中公平选择；受阻 payload 锁定，接受后只发一次 | 不以 scheduler 选择作为 consumer/wait 完成的条件 |
| operand collector | 源值捕获或源保护；宽 descriptor 两半同版本，完整 ST/向量 source 责任 | 不能只捕获第一片便释放整体源保护 |
| dispatch/route | 按实际执行域 capability、请求信用及返回信用派发；保留动态身份和完成域 | 类别枚举不能冒充实际 FMA/SFU/TMA 功能 |
| writeback/return | 匹配 producer 身份，所有片段真实写入后发布 ready；独立处理错误/取消 | backend request ack、第一片结果或 commit 登记 ack 不是完整结果 |
| CTA lifecycle | thread-exit、普通指令、Tensor/TMA/peer/barrier 等分别 drain，再回收 owner | 最后一个 thread exit 不能直接释放 SMEM/RF/warp |

## 3. 首版可执行握手合同

1. **身份**：每条动态操作通过稳定记录定位 `{reset_epoch, owner, generation, warp, instruction_instance, operation_token}`。若总线不铺全部字段，必须保留不可提前回收的 side table。静态 PC 不作为 collective 或返回身份。
2. **原子 issue**：接受前同时保证源已捕获或受保护、所有目的已预约、执行域有接收空间、返回/写回责任有信用。缺少任一项不得只改变部分 scoreboard 或 PC。
3. **顺序点**：PC/动态序号在正式 issue 或明确的本地控制完成点推进一次。前端入 FIFO、valid 尝试和 backend ready 单独出现均不能重复推进。分支解决前的旧 fetch response 需按版本过滤。
4. **稳定性**：valid 受阻时，指令、backend class、owner/token、mask、目的及已捕获源值全部稳定。RR 选择不能每拍重选 held request。若采用每域 staging，分别保持请求；不得把被 SFU 阻塞的全局槽解释成 SFU 已执行。
5. **依赖粒度**：首版可保守地对整个 warp 的 GPR/predicate/CC 加锁，但值仍按线程保存、写入仍按有效 lane mask。wide/vector 的全部 word、descriptor 和 implicit CC 都进入依赖检查。
6. **解除依赖**：仅匹配 producer 的完整 RF 提交可清 busy。乱序或旧 generation 的 response、重复 response、失败的最后一片都不能清除新 producer 的依赖。错误目的维持 poison/未就绪，并走错误关闭协议。
7. **同拍事件**：旧 producer 完成与新 producer 预约同一目的时，应明确旁路/优先级；即使允许同拍重用，新 producer 的 busy/token 必须保留，不能被旧 completion 的清位覆盖。
8. **能力关闭**：未实现 backend/tuple 在发射前返回明确诊断且无副作用。不能因永远为0的 ready 而永久等待一个根本不存在的执行器，更不能虚构 success response。
9. **控制与通信**：membermask、active mask、predicate mask、Tensor D-disable mask 独立；collective 以动态实例汇合，不能把不同循环的同 PC 到达合并。首版未实现的分歧/ITS/collective 形式应关闭能力。
10. **有限序号**：token/generation/PC-version 有明确耗尽策略；未证明安全复用时禁止回绕。reset 必须同时协调外部事务，过滤旧包不等于撤销旧写入。

若初版采用“每 warp 仅一条 in-flight 指令”，这是可执行的保守项目实现，可以先验证跨 warp 调度；它限制 warp 内并发，不构成完整 ITS、乱序 SM 或峰值吞吐实现。后续扩大窗口时仍须保持上述 token、源保护和全片写回规则。

## 4. 发射与完成必须分别建模

| 类别 | 正式完成责任 | 不足以完成的事件 |
|---|---|---|
| FMA/SFU/整数/转换/普通 load | 规定 GPR/predicate/CC 的完整有效线程结果已提交 | 请求握手、固定猜测延时、首个 word 返回 |
| store/atomic | 指定可见点/线性化与响应条件 | source collector 已捕获数据 |
| Tensor | tcgen05 LD/ST、MCS full、SMEM-A read、commit 各自推进 | TC_COMMIT 的 registration rsp |
| TMA/async copy | 各协议的 source/read、destination/transaction、barrier/bulk-group 完成域 | 发射或 commit_group 接受；`wait_group.read` 不能当目的完成 |
| wait/barrier/peer | 规定目标或成员责任实际关闭，身份匹配后唤醒 | warp 被 scheduler 再次选中；普通 response 入队 |
| CTA exit | thread、存储、异步和远端责任均关闭后释放资源 | warp 仅执行到 EXIT |

完成通路不能依赖普通 issue queue 有空位。RF 写回、barrier update、peer service、wait/free/commit、退出 drain 必须有独立的可前进路径；消费者 warp 正在等待时仍应接收其 producer 写回。停止新 launch 不等于停止现存 CTA 完成协议所需指令。

## 5. 最小故障触发用例

以下是待实现测试建议，全部 **NOT_RUN**；不是既有 SM 指令发生器106项 testplan的执行结果。

| 用例 | 具体触发与检查 |
|---|---|
| RR 前进 | 至少3个 warp 持续 eligible，在公平 backend 假设下各自被服务；只在真实 issue ack 增加各自次数 |
| backend 隔离 | SFU ready长期拉低，其他可执行域仍有合法前进策略；held SFU 请求不改身份/数据，也不计执行完成 |
| held issue | 请求第一拍被阻塞，随后更高优先 warp 到达；原 payload保持且最终只被接受一次 |
| RAW/WAW/WAR | 长延迟 producer 后接读/写同寄存器；未捕获完的wide/vector source禁止被覆盖；无关寄存器/warp可前进 |
| 同拍完成/预约 | completion清旧目的同时issue新producer写同目的，下一拍busy和token应属于新producer |
| 乱序/重复/旧包 | 两条不同延时返回乱序；重复与旧generation/epoch包不得二次写RF、清新依赖或错误唤醒 |
| 全片写回 | 64/128-bit和DATA/META/RED向量仅返回第一片后 consumer仍阻塞；最后真实RF ack后才ready |
| predicate/CC | 两lane guard不同；predicated-off lane无副作用，carry链按thread保持；predicate/CC依赖与GPR分别检查 |
| uniform约束 | 数据不同的lane不能走未经证明的SALU广播；`.uni`分支标记不自动打开数据uniform |
| PC/instance | 后端回压和branch等待中PC不重复推进；同PC两个循环实例不混collective，旧fetch不覆盖新PC |
| 资源关闭 | 普通队列满时writeback/event/free仍可被服务；退出仍有TMA/Tensor/peer引用时禁止回收owner |
| 未实现能力 | 请求缺失backend或ITS形式得到明确诊断，不发memory/RF/event副作用、不无期限挂起 |

## 6. 可对外报告的边界

调度模块、Instr Ctrl、scoreboard 和后端执行能力分别报告实现/验证状态。若本轮只是 dispatch 和依赖控制通过，准确称“SM控制基础层”，不能称“完整SM可运行”。后续真实 FMA/SFU/LSU/TMA 单元各需数值、内存/事件及错误恢复证据；归入一个 backend enum 不增加已实现功能数量。
