# MALU RTL 第一轮规格核验与第三轮独立审查记录

日期：2026-10-25。负责：agent1。范围：Matrix ALU / vector dot，只核验与审查，不修改仓库或核心 RTL。

## 结论及当前状态

第一轮规格核验已完成。Ti16 raw bits 的完整权威编码仍未闭合，应拒绝该模式；可提供**独立枚举、明确标为项目协议的 decoded integer 模式**，其数学取值限制为 [-2047,2047]。FP4/FP6、UE4M3/UE5M3 的 bias、subnormal 和特殊值现已用 NVIDIA 官方 CUTLASS 实现补足。第三轮 RTL 独立审查等待实现文件与验证结果，不能提前写成通过。

共享参数化无符号有效数乘法器（FP64-on为53×53，off为24×24）和 32-bit limb 分段精确累加存储可作为低面积项目实现；`PROJECT_EXACT` 表示本项目确定性数学/舍入契约，**不表示 NVIDIA Rubin 的内部位宽、流水线、逐 bit 结果或吞吐复刻**。

## 1. 新核验来源

### 1.1 用户上传 PTX ISA 9.4

- 路径：`/workspace/attachments/4971c15f-29fd-4875-95d3-ed0c693d3482/ptx_isa_9.4.pdf`。
- §9.7.18.4.2，表53及后文，PDF物理页724–725 / 印刷页712–713：`.kind::ti16`，A/B为`.s1z4m11`，16-bit signed integer，range `[-2^11+1,2^11−1]`，D=S32；atype/btype的descriptor编码为3。
- 本文及现有论文、两专利研究记录未提供 `.s1z4m11` 负数/零的完整逐 bit 解码方程。
- 本轮也实际HTTP200读取了 [NVIDIA当前PTX网页](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html)，保存为 `research/format_sources/ptx_current.html`；全文仅3处S1Z4M11相关命中（shape表、descriptor类型编码、范围描述），未新增完整raw位编码依据。网页的表编号不能替代上传PDF的固定页码引用。
- §5.2.3，PDF物理页54–55 / 印刷页42–43：FP4/FP6无Inf/NaN；UE4M3为7-bit unsigned、NaN=0x7f、容器bit7填0；UE5M3为8-bit unsigned、NaN=0xff；两者均无Inf。

### 1.2 NVIDIA CUTLASS 官方公开代码

通过只读 `git ls-remote` 核验的 main commit：

`91843b71d90737e0a9b86f7d9df213cff5a3526f`

以下固定commit URL均已实际HTTP200读取；本地证据保存在 `research/format_sources/`，SHA256/URL见该目录 `source_manifest.json`。

- [float_subbyte.h](https://github.com/NVIDIA/cutlass/blob/91843b71d90737e0a9b86f7d9df213cff5a3526f/include/cutlass/float_subbyte.h)：E2M1约75–85行；E2M3约156–166行；E3M2约263–273行。
- [float8.h](https://github.com/NVIDIA/cutlass/blob/91843b71d90737e0a9b86f7d9df213cff5a3526f/include/cutlass/float8.h)：UE4M3约1078–1086行；UE5M3约1155–1163行。
- [exmy_base.h](https://github.com/NVIDIA/cutlass/blob/91843b71d90737e0a9b86f7d9df213cff5a3526f/include/cutlass/exmy_base.h)：约94–102行的bias计算；约400–514行的位域、NaN/Inf/denormal规则；约870–888及917–939行的类型模板实例化。

CUDA Math API 的官方 FP4/FP6 类型页也已HTTP200访问，交叉确认sign/exponent/explicit mantissa位数以及无Inf/NaN：

- https://docs.nvidia.com/cuda/cuda-math-api/cuda_math_api/struct____nv__fp4__e2m1.html
- https://docs.nvidia.com/cuda/cuda-math-api/cuda_math_api/struct____nv__fp6__e2m3.html
- https://docs.nvidia.com/cuda/cuda-math-api/cuda_math_api/struct____nv__fp6__e3m2.html

**来源自检**：CUTLASS `float_subbyte.h` 的 E2M1 range 注释意外多列了5。实际encoding selector为4-bit、E2/M1、NanInfEncoding::NONE，且bias=1，所以正数只有 `0,0.5,1,1.5,2,3,4,6`。RTL与测试必须按编码/解码公式校验，不能盲目照搬这一行注释。

## 2. 已闭合的格式定义与数值

令 E为原始指数域整数，F为原始尾数域整数，M为尾数位数，B为bias。除特殊编码外：

- E=0：`x = sign × F × 2^(1−B−M)`，F=0为零。
- E>0：`x = sign × (2^M+F) × 2^(E−B−M)`。
- unsigned scale没有sign；UE4M3容器bit7必须为0，不能把它当作符号位，也不能静默忽略非法padding。

| 格式 | 数值位域 | bias | 最小normal | 最小正subnormal | 最大有限值 | 特殊值 |
|---|---|---:|---:|---:|---:|---|
| E2M1 | S1/E2/M1，共4bit | 1 | 1 | 1/2 | ±6 | 无Inf，无NaN；有±0 |
| E2M3 | S1/E2/M3，共6bit | 1 | 1 | 1/8 | ±7.5 | 无Inf，无NaN；有±0 |
| E3M2 | S1/E3/M2，共6bit | 3 | 1/4 | 1/16 | ±28 | 无Inf，无NaN；有±0 |
| UE4M3 | E4/M3，共7bit，8-bit容器bit7=0 | 7 | 2^-6 | 2^-9 | 448（raw0x7e） | 仅raw0x7f为NaN，无Inf，有+0 |
| UE5M3 | E5/M3，共8bit | 15 | 2^-14 | 2^-17 | 114688（raw0xfe） | 仅raw0xff为NaN，无Inf，有+0 |

FP4/FP6不能把all-ones exponent作为IEEE Inf/NaN；例如 E2M1 raw0x7=+6，E2M3 raw0x1f=+7.5，E3M2 raw0x1f=+28。UE4M3 raw0x78=256、UE5M3 raw0xf8=65536，均是有限数，不能一看exponent全1就判Inf。

E2M1正半区raw0..7的完整映射：

| raw | 0x0 | 0x1 | 0x2 | 0x3 | 0x4 | 0x5 | 0x6 | 0x7 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 数值 | +0 | 0.5 | 1 | 1.5 | 2 | 3 | 4 | 6 |

raw8..15按sign位对应负数和−0。这里的raw只指单元素紧凑数值编码；matrix共享内存/TMEM padding、packing仍需专门适配，不能由本表推断传输stride。

## 3. Ti16 raw与decoded模式的接口约束

- 原生/原始模式应使用明确名称，例如 `FMT_TI16_RAW_UNVERIFIED`，在无权威编码依据时直接返回unsupported/illegal，不执行dot，不把payload猜成s16或sign-magnitude。
- 可执行的项目模式应另用枚举，例如 `FMT_TI16_DECODED_PROJECT`：payload约定为已经解码的数学整数，可选择16-bit二补码承载，但必须明确“二补码是本项目传输协议，非已证明的PTX raw编码”。
- 每个输入元素检查 `−2047 ≤ value ≤ 2047`；−2048、2048、s16边界均非法。不能通过截位/饱和把非法payload悄悄变合法。
- 在PROJECT_EXACT下使用精确整数乘积/归约，C为正式输入；最终S32输出的wrap/saturate/reject必须由项目契约明示。原生Ti16表53的saturation bit是NA，不能默认继承其他mma的satfinite字段。
- Ti16若使用S32 C，`2047²=4,190,209`；K16纯dot最大67,043,344、K32纯dot最大134,086,688，但与任意S32 C相加仍可能溢出。

## 4. 共享资源与PROJECT_EXACT数值契约的审查准则

### 4.1 参数化共享乘法核

- FP64有效数最大53bit，单个A×B生成106bit精确乘积；符号与指数独立处理。
- scale UE4M3/UE5M3有4bit有效数，**不能仅加指数而丢掉scale mantissa**。可复用同一核串行完成scale乘积，或用移位加法精确扩展；保持精确中间乘积，不提前舍入为FP32/FP64。
- 分阶段更新时寄存器必须携带A/B格式、scale格式、block索引、sign、exponent、C/D格式与tag；不能读到下一请求的动态配置。
- 不把原生格式的输入packing、sign扩展与共享乘法核有效数抽取混淆。signed整数绝对值/符号处理应覆盖最负值，而非用溢出的同宽abs。

### 4.2 32-bit limb精确累加

- limb宽度32bit不是总精度；必须用最低可表示乘积指数、最大指数、dot长度与C范围证明总覆盖宽度。
- 每步正确传播carry/borrow；写回分块时不能丢失跨limb进位。加负项可用明确符号幅值或足够宽二补码，两者不可混用。
- PROJECT_EXACT应精确保存所有有限项和C，只在最终D转换时按项目舍入规则舍入；分block先舍入再相加不等于精确总和。
- 若允许FP64与额外microscale的项目扩展，应重新计算最低指数/最高指数覆盖范围；不能用“原生FP64不带scale”的宽度预算宣称覆盖完整独立字段交叉积。

### 4.3 必须写清的项目选择

最终舍入模式、FP64/FP32/FP16输出转换、signed-zero策略、NaN canonical编码、Inf×0/异号Inf混合、subnormal保留或FTZ、overflow结果、整数溢出策略、非法tuple拒绝语义。所有这些以PROJECT_EXACT命名，避免暗示Rubin位级模型。

## 5. 独立测试建议

1. 对E2M1的16种、E2M3/E3M2各64种raw值做枚举解码对照；对UE4M3的128种合法值与UE5M3的256种值分类检查，另测UE4M3bit7非法padding。oracle用独立Fraction/整数公式，避免直接调用RTL同构decoder。
2. 含C的精确边界：取消抵消、跨limb carry/borrow、round half-even两侧、subnormal最小值、正常/次正规边界、最终overflow。
3. block16/32切换及每block不同A/B scale，特别scale mantissa≠0，避免只测UE8M0掩盖scale乘法错误。
4. raw Ti16拒绝与decoded模式端点−2047/0/+2047，越界−2048/+2048拒绝；非法请求不产生部分数值副作用。
5. 输入accept/输出complete分开；backpressure下response payload稳定，tag和配置不可串单，reset清除未完成请求。

## 6. 三轮检查状态

| 轮次 | 责任与状态 | 证据 |
|---|---|---|
| 第1轮：规格 | agent1已完成编码/范围/模式分界核验 | 本记录、固定commit源码及PTX双页码 |
| 第2轮：实现/测试 | 主agent组织完成；agent1已独立复核真实主回归日志与稳定源码指纹 | 三轮共10,861个数值/配置向量及55项协议检查 |
| 第3轮：独立审查 | agent1已完成decoder独立仿真、核心数值路径静态审查及三轮证据总评 | 66,999项decoder另列；最终结论见第8节 |

## 7. 第三轮独立审查：decoder实际仿真与数值路径首审

工具为本机实际引导的 **Verilator 5.032（Debian 5.032-1+b2）**。本agent只在 `/workspace/output/malu/review3/` 写独立TB/oracle/日志，未修改DUT或主验证环境。

### 7.1 Decoder：66,999 cases，0 mismatch

编译真实 `malu_pkg.sv` + `malu_decode.sv`，SV TB输出解码分类、sign、sig、exp及needs_abs；独立Python `Fraction` oracle对照精确数学值与合法性。

| 覆盖项 | 实际数量 |
|---|---:|
| E4M3 / E5M2全编码 | 256 + 256 |
| E2M3 / E3M2全编码 | 64 + 64 |
| E2M1全编码 | 16 |
| UE8M0 / UE4M3 / UE5M3全byte，包括UE4非法bit7 | 256 + 256 + 256 |
| Ti16 decoded全部16-bit carrier + raw模式拒绝 | 65,536 + 3 |
| TF32项目传输协议边界/非canonical低13bit | 12 |
| F16 / BF16 / F32 / F64的zero-adjacent、normal、最大值、Inf/NaN边界 | 各6，共24 |
| **总计** | **66,999** |

证据：

- `review3/tb_decode_review.sv`：独立SV枚举器。
- `review3/decode_build.log`：真实编译日志。
- `review3/decode_results.log`：真实DUT输出。
- `review3/check_decode.py`：独立有理数oracle。
- `review3/decode_review_result.json`：工具版本、分项数量、0 mismatch以及被核验源码SHA256。

源码SHA256：pkg=`bec4d6b583e5a2c73bbdd1f3715137a3dee446c0a1e25090f7af7cab8db65f16`；decode=`ecb64bc43a68ab7e82e6556e71d026ef7e54d1d104ff3eba70097792d011688e`。

oracle首次执行把TF32的sign误纳入magnitude掩码，导致−0/−Inf两项oracle误报；已将掩码改为E8+M10的18bit，重新核对同一份DUT日志后为0 mismatch。此修正未修改DUT，也未把测试工具错误归为RTL缺陷。

### 7.2 核心/输出编码静态首审

已只读检查 `malu_core.sv`、`malu_round_pack.sv`、`malu_decode.sv` 和 `malu_pkg.sv`：

- 低精度acc覆盖位指数−300..339；完整acc覆盖−2148..2075。当前cfg只允许低位格式使用microscale、K≤65535，FP32最小乘积2^-298及F64最小乘积2^-2148均有覆盖；最大dot求和也留有sign/headroom。该结论不外推到任意FP64+microscale项目扩展。
- scale的4bit有效数没有被丢弃，复用乘法核执行A×scaleA、B×scaleB后再乘AB；cfg只允许低位浮点格式走该路径，53bit中间有效数宽度足够。
- 负数输入转换、term逐limb加减、全宽绝对值、GRS收集和最终半偶/定向舍入路径在首审中未发现阻断问题；此为代码审查结论，不是端到端仿真通过声明。
- TF32采用32-bit carrier、低13bit必须为0，是明确的PROJECT_EXACT传输协议；仍应在README中明确，不能描述成PTX规定的唯一raw布局。
- raw Ti16经cfg拒绝；decoded项目模式逐元素检查±2047。UE4M3bit7非法明确拒绝；高64bit carrier未使用部分属于项目接口约定。
- 主端到端仿真及三轮检查汇总尚待主agent结果；本记录没有提前声明整个MALU验证通过。

## 8. 第三轮独立最终总评

**结论：当前稳定源码在已记录的 PROJECT_EXACT 功能范围内，未发现需阻断本轮交付的问题；三轮实际主回归及独立decoder核验均通过。**以下是最终复核，取代第7节末尾的等待状态。该结论不是形式证明、全部输入空间穷尽证明、NVIDIA设备位级拟合或工艺映射PPA结论。

### 8.1 稳定源码与日志一致性

- 已独立读取 `build/malu/round{1,2,3}/results.json`，三轮的11项SV/filelist源码SHA256映射完全一致。
- 用当前工作区的相同文件重新计算SHA256和聚合指纹，仍与三轮报告全部相同：`197395785750354d3e1acf59dbba4542894062cfe66390eb952ed6d9022f96fd`。
- 已逐一检查4份 `run_l*_f*.log` 中真实 `MALU_PASS` 行，计数、LANES、FP64、cycles与JSON完全相符；日志没有MISMATCH、%Error或Aborting。
- 已检查vector manifest数量与name列表长度等于实际执行数；不能用仅存在`passed=true`字段代替上述日志核验。

| 轮次/配置 | 主向量 | 协议项 | 实际cycles |
|---|---:|---:|---:|
| Round1，LANES4 / FP64 on | 228 | 14 | 84,271 |
| Round2，LANES4 / FP64 on | 1,228 | 14 | 780,411 |
| Round3，LANES4 / FP64 on | 9,177 | 14 | 2,194,731 |
| Round3，LANES1 / FP64 off | 228 | 13 | 61,616 |
| **累计执行** | **10,861** | **55** | — |

这是跨轮次累计执行量，包含重复定向向量在不同seed/beat调度下重跑，不标为10,861个互异数学输入。另有本agent独立decoder **66,999例**，不混入主回归数量。

### 8.2 指定关键场景确实进入实际向量与协议测试

已检查Round3 `vectors_l4_f1.json/.txt` 与 `tools/generate_malu_vectors.py`，不是只看场景名称：

- `f64_borrow_entire_ram`有4种rounding：实际输入构成 `1 − 2^-2148`，检验最低乘积位与跨大量limb的借位；RNE/RUP预期为1，RTZ/RDN预期为F64的1以下相邻值。名称中的entire不应被解释成已穷尽所有132个RAM位置的借位组合。
- `f64_huge_product_cancellation`有4种rounding：最大有限F64的正、负乘积精确抵消，并保留正式输入C=3，预期D=3。能检验先把超大中间乘积错误舍入成Inf的实现缺陷。
- `scaled_fp4_boundaries`有48例：3种scale格式 × block16/32 × 8种K，含不同A/B block offset及变化的scale mantissa；另外UE4 scale codes有6例、UE5有5例、UE8最小scaled值有4种rounding。
- Ti16 raw unsupported、decoded越界、TF32非canonical低13bit均有实际拒绝向量。
- `tb_malu.sv`的protocol_tests实际覆盖：清RAM期间reset、response backpressure期间reset、有限浮点项跨RAM word累加期间reset；每次reset后有fresh request及tag/data核对。
- 新错误abort测试使用decoded Ti16值2048触发BAD_ENCODING，在未被接受的后续beat仍valid时等待错误response，然后取消该beat；响应状态/数据/tag都经response任务检查。
- 每轮LANES4执行14项协议、LANES1执行13项，唯一减少项为多lane跨scale block边界的单beat检查。不是遗漏了LANES1 reset或error-abort。

FP64-off配置中的F64向量按UNSUPPORTED验证，不能计为该配置执行了F64算术。

### 8.3 资源复用的证据边界

已独立解析 `resources_fp64_0.xml`、`resources_fp64_1.xml`：两种配置都只有1个非const乘法节点；acc_ram实际elaborated数组上界分别为0x13和0x83，即20和132个32-bit word。这与RTL的 `RAM_WORDS = ENABLE_FP64 ? FULL_ACC_WORDS : LOW_ACC_WORDS` 一致。

该结果支持共享乘法核与FP64-off存储缩减的**RTL elaboration层面**声明，不证明已经映射为某个真实单端口RAM宏、达到某个频率或具有Rubin算力配比。

### 8.4 最终保留的功能边界

- Ti16 raw编码仍是有意UNSUPPORTED；独立decoded整数项目协议已实现并验证，不把二者混称。
- TF32的低13bit=0是本项目传输约定；PROJECT_EXACT不自称tcgen05内部布局/累加微架构。
- 本轮通过的是点积+C数值核心及所述流接口，不覆盖TMEM/CTA调度、未接入的稀疏metadata原生解码或完整PTX指令执行前端。
- 详细机器可读独立总评保存在 `review3/final_independent_audit.json`，包含源码指纹、日志SHA256、各配置覆盖、实际XML资源检查及结论。


## 9. 最终资源收缩delta复核（更新最终指纹）

已检查资源优化后的实际新日志与三轮新results；没有重新发起全量仿真。第8节的源码指纹现已更新为最终版本 **`197395785750354d3e1acf59dbba4542894062cfe66390eb952ed6d9022f96fd`**，三轮11项源码/filelist映射与当前工作区重新计算值全部一致。主10,861向量+55协议的4个配置仍全部MALU_PASS，counts及cycles均与优化前相同。pkg/decoder源码SHA未改变，独立66,999项decoder证据继续适用。

本次功能delta只有共享乘法核的实际参数位宽：

| 配置 | 源乘法operand | 乘法表达式结果 | 进入既有累加路径的系数 | 实际acc RAM |
|---|---|---|---|---|
| FP64 on | 53×53 | 106 bit | 106 bit | 132×32 bit |
| FP64 off | 24×24 | 48 bit | zero-extend至106 bit | 20×32 bit |

已独立解析两个新XML的实际mul表达式dtype及其operand叶节点，不依赖可能被optimizer消除的`shared_product`变量名；每配置仅1个变量乘法节点。RAM上界分别为0x83/0x13。FP64-off的合法A/B中最大有效数为FP32的24bit；scaled路径仅低位格式，含scale有效数乘积也在24bit内，因此此收缩不会截断当前合法乘法操作数。原106bit项对齐/分段累加算法保持不变。

第一次第三轮报告生成遇到optimizer alias消除引起的资源审计脚本KeyError，发生于数值/协议仿真均PASS之后；这是审计脚本按变量名定位的错误，不是DUT数值失败。现已改为核验mul表达式dtype，新round3 results/resources与原始PASS日志均已落盘并复核。

**最终结论保持：PROJECT_EXACT已声明范围内未发现需阻断交付的问题；资源收缩获得新的elaboration证据，不扩大为工艺映射PPA或NVIDIA吞吐声明。**
