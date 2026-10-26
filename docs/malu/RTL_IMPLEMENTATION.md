# MALU RTL 实现与三轮检查记录

实现阶段：PROJECT_EXACT 功能基线
回归日期：2026-10-25（Asia/Shanghai）；证据归档与本文同步日期：2026-10-26
设计入口：design/core/src/rtl/sp/eu/tensor/malu/malu.sv
专用接口：design/core/src/if/sp/eu/tensor/malu/malu_if.sv

## 1. 当前实现的数值契约

MALU 是 Matrix ALU，外部只执行完整向量点积加正式输入 C：

    D = C × 2^(-c_scale_shift) + Σ[i=0..K-1] (A[i] × SA[i]) × (B[i] × SB[i])

关闭 block scaling 时 SA/SB 的数学作用为 1；普通点积 c_scale_shift=0。非零 C shift 只在配置检查允许的 F16/BF16 或 TF32 输入组合生效。该参数不属于 A/B scale 格式或 block 配置。

唯一已实现的 profile 编号是 PROJECT_EXACT=0。有限输入先解码为整数有效数和二进制指数，乘积及 scale 组合不做中间浮点舍入，用整数 RAM 累加器保存完整数学和，最后按 D 格式执行一次最终舍入。这里的“最后一次”是本项目明确选择的数值契约，不是对 tcgen05、Rubin 或所有 Tensor Core 的归约方式作保证。

浮点支持 RNE、RTZ、RDN、RUP，输出采用渐进下溢；规范化、GRS 和舍入增量由核心完成。NaN 产生正的 canonical quiet NaN，不保留输入 payload；相反符号 Inf 的和、0×Inf 等产生 NaN。全部同号零保持其符号；混合零或非零项精确抵消时 RDN 给 -0，其余模式给 +0。

整数结果为 S32 低 32 位回绕，或在允许 int_sat 的组合中对完整数学结果执行最终 S32 饱和。B1 的 term 为 AND 或 XOR 后的 0/1，再与正式 S32 C 累加。这是点积模式，没有开放独立标量逻辑指令。

实现不使用 real/shortreal 运算。它不是 NVIDIA 设备 bitfit，也没有达到或验证 Rubin 的绝对吞吐及格式配比。原设计文档中的 Rubin dense 参考比 0.5:1:4.375:8.75 仍是架构目标，不能写成当前串行引擎的实测性能。

## 2. 源码组织

| 文件 | 职责 |
|---|---|
| design/core/src/common/malu_pkg.sv | 枚举、配置结构、格式参数和配置合法性 |
| design/core/src/if/sp/eu/tensor/malu/malu_if.sv | 请求、操作数和响应通道；modport；可选握手断言 |
| design/core/src/rtl/sp/eu/tensor/malu/malu.sv | interface 包装顶层 |
| design/core/src/rtl/sp/eu/tensor/malu/malu_core.sv | 单上下文状态机、共享乘法／加法及 RAM 累加 |
| design/core/src/rtl/sp/eu/tensor/malu/malu_decode.sv | 一个复用的数值解码器 |
| design/core/src/rtl/sp/eu/tensor/malu/malu_round_pack.sv | 已舍入幅值的 IEEE 结果编码，不另设舍入加法器 |

编译顺序为 package、interface、decoder/encoder、core、包装顶层，再编译 testbench。filelist 由对应 flow 入口从项目根解析。验证入口及最终测试命令见第 9 节。

## 3. 参数与接口

顶层默认 LANES=4、TAG_W=8、MAX_K=65535、ENABLE_FP64=1。LANES 是一拍最多缓存的逻辑元素数，不是每周期同时工作的乘法器数。interface 和顶层必须使用一致的 LANES/TAG_W。

### 3.1 请求通道

| 字段 | 方向／类型 | 实际语义 |
|---|---|---|
| req_valid / req_ready | 输入／输出 | 在 IDLE 接受一笔描述符 |
| req_cfg | 输入 malu_cfg_t | 整笔事务配置，接受后锁存 |
| req_c | 输入 64 bit | 正式 C 原始编码，按 c_fmt 解释 |
| req_tag | 输入 TAG_W bit | 原样返回的事务标识 |

malu_cfg_t 的真实字段：

| 字段 | 类型／位数 | 说明 |
|---|---|---|
| a_fmt/b_fmt/c_fmt/d_fmt | 各 5 位 enum | 四种数据角色分别描述 |
| a_scale_fmt/b_scale_fmt | 各 2 位 enum | NONE、UE8M0、UE4M3、UE5M3 |
| block_scale_en | 1 bit | 运行时启用缩放 |
| block_size | 1 位 enum | BLOCK16=0、BLOCK32=1 |
| a_block_offset/b_block_offset | 各 5 bit | 首元素在其 scale 块内的位置 |
| k | 16 bit | 逻辑元素总数，必须 1..MAX_K |
| rounding | 2 位 enum | RNE=0、RTZ=1、RDN=2、RUP=3 |
| int_sat | 1 bit | 允许的整数模式最终饱和 |
| binary_xor | 1 bit | B1 为 1 时 XOR，为 0 时 AND |
| ti16_decoded | 1 bit | Ti16 项目解码后传输协议开关 |
| c_scale_shift | 4 bit | C 的 2^(-s) 变换，s=0..15 |
| profile | 2 bit | 目前仅接受 PROJECT_EXACT=0 |

### 3.2 操作数通道

| 字段 | 类型 | 实际语义 |
|---|---|---|
| op_valid/op_ready | 握手 | 仅 WAIT_BEAT 可以接收 |
| op_a/op_b | 每侧 LANES×64 bit | 每 lane 为一个元素的低位原始编码 |
| op_count | clog2(LANES+1) bit | 本拍有效前缀 lane 数，必须 1..LANES |
| op_scale_a/op_scale_b | 各 8 bit | 当前 A/B 块的 scale，本拍重复携带 |
| op_last | 1 bit | 必须恰好与本拍后累计元素数等于 k 一致 |

该接口不是 PTX 原生紧密打包布局。每个元素占一个独立 64 位槽；未使用的高位不提供额外数值精度。没有任意 lane mask，只有从 lane 0 起的连续 op_count 个有效元素。

开启缩放时，每拍不能跨越任一 A/B scale 块边界。上层按两侧最早到达的边界切拍；当前拍应携带各自对应的 scale。一个 scale 块内后续 beat 必须重复相同 payload，否则返回 BAD_ENCODING。块边界按整笔事务的逻辑 K 和独立 offset 计算，不随停顿或 beat 重新起算。

### 3.3 响应、复位与错误

rsp_valid/rsp_ready、64 位 rsp_data、rsp_tag 和 rsp_status 构成响应。结果仅低 d_fmt 位有效，高位清零；S32 为 32 位位模式，高 32 位也清零，不进行 64 位符号扩展。

| 状态 | 编码 | 条件 |
|---|---|---|
| OK | 0 | 正常完成 |
| BAD_CFG | 1 | 不允许的数据／scale／控制组合 |
| BAD_ENCODING | 2 | TF32 低 13 位非零、UE4M3 bit7 非零、块内 scale 改变等 |
| LENGTH | 3 | k=0、超限、拍长／last 错误或跨块拍 |
| UNSUPPORTED | 4 | 未实现 profile、被关闭的 F64、PTX raw Ti16 |
| RANGE | 5 | 中间系数或累加器对齐范围检查失败 |

NaN/Inf 本身是数值结果，不自动作为协议错误。错误响应的数据为 0，tag 保持该请求；错误出现后不继续消费该事务后续操作数。发送端必须在观察完成／错误后停止旧数据，再发新请求。

单上下文基线在响应消费前不接收下一笔请求。valid 且非 ready 时 payload 必须稳定。异步低有效 rst_n 清控制和有效状态，丢弃在途事务；不在 reset 中整体清 RAM，下一笔合法请求先执行 CLEAR。

定义 MALU_ASSERTIONS 后 interface 包含请求、操作数和响应的阻塞稳定性断言。仅声明断言不等于已运行；实际执行情况见三轮记录。

## 4. 当前支持与拒绝范围

### 4.1 浮点

普通 A/B 各自可以为 F16、BF16、TF32、F32、F64、E4M3、E5M2、E2M3、E3M2、E2M1；C/D 各自可以为 F16、BF16、F32、F64。浮点数据与整数数据不混为一笔事务。ENABLE_FP64=0 时，任一角色选 F64 均拒绝。

这些是 PROJECT_EXACT 的功能集合。不同 A/B、独立 C/D 和普通 F32 乘数等组合不能自动标为原生 tcgen05 tuple；本版不声称是带 target/shape 检查的完整 PTX 指令 legalizer。

TF32 采用项目传输约定：32 位 F32 容器中的低 13 位必须为零，使用其余有效数位，不在输入端替发送者量化任意 F32。PTX 对 TF32 内部布局的定义限制与项目协议不同，应保留该区别。

### 4.2 scale 与块长

| A/B | scale 格式 | 运行时块长 |
|---|---|---|
| 各自为任意 FP8/FP6/FP4 输入类型 | 两侧相同的 UE8M0 | BLOCK32 |
| 两侧均 E2M1 | 两侧相同的 UE8M0 | BLOCK16 或 BLOCK32 |
| 两侧均 E2M1 | 两侧相同的 UE4M3 或 UE5M3 | BLOCK16 或 BLOCK32 |

开启缩放时 A/B scale 不能为 NONE，也不能互不相同；offset 必须小于所选 16/32。禁用缩放时 scale 字段不参与数学运算。UE8M0=0xff、UE4M3=0x7f、UE5M3=0xff 按各自 NaN 处理；UE4M3 只允许 7 位有效编码，bit7 必须零。

### 4.3 整数、B1 与 Ti16

| 输入组合 | C/D | 支持条件 |
|---|---|---|
| S8/U8 两侧独立 | S32/S32 | 两侧 8 位；可选最终 int_sat |
| S4/U4 两侧独立 | S32/S32 | 两侧 4 位；可选最终 int_sat |
| B1/B1 | S32/S32 | AND/XOR 点积，不允许 int_sat |
| TI16/TI16 | S32/S32 | 仅 ti16_decoded=1 的项目协议；不允许 int_sat |

整数不能启用 block scale 或非零 C shift，不支持不同位宽组合。B1 与其他整数混合、TI16 与其他整数混合均拒绝。普通整数模式不允许 binary_xor=1。

TI16 的数学范围沿用已核验的 [-2047,2047]。ti16_decoded=1 明确表示发送者提供低 16 位 two's-complement 的“已解码数学整数”；超过范围返回 BAD_ENCODING。它不是 PTX 原生 S1Z4M11 raw-bit 解码器。ti16_decoded=0 的原生编码请求返回 UNSUPPORTED，不把尚无证据的负数编码假定为 S16。

## 5. 共享资源与串行 RAM 累加

核心在 RTL 中只有一处参数化数值乘法表达式：ENABLE_FP64=1 时为 53×53，关闭时为 24×24；另有一处 33 位带 carry 数值加法表达式、一个 decoder 实例和一份共享累加数组。这里的“一个表达式”不代表目标工艺中只占一个 DSP 或只有一个门级加法器；控制计数和索引也包含地址运算，实际映射必须看综合报告。

| 模式 | active_words | 数学 LSB 指数 |
|---|---:|---:|
| 整数／B1／decoded Ti16 | 2 | 0 |
| 不涉及 F64 的浮点 | 20 | -300 |
| 任一 A/B/C/D 为 F64 | 132 | -2148 |

数组声明深度为 RAM_WORDS=ENABLE_FP64?132:20。默认启用 F64 时为 132×32=4224 bit；在 elaboration 关闭 F64 时，实际声明缩减为 20×32=640 bit。整数事务仍只使用前 2 words，不是在运行时生成另一块 2-word RAM。

事务仅清当前 active_words，并只扫描这一范围，减少周期和切换；不能据此声称物理 RAM 容量在运行时变小。读写按独立状态串行进行，属于单端口行为；是否推断成目标 block RAM 未经技术映射确认。

### 5.1 乘法复用

无缩放时共享乘法器执行 A×B。开启缩放后依次执行 A×SA、B×SB、两侧已缩放有效数的乘积；指数独立相加，中间不进行浮点 round/pack。允许的低精度格式与 scale 系数可容纳在 F64 关闭时的 24 位乘法输入中；F64 打开使用 53 位输入。核心检查乘积和累加范围，失败返回 RANGE。

每拍虽然可缓存 LANES 个元素，元素仍顺序解码和运算。提高 LANES 不会自动提高每周期产品数。

### 5.2 加法复用

有效乘积及其指数先形成不超过 106 位的系数，最多左移 31 位形成局部窗口，再从起始 word 到 active_words-1 做完整 carry／borrow 传播。每个 word 使用 ACC_READ 和 ACC_WRITE 两个周期，不把大累加向量整体接到组合加法器。

负数转换、累加、最终取绝对值、整数结果取负及舍入增量均复用同一数值 word adder。浮点舍入需要的 53 位加一拆为低 32 位与高位两次操作，不另设隐藏的宽舍入加法器。

RAM 用二补码保存数学和；最终按符号取幅值，扫描最高非零位，再扫描全部有效 words 收集结果有效数和 GRS。输出 encoder 只封装位模式。

### 5.3 elaboration 资源审计

第三轮使用 Verilator XML 对开／关 F64 两种参数进行实际展开，读取乘法节点、位宽和 RAM 数组边界，结果为：

| 参数 | 非常量乘法节点 | 操作数／结果位宽 | 共享 word 加法结果 | 实际 acc_ram |
|---|---:|---|---|---|
| ENABLE_FP64=1 | 1 | 53×53 → 106 bit | 33 bit，含 carry | 132×32=4224 bit |
| ENABLE_FP64=0 | 1 | 24×24 → 48 bit | 33 bit，含 carry | 20×32=640 bit |

归档证据为 [checks/2026-10-26/resource_inventory.json](checks/2026-10-26/resource_inventory.json)。原始 elaboration XML 位于 build/malu/round3/resources_fp64_1.xml 和 resources_fp64_0.xml，可用回归脚本重新生成；独立审查已读取 XML 验证实际变量乘法位宽和 132／20 words，而不是只从参数预期填表。

这是 elaborated RTL 审计，不是技术映射后的 DSP 数、RAM macro 保证或 PPA 签核。宽加法链、mux、控制计数和地址逻辑仍可能影响综合结果；没有用“一个乘法节点”承诺只使用一个物理乘法硬块。

## 6. 延迟与吞吐

延迟从请求接受的时钟边沿计到 rsp_valid 首次为 1；等待 rsp_ready 的时间另计。输入没有及时有效时的 WAIT_BEAT 停顿也单独计入。本版不是固定延迟单元。

令 W 为 active_words、s 为当前非零有限项的起始 word：

- CLEAR 为 W 个周期。
- 每项 RAM 加法为 2×(W-s) 个周期。
- 无缩放、无负整数幅值转换的非零有限项还有 5 个控制周期：DECODE_A、DECODE_B、PREPARE、MUL_AB、NEXT_ITEM。
- 开启缩放额外 4 个周期：DECODE_SA、DECODE_SB、MUL_A_SCALE、MUL_B_SCALE。
- 每个需要符号幅值转换的负整数输入额外 1 个 DECODE_ABS 周期。
- C 的解码／累加单独执行一次，不能只用 K 项公式忽略 C。
- 收尾包含符号读取；负和取幅值需 2W 周期；最高位搜索最多 2W 周期；非零结果 GRS 扫描为 2W 周期；若需舍入进位再加 2 个 word-adder 周期。

零、Inf、NaN 和不同起始 exponent 会走不同路径，故以上是状态分解，不是对全部数据的一条固定总周期公式。实际测试集累计周期见第 8 节；它们不等于单笔端到端延迟。

同一逻辑 dot 的 beat 切分不会改变精确数学和，但会改变 WAIT_BEAT 接收及等待次数。该单上下文基线不能用 4 个缓存 lane 宣称“每周期 4 项”。没有综合、时序或目标频率证据时，不报告 FLOPS、DSP、面积或功耗。

## 7. 验证方法与独立性

本轮使用 Verilator 执行 SystemVerilog testbench；Python Fraction 离线生成独立精确数值期望向量，不是 DUT，也不参与综合。RTL、testbench 和 SVA 均为 SystemVerilog；外部 Python 是回归辅助工具，没有 DPI 或 real/shortreal 数学路径。

数值 oracle 必须从格式编码与数学值独立计算乘积、scale、C 和最终舍入，不能调用 RTL 的 decode/round 函数直接生成预期值。整数参考模型分别检查最终 wrap/sat。特殊值、signed zero 和所有舍入模式需要定向向量补充 Fraction 的有限实数模型。

低比特格式使用小编码空间穷举和边界回归；协议测试包括非法请求、零／越界长度、last 不一致、跨块拍、块内 scale 改变、反压、复位以及错误后的恢复。测试通过只覆盖实际列出的用例，不能扩写为全部输入的形式证明。

## 8. 三轮检查记录

三轮主回归已完成，均启用 SVA。工具为 Verilator 5.032，Debian 5.032-1+b2。数值期望由独立 Fraction／整数 quotient-remainder 舍入生成，SV testbench 逐位核对结果、状态和 tag，并对每笔响应施加随机反压。

| 轮次 | 测试集／seed | 参数 | 数值事务 | 协议用例 | 仿真周期总数 | 结果 |
|---|---|---|---:|---:|---:|---|
| 1 | smoke／1 | LANES=4，F64 开 | 228 | 14 | 84,271 | PASS |
| 2 | random／1907 | LANES=4，F64 开 | 1,228 | 14 | 780,411 | PASS |
| 3 | exhaustive／2026 | LANES=4，F64 开 | 9,177 | 14 | 2,194,731 | PASS |
| 3 参数复查 | smoke／29 | LANES=1，F64 关 | 228 | 13 | 61,616 | PASS |

合计实际执行 10,861 个数值事务和 55 个协议用例；这些是执行计数，不代表所有事务互不重复，也不是完整输入空间的穷尽证明。周期列是整个测试集的累计仿真周期，不是每笔点积延迟。

三轮的 DUT/TB/filelist source_signature 均为：

    197395785750354d3e1acf59dbba4542894062cfe66390eb952ed6d9022f96fd

各 results.json 保存完整逐文件 SHA-256。指纹、参数和工具版本匹配时复用已有编译结果；不同 LANES/F64 配置有独立构建目录和指纹。最终记录中 Round 1 默认配置重新编译，后续配置复用匹配构建，但每个表格条目均实际执行对应向量与 seed，没有因编译复用跳过仿真。

### 8.1 实际覆盖内容

- 定向：各输入格式、四种舍入、最小次正规乘积、signed zero、巨大 F64 乘积抵消、跨整块 RAM 的 borrow、负极小结果、BF16 中点、上下溢和 FP16 特殊值。
- 缩放：UE8M0/UE4M3/UE5M3、BLOCK16/BLOCK32、独立 offset、跨多个逻辑块、scale 极值与非法填充／变化。
- 整数：有符号／无符号、decoded Ti16 边界与越界、B1 AND/XOR、S32 wrap/sat；Round 3 包含 K=65535 的整数点积。
- 小格式：Round 3 对 E2M1、E2M3、E3M2 的单项原始输入对作穷举，再叠加定向与随机事务；没有据此宣称 F16/F32/F64 全空间穷举。
- 协议：空拍、早／晚 last、复位中止与恢复、阻塞响应、持有下一描述符、RAM 运算期间复位、错误取消未接受拍、块内 scale 改变和跨块拍。
- 每笔向量随机输入等待与有效前缀切拍，输出等待 1..5 个周期；断言检查阻塞期间 payload 稳定。

LANES=1 配置的协议数比默认少 1，是因为“一个拍跨块”的双元素测试对单 lane 不适用，不是遗漏后直接算通过。

### 8.2 lint、bring-up 与修正

最终 runner 对 warning 保持 fatal，没有使用全局 -Wno-fatal。全局只明确豁免 UNUSEDSIGNAL（已验证后不再使用的结构字段）和 UNUSEDPARAM（公共常量）。testbench 的时钟发生器在其局部对 BLKSEQ 作意图豁免；DUT 的位宽、锁存及数值时序 blocking 类警告不通过全局关闭处理。

最初 bring-up 曾发现 testbench 对文件末尾 EOF 的识别问题，以及命令行 bit 参数常量的位宽警告；均已修正后重跑。它们不是 DUT 数学错误。最初带 18 条警告的检查日志是调试历史，不是当前三轮的最终质量结论。

最终三轮建立在上述相同源指纹上。小型原始证据已归档至 [checks/2026-10-26/](checks/2026-10-26/README.md)：

- round1_results.json、round2_results.json、round3_results.json。
- round1_run_l4_f1.log、round2_run_l4_f1.log、round3_run_l4_f1.log、round3_run_l1_f0.log。
- resource_inventory.json、独立审查结果与 archive_manifest.json。

完整原始构建目录仍为 build/malu/round1、round2、round3；lint 日志为 build/malu/lint/latest.log。大型 XML、C++、向量全集和工具链不在小型证据归档中。

### 8.3 独立 decoder 复查

独立于主回归，agent1 运行实际 SV malu_decode，并以固定 CUTLASS 来源参数和独立 Python Fraction 解码数学值进行 66,999 项对照，结果为 0 mismatch：

| 内容 | 比较项数 |
|---|---:|
| E4M3/E5M2 全编码 | 512 |
| E2M3/E3M2 全编码 | 128 |
| E2M1 全编码 | 16 |
| UE8M0/UE4M3/UE5M3 全 byte，包括 UE4M3 非法 bit7 | 768 |
| decoded Ti16 全 16 位载体及 3 项 raw 拒绝 | 65,539 |
| TF32 边界 | 12 |
| F16/BF16/F32/F64 各 6 个边界 | 24 |

该计数不加入 10,861/55 主回归。独立复查保存 decoder/package SHA，与主回归记录一致；运行时不链接 CUTLASS，也不假定 raw S1Z4M11 编码已得到证明。

独立 oracle 初次执行曾将 TF32 sign 位纳入 magnitude 掩码，对 -0/-Inf 产生两项误报；修正 oracle 掩码后，对同一份 SV DUT 输出重查为 0 mismatch，未修改 DUT。结果已归档为 [decode_review_result.json](checks/2026-10-26/decode_review_result.json)，原始工作区 output/malu/review3 另保存 decode_results.log、decode_build.log、tb_decode_review.sv 和 check_decode.py。

### 8.4 最终独立复核

独立审查将三轮 results.json 的 11 个源文件 SHA 与当前源码逐一比较，并核对四份原始 MALU_PASS 日志、向量 manifest 数量和两份 XML。所有源映射一致，执行计数与汇总一致；其结论是在已说明的 PROJECT_EXACT 范围内未发现交付阻断问题，不构成形式证明、GPU 逐位匹配或工艺 PPA 结果。

该机器记录已归档为 [final_independent_audit.json](checks/2026-10-26/final_independent_audit.json)，含原始日志哈希、选定覆盖项及复位／错误恢复审查条目；归档时又将 11 项源文件 SHA 和聚合签名与当前文件核对一致。

## 9. 运行入口与结果

从仓库根目录运行：

    python3 tools/bootstrap_verilator.py
    python3 tools/run_malu_checks.py --round all --jobs 2

bootstrap 在没有可用系统工具时将锁定版本解包到 build/toolchain/verilator，不需要 root。包的初次锁定使用 Debian InRelease 签名→软件索引 SHA-256→包 SHA-256，后续下载依据 tools/verilator.lock.json 校验。需要 Python 3、C++ 编译器、make、dpkg-deb 及该 Debian amd64 工具包的运行环境。

runner 优先使用 VERILATOR 环境变量，再查 PATH，最后查本地工具包；自动推导本地 VERILATOR_ROOT。已有合适工具时无需重复 bootstrap。--jobs 只控制构建并行度。

分轮及 lint 入口：

    python3 tools/run_malu_checks.py --round 1
    python3 tools/run_malu_checks.py --round 2
    python3 tools/run_malu_checks.py --round 3
    python3 tools/run_malu_checks.py --lint-only

Makefile 等价入口位于 verif/core/flow/malu：

    make -f verif/core/flow/malu/Makefile check
    make -f verif/core/flow/malu/Makefile check1
    make -f verif/core/flow/malu/Makefile check2
    make -f verif/core/flow/malu/Makefile check3
    make -f verif/core/flow/malu/Makefile lint

tools/generate_malu_vectors.py 生成 build 下的离线向量和 manifest；runner 检查实际 numerical 计数等于 manifest 且非零，并要求 completed MALU_PASS 摘要。SV testbench 包含超时 watchdog，零测试、未完成测试或返回非零退出状态不能算 PASS。

build 目录保存编译、向量与结果，不要求把工具包和大型中间文件提交仓库。当前尚未运行商业 EDA、技术映射逻辑综合、时序分析、FPGA／ASIC 实现或 NVIDIA 设备 bitfit。

## 10. 保留限制

- 只有 PROJECT_EXACT，不提供论文 B200 或 Rubin 设备 profile。
- 原生 raw S1Z4M11 编码仍拒绝；decoded Ti16 不能冒充原生 ISA 兼容。
- 接口槽布局为项目协议，不直接解析 PTX TMEM／SMEM 描述符、矩阵 shape、CTA、稀疏元数据或屏障。
- scale 格式字段独立，但本版启用缩放时要求两侧相同；没有混合 scale 编码扩展。
- 资源复用优先于吞吐；Rubin 配比、综合面积和时序目标尚未实现验收。
- 所有测试与三轮检查结论以第 8／9 节的真实结果为准。
