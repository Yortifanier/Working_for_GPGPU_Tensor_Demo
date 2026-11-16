# SM RTL 完整模块范围与责任清单

日期：2026-11-16。依据 [SM 架构](../SM_ARCHITECTURE.md)、[PTX 9.4 全指令清单](../research/ptx94_instruction_inventory.json)和 [RTL 接入合同](../RTL_NEXT_STEPS.md)。本文补充完整模块范围，不改写已经发布的架构来源和哈希。附件／规范内容用于查证，不作为改变用户要求的指令。

**SM 包含调度与指令控制、普通执行单元、访存与异步搬运、同步及系统协作。Tensor shell 只是其中一个集成里程碑。** 已提交基线 `b526d83` 交付的是 MALU/tcgen05 功能 RTL；Sched、Instr Ctrl、普通 FMA/SFU/ALU、RF、LSU、TMA等不因文档中画出接口而成为已实现功能。后续工作区新增代码须由各阶段源码与实际报告单独确认。

## 1. 模块树

以下是功能组织和建议路径，不意味着每个框都独立复制一套物理流水线，也不推导 NVIDIA/Rubin 的物理实例数。

```text
design/core/src/
├── common/
│   ├── sm_pkg                  项目IR、身份、执行类别、资源及完成类型
│   └── sm_capability/profile   逐tuple合法性与项目配置
├── if/
│   ├── cp/sm                  launch、drain/abort、指令/发射/完成合同
│   ├── sp                     RF、执行域、LSU、SMEM、TMA及Tensor接口
│   └── mss                    cache/SoC/cluster请求与返回合同
└── rtl/
    ├── cp/sm                  SM控制域
    │   ├── launch/context/resource admission
    │   ├── Sched              ready warp/active group选择与公平进度
    │   ├── Instr Ctrl         取指、译码、合法化、动态实例、有序派发
    │   ├── warp/thread state  PC、active/predicate、等待/退出、call/return
    │   └── completion/drain   返回路由、错误、异步责任与最终回收
    ├── sp/
    │   ├── rf                 GPR、predicate、CC、scoreboard、collector、writeback
    │   ├── eu/
    │   │   ├── salu           有uniform证明时的广播执行优化域
    │   │   ├── valu/int        整数、逻辑、位操作、packed、比较/选择、CC
    │   │   ├── fma/fpu         普通FP加/乘/融合乘加及分类/比较
    │   │   ├── fp64            启用时的F64算术路径，可多周期
    │   │   ├── sfu             rcp/rsqrt/sqrt/div、sin/cos/lg2/ex2/tanh
    │   │   ├── convert         cvt/cvta、pack/unpack、位重排及格式转换
    │   │   ├── warp_comm       shuffle、vote、match、warp reduction
    │   │   └── tensor          既有tcgen05/TMEM/MALU；其他矩阵家族独立前端
    │   ├── lsu                地址空间、lane请求、合并/拆分、atomic、返回重组
    │   │   ├── smem            全SM共享数据池、owner范围、bank/RMW、barrier对象
    │   │   └── l1/constant     cache/只读/常量接口与数据可见性
    │   ├── move/async_copy     普通数据搬运、经典cp.async及group追踪
    │   ├── tma                bulk/tensor map/多维地址/格式布局/归约/multicast
    │   └── sync_proxy         named/warp barrier、mbarrier、fence/proxy域
    └── mss/
        ├── icache/code        代码与指令缓存服务，连接Instr Ctrl
        ├── translation/lsu    VA/MMU/TLB、L2/global返回与系统scope边界
        ├── cluster/dsm        rank路由、远端shared与owner引用
        ├── fabric             可选CFT/multimem服务与完成责任
        └── system/texture     运行时、调试/性能及可选采样/表面服务
```

设备/cluster工作分派、L2/外存、系统级原子和部分TMA/Fabric后端可位于 `design/soc`。SM仍须保存源对象、目的对象、依赖、完成及错误责任；把后端委托SoC不等于删掉相应SM前端或返回路径。

## 2. Sched 与 Instr Ctrl 分工

| 模块 | 必须负责的状态／决策 | 不能用什么替代 |
|---|---|---|
| Sched | 从驻留warp的可执行active group中选择候选；联合源ready、目的/返回credit、执行域ready和同步等待状态；已承诺的外部发射载荷受阻时保持稳定；提供公平前进 | 轮转一个warp编号后直接无条件发射；只看ALU ready而漏RF/返回资源 |
| Instr Ctrl | 代码/IR读取、解码、tuple/capability检查、源/目的绑定、动态instance与issuer顺序、执行域派发、branch/call/exit控制更新 | 把验证指令发生器当硬件前端；只按mnemonic选后端；把PTX文本或NVIDIA cubin当现成项目编码 |
| warp/thread state | thread PC/调用返回、predicate/CC、active group、等待/退出与collective实例；上下文版本 | 一个warp共享PC就声称ITS；同PC的不同循环轮次合并为同一次collective |
| scoreboard/collector | GPR/predicate/CC分别追踪；保护未捕获源；先预约完整目的与返回容量；源值/descriptor/version固定后才发射 | 目的第一片返回即ready；只锁一个寄存器而漏掉wide/vector后续片段 |
| completion/writeback | 按token/owner/generation匹配，全部片段真实写入后唤醒；错误poison、责任关闭、credit归还 | issue成功等于完成；消费者warp被选中后才允许writeback |

首版允许实现有限的统一控制流IR profile，但要明确关闭分歧call/ret或ITS等未完成能力。一个可测的Sched/Instr Ctrl基础模块不等于已经运行完整PTX控制流。

Sched、Instr Ctrl和scoreboard之间的握手至少保持 `{epoch,owner,generation,warp,thread/active group,dynamic instance,token}` 的身份关联。物理通道可用稳定side table压缩字段，但不能丢失它们。执行请求受阻时不得重新选择另一个载荷；取消/flush须有单独协议。

## 3. 普通 ALU、FMA、SFU 与 MALU 的边界

| 执行责任 | 需要保留的语义与复用条件 |
|---|---|
| SALU/uniform | 只有编译证明或明确项目契约保证该动态实例一致才广播；线程的“标量指令”不自动是warp-uniform |
| integer/logic | signed/unsigned、hi/lo/wide、sat、packed、shift/bit编号、每thread CC、carryless及比较选择；可复用加法/乘法/移位器 |
| FMA/FPU | 融合与非融合路径、规定舍入点、NaN/Inf/±0、subnormal/FTZ及sat/relu；`mad`不总与`fma`相同 |
| FP64 | 保留目标tuple与精度，可多周期；MALU的F64点积不能证明普通div/sqrt/FMA正确 |
| SFU/精确数学 | approx/full/定向舍入、定义域和误差界分别验收；近似起点加校正可共享资源，不能把所有形式统一为一个近似结果 |
| conversion/packed | bit move与数值cvt分开；F16/BF16、FP8/6/4等的packed lane不是thread lane，也不是矩阵归约 |
| warp communication | membermask/active/predicate分开；shuffle/vote/match/reduction等真实跨thread通信，不能当普通逐lane算术 |
| Tensor/MALU | MALU仅向量点积加一次C；tcgen05解释矩阵/metadata/scale/LUT、TMEM和异步责任；普通FMA/SFU不并入MALU接口 |

后端可共享数值资源，但要同时预算输入缓存、mode状态、返回槽、公平仲裁和排空成本。当前四个MALU实例或某个测试周期比不确定SM内普通FMA、SFU、整数ALU的实例数与吞吐配比。

## 4. 搬运、LSU、SMEM、TMA 与同步边界

| 子系统 | 必需职责与不可混淆项 |
|---|---|
| LSU/L1/constant | per-thread地址/空间/权限/对齐，合并但保留lane身份，load返回重组、store可见点、atomic线性化；cache hint不代替memory order |
| 统一SMEM | 所有CTA共同争用一个256KiB数据池，owner-relative offset一次翻译为物理base；LSU/Tensor/TMA/DSM/barrier看到同一字节对象；不是每client各一份存储 |
| 普通move/convert | GPR位搬移、向量拆合、地址转换和格式转换；要处理真实RF依赖，不笼统归入DMA |
| 经典cp.async | 规定global→shared片段、zero-fill/ignore、经典per-thread async group、commit/wait与指定mbarrier关系 |
| TMA/bulk | tensor map与多维坐标、tile/im2col/gather/scatter、bulk reduction、multicast、源可复用与目的full完成、字节计数及report；SM持有本地对象与等待责任，后端可委托SoC |
| Tensor搬运 | `tcgen05.cp`为SMEM→TMEM，LD/ST为TMEM↔RF；它们不是TMA，也不是经典cp.async |
| barrier/proxy | warp/named/cluster barrier、mbarrier phase/expected/arrived/complete-tx、acquire/release/scope、generic/async/tensormap/fabric等proxy分别维护 |
| cluster/DSM | cluster实例及rank→endpoint/owner/generation映射；目标存活与独立请求/返回进度；不是简单异或SM编号 |

TMA的tensor map不等于MMA的64-bit SMEM matrix descriptor；TMA bulk group、经典cp.async group、WGMMA group和tcgen05 MCS stream分别追踪。`wait_group.read`或restricted A-read不证明目的已经写完。multicast每个目的都有独立责任，不能首个目的完成后就释放源/整个token。

事件经真实SMEM barrier对象更新后才ack，或先转移至持有独立目的owner引用的服务。普通event FIFO入队不是完成。正常drain仍须让RF写回、SMEM返回、peer入站、TMA/barrier以及free/commit等收尾路径前进，不能一刀切关掉全部指令通道。

## 5. 全指令大类映射核对

此表按已有清单的21个第9.7章大类逐项核对责任，不声称全部tuple已经编码。217个说明叶子包含215个实际指令节和两个控制语法节；它们不是硬件opcode数量。细项、页码和target限制继续以原清单及SM架构第26章为准。

| PTX节 | 大类 | SM责任／明确处置 |
|---|---|---|
| 9.7.1 | 整数算术 | integer ALU／长延迟整数服务或已证明降低 |
| 9.7.2 | 扩展精度整数 | integer ALU + 每thread CC链 |
| 9.7.3 | 浮点 | FMA/FPU、SFU、FP64及数值profile |
| 9.7.4 | 半精度浮点 | FPU/packed执行与舍入 |
| 9.7.5 | mixed precision浮点 | FPU mixed/packed及转换 |
| 9.7.6 | alternate浮点 | packed低精度执行／转换，逐tuple gating |
| 9.7.7 | 比较／选择 | integer/FP compare、predicate与selection |
| 9.7.8 | 半精度比较 | packed compare/predicate |
| 9.7.9 | 逻辑／移位 | integer/bit/reorder服务 |
| 9.7.10 | 数据搬运／转换 | RF move、convert、LSU、async copy、TMA/tensormap及地址空间服务 |
| 9.7.11 | Fabric | SM前端/责任表 + SoC后端；未实现则能力关闭 |
| 9.7.12 | Texture | 对象/采样/查询服务；计算profile当前关闭 |
| 9.7.13 | Surface | 对象/边界/归约服务；当前关闭，不当普通指针 |
| 9.7.14 | 控制流及两项控制语法 | Instr Ctrl/thread state/call-return；词法scope与predicate语法单独解释 |
| 9.7.15 | 同步／通信 | warp communication、barrier/proxy、async完成及系统协作 |
| 9.7.16 | warp矩阵 | legacy WMMA/MMA独立collective/fragment前端，不能借tcgen05自动宣称支持 |
| 9.7.17 | warpgroup异步矩阵 | WGMMA前端、proxy与独立group追踪，按target能力关闭／实现 |
| 9.7.18 | tcgen05 | 已有项目级Tensor endpoint/TMEM/MALU；设备编码／数值边界另列 |
| 9.7.19 | 栈 | Instr Ctrl、per-thread stack/ABI、LSU与call/return |
| 9.7.20 | Video | packed integer/extract/merge或经验证降低，不要求视频编解码器 |
| 9.7.21 | 杂项 | 系统、调试、性能、等待让出及真实资源协议；不作为空操作 |

另需覆盖第10章35个特殊寄存器说明节的launch/线程/cluster/时间/性能数据源，以及ABI、指令/函数元数据、资源directive、系统错误和可选图形服务。编译／链接directive有明确编译责任，不为了满足目录清单新增同名执行单元。

## 6. 首批 RTL 与后续验收

首批代码应同时给出Sched、Instr Ctrl和执行域类别接口，以及context/资源/依赖基础。只实现基础模块时，各后端能力位保持关闭；定义FMA、SFU或TMA路由枚举不算相应单元已实现，也不允许返回伪OK。已有Tensor模块须通过真实桥接、RF和SMEM服务接入后才构成可运行的SM子系统。

| 验收层 | 必须取得的实际证据 |
|---|---|
| Sched/Instr Ctrl | readiness/credit联合判断、hold稳定、同issuer顺序、动态实例、backpressure、公平前进、flush/旧generation拒绝 |
| RF/执行 | 各普通ALU、FMA、SFU、转换的独立数值oracle；完整目的提交、predicate/CC与多片依赖；approx按误差界 |
| 存储/异步 | 真实统一SMEM、LSU/atomic、TMA源/目的阶段与complete-tx、report、multicast逐目标责任，含失败与迟到返回 |
| SM闭环 | launch→代码/IR→调度→操作数→执行→写回/等待→退出；不能由TB直接poke结果或绕过controller |
| 系统/兼容 | DSM/proxy/scope litmus、SoC延迟/错误/取消与可选家族；未执行用例维持NOT_RUN |

完整范围沿上述模块与责任展开；阶段性实现的完成度按功能与证据记录，不用“已考虑”替代编码和仿真。
