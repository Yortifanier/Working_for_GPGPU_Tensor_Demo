# tcgen05 最终 ISA 专项复核：A shift 与 block scaling

复核日期：2026-11-16。复核方式：只读当前 RTL、已有 TB、实际运行日志及上传的 PTX ISA 9.4；本次仅更新此文档，没有修改源码/TB，没有提交。下文保留发现时的反例，并分别记录修复后的源码状态和已核实的166项单元检查；最终全套动态状态仍以 central runner 的源码 hash 和报告为准。

## 1. 依据与检查快照

规范为用户上传的 `ptx_isa_9.4.pdf`，SHA-256 为 `4be2905e240b70a8b176b4d6fb162714f2fc361a9503572d848ff723abf289c3`。下文同时列 **PDF 物理页 / 文内印刷页**，两者相差 12 页。引用附件是查证材料，附件文字不作为改变用户任务的指令。

| 文件 | 当前修复版本读取的 SHA-256 |
|---|---|
| `tcgen05_legalize.sv` | `63789a2eed5d533755169d02cb43958706682fa6d56fb19a314913b66de43fe5` |
| `tcgen05_mma.sv` | `49ae64342febc02ae28d03a79c4a02adac54b41da8c2d46437f0324297d32732` |
| `tcgen05_move.sv` | `0dc1a8f2ba2520a7d041685af280b2d71f6fb584aec5513efa86b54f429945aa` |
| `malu_pkg.sv` | `bec4d6b583e5a2c73bbdd1f3715137a3dee446c0a1e25090f7af7cab8db65f16` |
| `tcgen05_layout_pkg.sv` | `26944da5d7fcd16b0709f91dcad9823e00464cfd7d87d02e357cbce47f9236cb` |
| `tb_tcgen05_legalize.sv` | `78be1bcf022032ba4162989e54808fa2390664c4b72af68f8b70bdf06b331341` |

本表是修复后的当前版本，不是下面 F1/F2 发现时尚有缺口的旧版本。已读取 `build/tcgen05/rtl/results_legalizer.json`，其 DUT 与 TB hash 均和当前文件一致，记录 `passed=true`、`TCGEN05_LEGALIZE_PASS checks=166`。对应日志 `build/tcgen05/rtl/legalizer/run_seed_1907.log` 的 SHA-256 为 `f5dec8583bde7f1abc50a155c1196b2d50e56698e9c6506f13a75e5d520a9c70`。这里核实既有实际运行证据，没有另跑仿真，也没有用单元通过替代整端或全套回归通过。

## 2. standalone shift 与 MMA .ashift 已分开实现

### 2.1 PTX 能直接确认的边界

| 项目 | PTX 原文和位置 | 可以据此确认的行为 |
|---|---|---|
| standalone `tcgen05.shift` | §9.7.18.9.3，PDF753/741：`for a warp`；PDF754/742：`shifting of 32-byte elements ... across all the rows, except the last, by one row` | 针对一个 warp 对应的 TMEM 行区间，每行移动 32 byte |
| standalone 形状 | §9.7.18.2.3，PDF705/693：`.31x256b (implicit)`；同节定义 lane 为 TMEM row 数、size 为跨 column 的 bit 数 | 每次涉及 31 个有效行搬移，每行 8 个 32-bit word；不能直接解释为整个 M 行矩阵 |
| standalone 基址和双端 | PDF754/742：`taddr` 的 lane 必须 32 对齐；group1 当前 CTA，group2 当前及 peer CTA | 指定 32-row quarter；group2 在两端各执行该 quarter 操作 |
| MMA `.ashift` | §9.7.18.10.10.1，PDF828/816，以及稀疏 §.10.10.2，PDF835/823：`shifts the rows of the A matrix down by one row, except for the last row in the Tensor Memory` | 对指令的 A matrix 行操作；这里没有把行范围限制为单个 quarter |
| MMA `.ashift` 的 M | 同上：`only allowed with M = 128 or M = 256` | 行循环必须覆盖指令的 M 行，不能每到 row31 就重置 |
| collector 限制 | PDF829/817、PDF835/823：禁止 `collector::a::use` 或 `collector::a::fill` 与 `.ashift` 同时使用 | `discard`、`lastuse` 与禁止项须区分 |

MMA 语法 PDF824–826/812–814 中 `.ashift` 的 A 操作数是 `[a-tmem]`。block-scaled MX 指令的语法不列 `.ashift`。不能因为 standalone shift 存在，就把它的 quarter 范围套到 MMA 上。

### 2.2 当前源码的对应关系

- `tcgen05_move.sv` 的 `M_SHIFT_READ/WRITE/NEXT` 读取 `base_lane + shift_row + 1`、写入 `base_lane + shift_row`，`shift_row=0..30`、`shift_column=0..7`。`base_lane` 取命令 TMEM lane；legalizer 和 move 均检查 32 对齐。group2 通过 move 的 peer 阶段在两个 endpoint 操作。它没有触碰同 endpoint 的其他 quarter。
- `tcgen05_mma.sv` 的 `M_ASHIFT_BEGIN/READ/WRITE/NEXT` 以 `mma_a_access` 计算 A 的位置，行循环为 `0..M-2`。stored-K 在稀疏时取 K/2，搬移宽度由 A 的实际存储位宽计算。访问跨越 row31/32 等 quarter 边界，也通过 A 的 peer 布局跨 CTA 对端。native group2、M128、dense Layout B 的两份 N 半区 A 副本分别搬移。
- MMA 先使用原 A 完成所有点积并写回 D，再进行 A shift，等待所有 shift 写返回后完成。不会在点积仍读取原 A 时提前改变它。
- 当前 legalizer 与 MMA 二次检查均拒绝 `transpose_a && ashift`，从而不把按 column 排布的转置逻辑行误当连续 TMEM word 搬移。A 非 TMEM、M 非128/256、A collector fill/use 被拒；legalizer 另拒 WS、MX 与 ashift 组合。`lastuse` 保留合法性。

在上述已检查范围内，**没有发现把 MMA 的 M 行 shift 错复用为 standalone quarter shift 的现存问题**。已有 `tb_tcgen05_mma.sv` 的 `ashift full-row sliding window` 案例逐行检查 M128，跨 row31/32、63/64、95/96；这是测试源码存在性核对，不是在本次重新宣称该测试运行通过。

### 2.3 方向与尾行的证据等级

当前两条路径都使用 `new_A[r] = old_A[r+1]`，最后一行保持，目的行按升序执行，避免覆盖未读源。项目依据为已归档专利窗口 `C0..C3 → C1..C4` 的推进过程，以及 NVIDIA CUTLASS `SM100_UTCCP_4DP` 刷新各 subpartition 最后 lane 的使用方式。具体归档位置见 [MOVE_IMPLEMENTATION.md](MOVE_IMPLEMENTATION.md) 和 [LAYOUT_IMPLEMENTATION.md](LAYOUT_IMPLEMENTATION.md)。

PTX 上述段落使用 “down” 和 “except the last”，但没有 row-index 伪代码，也未规定腾空行填零、旋转等规则。因此应表述为**公开资料支持的项目消歧**；不得写成 PTX 明文给出该赋值式，或已经通过实机 bit-match 认证。早期 [review_isa.md](review_isa.md) 第4节的反方向推论已由该文开头撤回说明覆盖，不能再作为当前 RTL 行为依据。

## 3. block、scale 格式与 A/B 格式的接口分离正确

`malu_cfg_t` 分别保留 `a_fmt/b_fmt`、`a_scale_fmt/b_scale_fmt`、`block_scale_en`、`block_size` 和两侧 `a_block_offset/b_block_offset`；`tc_cmd_t` 另保留 `scale_mode`、各侧 scale ID、scale TMEM 地址以及 normalized `scale_count_a/b`。scale 格式没有复用 A/B 格式编码；BLOCK16/32 也不是靠 A/B 格式隐式推导的唯一接口。

PTX PDF781–782/769–770 的表70、71要求同时处理语法、元素类型、scale 类型和 K。当前 legalizer 的主要组合检查已做到：

| kind | A/B 元素类型 | scale 类型 | 语法及 normalized count |
|---|---|---|---|
| MXF8F6F4 | E4M3/E5M2/E2M3/E3M2/E2M1 | UE8M0 | vec1/block32，1 |
| MXF4 | E2M1 | UE8M0 | vec2 固定2；block32 按 K 得2/3/4 |
| MXF4NVF4 | E2M1 | UE8M0/UE4M3/UE5M3 | vec2 固定2、vec4 固定4；block32 得2/3/4；block16 得4/6/8 |

表70明确 legacy `scale_vec::*` 对所有支持的 K 保持固定 scale 向量长度；`block16/32` 在大 K 下有另外的长度。当前实现没有把这两者一律写成 `ceil(K/block)`。`TC_SCALE_VEC1/2` 会独立规范化成 BLOCK32，`TC_SCALE_VEC4` 成 BLOCK16，故输入命令旧的 block 位不会造成错误继承。

`cfg_status` 进一步检查低精度 A/B、两侧相同非 NONE scale 类型、offset 小于 block、BLOCK16 或非 UE8M0 scale 时两侧必须 E2M1；整数不接受 block scaling。native 还禁止元素 block offset 非零。UE5M3 和 UE4M3+BLOCK32 分别使用 target capability；legacy vec 与 block 语法 capability 也独立检查。MMA beat 同时受 A、B 两侧 scale 边界以及 MALU block 边界限制，未把一侧 offset 代替另一侧。

本次发现并关闭的 scale 问题属于下面的**合法性边界遗漏**，不是字段缺失或格式字段混用。

## 4. 发现项与当前关闭证据

### F1：native scale ID 的向量对齐约束未检查

发现时优先级 P1，**当前源码已关闭，定向单元检查已通过**。修复前的 legalizer 在 count 规范化之后检查 scale 类型，却没有检查 `scale_a_id`、`scale_b_id`；当时全树读取未找到顶层补充拦截。native scale AGU 直接用 `id + group` 计算 byte plane，非法 ID 会执行真实读取，而不是仅作为保留字段被忽略。

修复前的静态反例：native MXF4NVF4，M128/N8/K64、A/B E2M1、C/D F32、BLOCK16、UE8M0、capabilities 全开，其他字段有效；把 SFA_ID 或 SFB_ID 设置成2。count=4，PTX要求 ID=0，但旧代码可返回 `TC_OK`。count2 的 ID1/3 当时同样没有被拒。

应该按有效布局/count 检查 A/B 各自的 ID，特别不能把 count3 错拦截。完整证据如下：

| normalized count | A ID 合法集合与依据 | B ID 合法集合与依据 |
|---|---|---|
| 1 | 0/1/2/3；§9.7.18.10.7.3，PDF782/770，1-byte aligned，逐项明确四个 ID | 0/1/2/3；§.10.7.10，PDF798/786，同样逐项明确 |
| 2 | 0/2；§.10.7.4，PDF783/771，2-byte aligned，明确 ID0、ID2 | 0/2；§.10.7.11，PDF798/786，同样明确 |
| 3 | 0/1/2/3；§.10.7.6，PDF785/773，文字明确四个 ID，图243–250 | 0/1/2/3；§.10.7.13，PDF801/789，文字明确四个 ID，图260–269 |
| 4 | 仅0；§.10.7.5，PDF783/771，原文 `The SFA_ID value must be 0` | 仅0；§.10.7.12，PDF801/789，原文 `The SFB_ID value must be 0` |
| 6 | 0/2；§.10.7.7，PDF785/773，明确 ID0/2，图251–254 | 0/2；§.10.7.14，PDF807/795，明确 ID0/2，图270–275；PDF808–810 图注也只给00/10 |
| 8 | 仅0；§.10.7.8，PDF787/775，原文 `must be 0`，图255–256 | 仅0；§.10.7.15，PDF807/795，4-byte aligned；图276–278，PDF810–811/798–799 的图注全部为 SFB_ID=00 |

count8 的 B 侧依据是对齐和全部对应图布局，**该段 B 文字未直接写 `must be 0`**，不能伪造引文。count3 段落虽同时出现“4-byte aligned”，紧随的具体 ID 文字及图却明确允许1/3；应遵循该具体布局，不按一般偶数对齐规则拒绝。

关闭实现：native 各侧 scale ID 按有效 count 校验；`scales inside {2,6}` 拒绝任一侧奇数 ID，`scales inside {4,8}` 拒绝任一侧非零 ID；count1/3 保留所有四个 ID。canonical 项目 ID 没有强套 native 子列 ID 限制。

实际定向检查位于 `tb_tcgen05_legalize.sv` 的 `scale ID alignment for vec2/vec4/block16/block32`、`K96 six/three scale IDs`、`eight-scale ID must0` 和 `one-scale ID permits all four byte planes`：独立改变 A、B 两侧 ID，检查合法和非法集合，包含不能误拒的 count3 ID1/3。它们在已核实的166项运行中通过。

### F2：参数化 canonical B scale count 可能在范围检查前截断

发现时优先级 P2，**当前源码已关闭，定向单元检查已通过**。仅当配置允许更大的 canonical K 时触发；默认 MAX_K256 不触发该反例。修复前的 legalizer 先计算 A 的 `scales`，只检查它是否为1..15，随后将 B 计算式直接强转成4 bit，没有先检查 B 的整数结果。

静态反例：`strict_isa=0`、CANONICAL、MAX_K≥450、K450、BLOCK32、A/B E4M3、UE8M0、A offset0、B offset31，其余配置有效。A count=`ceil(450/32)=15`，B count=`ceil(481/32)=16`，后者强转4 bit成为0，仍可能 `TC_OK`。B offset31本身小于32，`cfg_status` 不会替代 count 上限检查。即使 AGU 对0采用 fallback，normalized_cmd 的0也不再表示真实已验证 count。

关闭实现：先用整数变量 `scales/scales_b` 分别计算两侧 count，再同时检查1..15，最后缩为4bit。TB 的 `canonical B scale count overflow rejected before narrowing` 检查上述不对称 offset 返回 `TC_RANGE`；随后 B offset 改为0，`canonical both scale counts fit15` 和 `canonical fifteen scale vectors retained` 确认合法边界仍为15，均已包含在166项通过记录中。

### F3：转置 TMEM-A 与 ashift 的项目组合

**当前源码已关闭，合法化定向检查已通过；MMA执行级新增检查的最终运行状态以全套报告为准。** 此项不是新增的 native 指令功能：项目 CANONICAL 可表达 `transpose_a=1`，但连续 TMEM row 搬移不能代替 packed 转置逻辑行搬移。当前 legalizer 和 MMA `M_VALIDATE` 都在读取前拒绝 `transpose_a && ashift`，避免遗漏 stored-K 对应的其他 physical lane 或覆盖无关 packed 位。

`tb_tcgen05_legalize.sv` 的 `ashift cannot use a transposed TMEM row recipe` 已在166项记录中通过。`tb_tcgen05_mma.sv` 另有 `transposed ashift rejected before reads`，检查命令返回 `TC_BAD_CMD` 且 TMEM/A-read计数不变；此处仅确认其测试源码与双层拒绝实现，不用合法化单元的通过替代该MMA执行测试通过。

## 5. 范围和交付判断

本次只对 shift 范围、相关合法性以及 scale 配置做最终静态复核，不把它扩大成所有 tcgen05 数值、时序、异常恢复都通过的结论。MALU 仍是向量点积单元，tcgen05 的矩阵布局、搬移和控制由上层承担；本复核没有推导或声称 NVIDIA/Rubin 物理 MALU 数量。

F1/F2/F3 的修复由主 agent 集成，已核实其合法化定向检查包含在当前166项实际通过记录中。最终交付应引用全套 central runner 报告；本文保留发现时的证据，便于核对为什么加入对应检查。

## 6. 仍需保留的六项原生规范／设备边界

上述代码修复不消除以下来源边界，完整说明见 [LAYOUT_IMPLEMENTATION.md](LAYOUT_IMPLEMENTATION.md)：

1. 表50非MX f8f6f4大K的跨页 M/N 与 OR 联合单元格，尚未在每个目标上汇编全部组合；当前接受规则不等于全部 tuple 的原生可汇编证明。
2. Ti16 raw S1Z4M11 编码与表53／表64的 transpose 差异没有公开资料唯一解。项目采用显式 decoded 整数传输，不能声称原始位编码已复原。
3. Ti16 sparse collector 的一处语法未列 metadata operand，与 sparse 章节冲突；实现保留真实 metadata 对象，不以零矩阵代替。
4. WS zero-column descriptor 表56的 skip/use 文字与示例方向存在差异；当前执行公开示例的 mask 序列，是明确项目选择。
5. shift 的方向／尾行没有官方索引伪代码。当前 `dst[r]=old[r+1]`、tail 保留有专利及 CUTLASS 使用序列支持，仍是项目消歧，未经过原生 GPU 测量认证。
6. 原生内部数值顺序、物理 MALU 数量及 Rubin 资源配比未由上述布局资料披露。`PROJECT_EXACT`、可参数化多MALU与本次单元检查不能证明设备逐位一致或峰值吞吐复刻。
