# PTX ISA 9.4：Matrix / Dot MALU 已核验研究记录

负责人：agent1（tcgen05 / 矩阵与点积语义）。本文只研究 Matrix ALU 的向量点积，不纳入标量 ALU、标量 FMA 或 SFU，不编写 RTL。

## 1. 原件与引用口径

- 已实际读取用户上传的 `/workspace/attachments/4971c15f-29fd-4875-95d3-ed0c693d3482/ptx_isa_9.4.pdf`，并用 `pdftotext -layout`、PyMuPDF 文本提取及关键表格页面渲染交叉检查。
- 封面：**PTX ISA, Release 9.4, NVIDIA Corporation, Jul 17, 2026**；PDF 共 1002 个物理页。
- 原件 SHA-256：`4be2905e240b70a8b176b4d6fb162714f2fc361a9503572d848ff723abf289c3`。
- 下文“PDF页”均为阅读器从 1 开始的物理页；“印刷页”为原文页脚。正文相关页满足 PDF页 = 印刷页 + 12。
- 证据级别：**[ISA]** 为已读原文；**[推导]** 为从原文范围/公式计算；**[项目选择]** 为建议的本项目实现，不能写成 NVIDIA 已公开的内部结构。

## 2. 最重要的核验结论

1. **[ISA]** tcgen05 算术关系为 `D = A×B + D`，输入累加使能为假时为 `D = A×B`。本项目使用正式独立输入 C，写成 `D = dot(A,B) + C`，由外层适配器将 PTX 输入 D 映射成 C，不能丢掉 C。（§9.7.18.10，PDF755/印743；§9.7.18.10.10.1，PDF827/印815。）
2. **[ISA]** tcgen05 是异步矩阵操作，单线程发射即启动整项运算；不是要求全 warp 同时执行的 `mma.sync`，也不是 `wgmma.mma_async`。（PDF827/印815。）
3. **[ISA]** tcgen05 的 `.kind::ti16` 实际输入类型名为 **`.s1z4m11`**，不是 `e1z4m11`。原文将其定义为 16-bit signed integer，范围 `[-2^11+1, 2^11−1] = [-2047,2047]`；输出/累加格式为 `.s32`。（§9.7.18.4.2，表53，PDF724–725/印712–713。）
4. **[ISA]** PTX 的 tcgen05 章节没有给出 `.s1z4m11` 负数的完整逐 bit 编码；不能仅凭名称画成 sign-magnitude、普通二补码 s16、FP16 或“1位指数+4位零+11位尾数”。名称纠正、取值范围、descriptor 编码是确定证据，输入编码转换仍需独立权威依据。
5. **[ISA]** tcgen05 表50没有 FP64、INT4 或 B1 运算行；这些格式出现在较早 `mma` 家族，不能据此宣称 tcgen05 支持它们。完整 FP32 乘数输入也不同于 TF32 乘数输入。（表50 PDF700–704/印688–692；较早 mma §9.7.16.5.14，PDF586–589/印574–577。）
6. **[ISA]** scale 格式与元素格式是不同字段；UE8M0、UE4M3、UE5M3 不能混成一种“FP8 scale”。块大小也不能由 FP4/FP8 元素位宽直接推断。（§5.2.3，PDF54–55/印42–43；表71 PDF782/印770。）
7. **[ISA]** 官方 tcgen05 descriptor 中 A/B scale 共享同一个 Scale Matrix Type 字段。本项目可以保留独立的 A/B scale-fmt 请求字段，但不同值的组合属于项目扩展，不能宣称直接对应原生 tcgen05 tuple。（表54、55，PDF725–726/印713–714。）
8. **[ISA]** block16 不是所有 matrix kind 都合法：表71中只在 `.kind::mxf4nvf4` 有该组合；`.kind::mxf4` 和 `.kind::mxf8f6f4` 为 block32。（PDF782/印770。）
9. **[ISA]** `scale-input-d` 是输入累加值的 `2^(−s)` 缩放，s∈[0,15]，仅 `.kind::tf32`、`.kind::f16` 合法；不是 A/B microscaling 的另一个名称。（PDF827/印815。）
10. **[ISA]** 表53与表64对 Ti16 transpose 存在可见不一致；表70的 K128 特例与其 fallback 字面重叠。下文明确列出，不能静默假定已经解决。
11. **[ISA]** 旧 mma/wgmma 的精度段落不能不加说明移植为 tcgen05 的逐 bit 数值保证。PTX 字段、论文实测和项目数值约定必须分层。

## 3. tcgen05 矩阵数据格式矩阵

来源：§9.7.18.2.1 表50，PDF700–704/印688–692；§9.7.18.4.2 表53–55，PDF724–726/印712–714；§9.7.18.10，PDF755/印743。

| kind | A/B 元素类型 | 原生累加/输出 D | A/B scale | 备注 |
|---|---|---|---|---|
| `.kind::f16` | F16 | F16 或 F32 | 无 block scale | BF16 不能直接套入 D=F16 行 |
| `.kind::f16` | BF16 | F32 | 无 block scale | descriptor A/B type 均有 F16/BF16 编码；全组合许可不能替代具体 shape 校验 |
| `.kind::tf32` | TF32 | F32 | 无 block scale | TF32 不是完整 FP32 精度乘数 |
| `.kind::f8f6f4` | E4M3、E5M2、E2M3、E3M2、E2M1 | F16 或 F32 | 无 block scale | §9.7.18.10 明说支持 f8/f6/f4 的全部输入组合；扩展 K 有格式/架构条件 |
| `.kind::mxf8f6f4` | E4M3、E5M2、E2M3、E3M2、E2M1 | F32 | UE8M0 | block32；没有 `.ws` 行 |
| `.kind::i8` | S8、U8 | S32 | 无 block scale | A/B signedness 有独立编码；饱和控制只在该 kind 的表53有效 |
| `.kind::mxf4` | E2M1 | F32 | UE8M0 | block32；没有 `.ws` 行 |
| `.kind::mxf4nvf4` | E2M1 | F32 | UE8M0、UE4M3、UE5M3 | block16/block32；有架构门限 |
| `.kind::ti16` | S1Z4M11 | S32 | 无 block scale | PTX9.4 新增；sm_107f 同 family 及以上 |

### 3.1 与本项目独立 AB/C/D format 配置的关系

**[项目选择]** 接口可保留 `ab_fmt`（或独立 a_fmt/b_fmt）、`c_fmt`、`d_fmt`、`a_scale_fmt`、`b_scale_fmt`、`block_cfg`、`dot_len`。字段独立不等于其笛卡尔积全部合法。legalizer 至少输出 `native_tcgen05`、`legacy_matrix`、`project_extension`、`illegal` 四种分类或等价状态。

原生 tcgen05 对累加输入与输出使用同一 TMEM D 格式，没有通用独立 C-format 字段。用户要求的独立 C/D 格式由本项目明确转换位置、内部精度和输出舍入，作为项目能力描述；不能倒写成 PTX 原生承诺。FP64/INT4/B1 若纳入“全部 matrix/dot 格式”，也应标成 legacy matrix profile，而非 tcgen05。

## 4. 精确格式与特殊值：能从该 PDF 确认到什么程度

来源：§5.2.3，PDF54–55/印42–43。

| 格式 | 原文确定内容 | 不应额外臆定 |
|---|---|---|
| BF16 | 16 bit，8 exponent，7 mantissa；register `.b16` | 不能把内部累加格式等同于输入格式 |
| E4M3 | 8 bit，4 exponent，3 mantissa；无 Inf；NaN 仅 0x7f/0xff | 不把所有 exponent=all-ones 一律当 Inf/NaN |
| E5M2 | 8 bit，5 exponent，2 mantissa | 特殊值传播仍需所选操作规范 |
| TF32 | 32-bit special format，范围同 F32，精度≥10 bit；**内部布局 implementation defined**；register `.b32` | 不声称 PTX 规定固定的 1+8+10 物理位域，也不套用 wgmma 的具体截断规则到 tcgen05 |
| E2M1 | 4 bit，2 exponent，1 mantissa；无 Inf/NaN；通用 packed e2m1x2 用 `.b8` | matrix 的 packing 仍需按具体 kind/内存路径 |
| E2M3 | 6 bit，2 exponent，3 mantissa；无 Inf/NaN | matrix 不总是每元素 8-bit 容器 |
| E3M2 | 6 bit，3 exponent，2 mantissa；无 Inf/NaN | 同上 |
| UE8M0 | 8-bit unsigned，8 exponent，0 mantissa；无 Inf；NaN=0xff | 本节未给出的 bias/zero 数值不在此凭名字补出 |
| UE4M3 | **7-bit unsigned**，4 exponent，3 mantissa；`.b8` 的 MSB 填0；无 Inf；NaN=0x7f | 不是带 sign 的完整 E4M3；不能接受任意 bit7=1 的 scale byte |
| UE5M3 | **8-bit unsigned**，5 exponent，3 mantissa；无 Inf；NaN=0xff | 不是 E5M2；UE5M3 是9.4新增的 scale 类型 |

仅依靠本 PDF 的上述定义不足以写出所有自定义类型的完整 bias/边界数值表。若文档提供此表，必须再引用明确规定编码的权威格式规范，并列出计算方式，而不是将习惯性编码当作本 PDF 明示内容。

## 5. Ti16：可确定的 descriptor、范围、位宽推导及缺口

### 5.1 确定证据

- **[ISA]** 名称 `.kind::ti16`，A/B `.s1z4m11`；16-bit signed integer，范围 `[-2047,2047]`。（PDF725/印713。）
- **[ISA]** 表53：dtype[5:4] 编码 S32=2；atype[9:7] 编码 S1Z4M11=3；btype[12:10] 同类格式编码；saturation bit3 对 ti16 为 `0 (NA)`。（PDF724/印712。）
- **[ISA]** dense K16、sparse K32；non-ws CTA1 的 M64 配 N=8..256步8，M128 配 N=16..256步16；CTA2 的 M128或256，N=32..256步32。ws只支持 CTA1，M32/64/128，dense N64/128/256、sparse N64/128。（表50末页 PDF704/印692。）
- **[ISA]** `.kind::ti16` 从 PTX9.4 引入，要求 sm_107f 或同 family 更高目标。（§9.7.18.10.10.1，PDF829–830/印817–818；ws 对应 PDF839–840/印827–828。）

### 5.2 从范围推导的项目整数宽度预算

- **[推导]** 最大单项乘积绝对值为 `2047² = 4,190,209`，数学值可容纳在 23-bit signed 中。
- **[推导]** K16、C=0 的最大 dot 绝对值为 `67,043,344`，27-bit signed 足够；K32 对应 `134,086,688`，28-bit signed 足够。
- **[推导]** 任意 S32 输入 C 加入后仍可能超出 S32，不能因为短 dot 自身不溢出就删除累加溢出处理。
- **[项目选择]** 内部保留额外 carry，再依据明文规定的项目策略打包为 S32；不得把旧 mma 的 `.satfinite` 当成 ti16 的合法原生字段。

### 5.3 不可伪装已解决的两处问题

1. **输入 bit encoding**：本 PDF 只给类型名、容器位宽、数学范围与 descriptor 编码，没有说明负数逐 bit 编码。设计文档应使用“已解码数学整数”的路径画法，不画猜测字段；RTL 输入解码规则须有额外来源或被明确标为项目协议。
2. **Ti16 transpose 不一致**：表53 PDF724/印712 的 ti16 transpose A/B 只写 `No Transpose = 0`，而表64 PDF757/印745 给 ti16 的 transpose support=`Yes`。本版不能把二者当作无歧义。该差异属于文档核验项，与 MALU 内部 dot 数值计算独立；矩阵 transpose 可由外层喂数序列处理，但不能把此实现选择写成已确认的 tcgen05 descriptor 行为。

## 6. Block scaling 的合法 tuple 与运行时配置

### 6.1 数学语义

**[ISA]** §9.7.18.10.7，PDF774/印762：

`D = (A × scale_A) × (B × scale_B) + D`。

scale_A 为 `M×SFA_N`，按 A 的各 row 沿 K 划分 chunks；scale_B 为 `SFB_M×N`，按 B 的各 column 沿 K 划分 chunks。两组 scale 驻留 TMEM。该语义不是“最后只乘一个总 scale”；跨多个 block 时每个部分点积需对应其自己的 A/B scale。

**[项目选择]** 使用独立 C 输入可写为：

`D[j] = convert_d(C[j] + Σ_g (scaleA[g] × scaleB[g]) × Σ_(k in group g) A[k]×B[k])`。

该式只表达实数数学关系；内部舍入位置、scale 中间值精度和特殊值优先级另立数值契约，不能从实数分配律推出浮点逐 bit 等价。

### 6.2 确认的类型/块配置合法表

来源：§9.7.18.10.7.1 表71，PDF782/印770。

| kind | 元素格式 | Scale 格式 | 合法 block 选择 | 额外架构条件 |
|---|---|---|---|---|
| mxf8f6f4 | E4M3/E5M2/E2M3/E3M2/E2M1 | UE8M0 | block32（scale_vec::1X 的相应布局） | shape/K 另查表50 |
| mxf4 | E2M1 | UE8M0 | block32（scale_vec::2X 的相应布局） | shape/K 另查表50 |
| mxf4nvf4 | E2M1 | UE8M0 | block16 或 block32 | shape/K 另查表50 |
| mxf4nvf4 | E2M1 | UE4M3 | block16 或 block32 | **UE4M3+block32 要求 sm_107f 或同 family 更高** |
| mxf4nvf4 | E2M1 | UE5M3 | block16 或 block32 | **UE5M3 要求 sm_107f 或同 family 更高** |

项目可以允许 runtime 改变 block16/32，但每个请求必须通过上述 tuple 与目标 profile 检查。不能因为 block 字段独立，就宣称 E5M2+UE4M3+block16 是 tcgen05 原生组合；项目若要实现它，应明确标记扩展模式。

### 6.3 Scale count、K 与稀疏口径

表70 PDF781/印769直接列出：

| 配置 | 原文列出的 K 情况 | Scale_A / Scale_B shape |
|---|---|---|
| scale_vec::1X，mxf8f6f4 | 所有支持 K | M×1 / 1×N |
| scale_vec::2X，mxf4或mxf4nvf4 | 所有支持 K | M×2 / 2×N |
| scale_vec::4X，mxf4nvf4 | 所有支持 K | M×4 / 4×N |
| block16，mxf4nvf4 | K96 | M×6 / 6×N |
| block16，mxf4nvf4 | K128 | M×8 / 8×N |
| block32，mxf4或mxf4nvf4 | K96 | M×3 / 3×N |
| block32，mxf4或mxf4nvf4 | K128 | M×4 / 4×N |

K64 的常用 block32/16 分别需要2/4个 scale。§9.7.18.10.7.4–.5（PDF783/印771）同时以 K64/K128 为标题分别给出2/4个 scale；§.7.8（PDF787/印775）以 K128/K256 为标题给出8个 scale。后者涉及 dense/sparse 的维度口径，不能把压缩行长度与数学 logical K 混为同一个计数器。

**文档差异记录**：表70 block16/32 的 K128 专门行与其“all supported values of K except96”fallback 有字面重叠；PDF828/印816 的历史 alias 描述也不能取代 K128 新增行。应在适配层显式保留 `logical_K`、`packed_K`、`block_elems`、`scale_count` 和布局 profile，并针对指定 shape 逐项回查图布局。不要在接口上把 block16 永久编码为“恰好4个scale”，或 block32 永久编码为“恰好2个scale”。

### 6.4 Descriptor 的 scale 类型编码

- **[ISA]** `.kind::mxf8f6f4`：表54 bit23 为 A/B 共用的 scale type，UE8M0=1。（PDF725/印713。）
- **[ISA]** `.kind::mxf4/.kind::mxf4nvf4`：表55 bits24:23 为 A/B 共用 scale type；UE4M3=0、UE8M0=1、UE5M3=2。mxf4 只允许 UE8M0=1。（PDF726/印714。）
- **[ISA]** `.kind::mxf4` 未显式写 scale_vectorsize 时默认 block32；`.kind::mxf4nvf4` 必须显式给出。（PDF828/印816。）

## 7. 矩阵 shape 约束摘要：不能等同于物理 dot lane 数

来源：§9.7.18.2.1 表50，PDF700–704/印688–692。以下仅为 non-ws 基本口径；M/N 矩阵 tile 由外层分解为若干 dot，不能直接宣称芯片有 M×N 个物理结果通道。

| kind | 基本 dense K / sparse logical K | 常见 CTA1 shape 限制 | 扩展项 |
|---|---|---|---|
| f16 | 16 / 32 | M64或128，N8..256步8 | CTA2 M128/256、N步16 |
| tf32 | 8 / 16 | M64或128，N8..256步8 | CTA2 M128/256、N步16 |
| f8f6f4 | 32 / 64；扩展64 / 128 | M64/128；扩展 K 有 M/N 与类型条件 | denseK64 的输入仅 E4M3/E5M2（表50注） |
| mxf8f6f4 | 32 / 64；扩展64 / 128 | M128；N8..256步8 | CTA2 的 M/K 组合限制，见原表 |
| i8 | 32 / 64 | M64/128；N={8,16,24,32,48,…256} | N>32后步16；CTA2 N步32 |
| mxf4 / mxf4nvf4 | 64 /128；另有96 /192；dense扩展128 | M128；N8..256步8 | CTA2 M128/256，扩展K关联M256 |
| ti16 | 16 / 32 | M64：N步8；M128：N步16 | CTA2 N步32 |

§9.7.18.2.1.1（PDF704/印692）明确：K96仅 sm_103a、sm_107a；f8f6f4/mxf8f6f4 的 dense K64/sparse K128 需要 sm_107f 同family更高；mxf4/mxf4nvf4 的 dense K128/sparse K192 扩展也有 sm_107f 门限。此处 table50、K96 特定目标与后续扩展 note 应一并检查，不可只看单行。

`.ws` 仅 CTA1；f16/tf32/f8f6f4/i8/ti16有 ws 行，mxf8f6f4/mxf4/mxf4nvf4 的 ws 行是 Invalid。ws 的 M32/64/128、dense N64/128/256 与 sparse N64/128 也不应直接借用于普通 tcgen05。

## 8. 稀疏语义与元数据

来源：§9.7.18.10.9–.9.3，PDF816–818/印804–806。

- **[ISA]** tcgen05.mma.sp 的数学 A 为 M×K，物理压缩存储为 M×(K/2)，每行50%为零；元数据映射回数学位置。
- **[ISA]** TF32 是 **1:2**，不是泛称的2:4；有效4-bit metadata值仅 `1110`、`0100`，其余 undefined。
- **[ISA]** f16、ti16、f8f6f4、mxf8f6f4、i8 是 **2:4**。PDF817/印805 列出的4-bit值为 `0100,1000,1100,1001,1101,0110,1110`。这是原文七项，不能凭熟悉的六种“任取两位置”擅自删掉末项；需要后续按对应硬件目标核验该特殊值。
- **[ISA]** mxf4、mxf4nvf4 是 **4:8 且成对成组**：每8个元素包含4个非零值，按2元素子组决定整组零或整组非零。不能将其误做任意4-of-8或一般2:4。
- **[ISA]** 表55 sparsity version 位12：sm_100a/sm_103a/sm_110a 要 v0，sm_107a 要 v1，否则 undefined。（§9.7.18.4.2.1，PDF727/印715。）

**[项目选择]** 稀疏索引解码与向量展开在 MALU 前端或矩阵适配层；数值阵列只消费选定乘积与对应的 block/scale 映射。不要在“dense吞吐”数字中混用 sparse 等效运算量。

## 9. Packing：格式位宽不等于总线 stride

来源：§9.7.18.10.4.1–.6，PDF759–763/印747–751。

- **[ISA]** D 的 subword 元素不在一个32-bit TMEM word中紧凑打包；例如 F16 D 只占该 word低16位。（PDF759/印747。）
- **[ISA]** `.kind::mxf8f6f4` 的 TMEM A packing 在表68按 dense K 和类型区分：FP4为8-bit container（K32）；FP6可为6-bit container（K64）或带2 padding的8-bit container（K32）；FP8为8-bit container（K32）。
- **[ISA]** 同 kind 的共享内存4/6bit元素连续打包，dense K32每16元素后需要padding，dense K64不需要。（PDF762/印750。）
- **[ISA]** `.kind::mxf4/.kind::mxf4nvf4` 每两个 E2M1 放入一个 byte，SMEM无需padding。（PDF763/印751。）
- 较早 mma 的 f8f6f4/mxf8f6f4 则有 E2M1 位于 byte中央4bit、上下各2bit padding等规定（PDF589/印577）；不能跨家族照抄。

## 10. 数值精度与舍入：明确区分指令家族

### 10.1 较早 `mma` 的原文

§9.7.16.5.14，PDF589/印577：

- F16乘法至少single precision；C或D为F32时累加至少single，均为F16时至少half。
- FP8/FP6/FP4乘法为 specified precision，累加至少single。
- BF16/TF32乘法为 specified precision，累加至少single。
- 上述相关运算的累加顺序、舍入及输入subnormal处理 **unspecified**。
- F64 multiply/add 精度同 F64 fused multiply-add，支持 `.rn/.rz/.rm/.rp`，默认 `.rn`。
- 整数 mma 使用S32累加器；`.satfinite` 溢出clamp到S32范围，否则wrap。

这些是本项目 legacy matrix profile 的原文依据，不是许可把标量 FMA 纳入 MALU 操作集。

### 10.2 `wgmma` 的原文及区别

§9.7.17.5.2，PDF677–678/印665–666：类似精度叙述；其中 TF32 明确先截断32-bit输入低13位。另有注释：E4M3/E5M2、D=F32 的 **current implementation** 累加精度高于half但低于single。该注释必须连同家族与限定词引用，不能改写成所有 Tensor Core/所有代际的共同硬件位宽。

### 10.3 tcgen05 能确认与不能确认的部分

已检查 §9.7.18（PDF699–846/印687–834），尤其 §9.7.18.10 的 types/descriptor/运算描述。该节给出输入/输出类型、缩放、数据路径布局、同步等规则，但没有提供一个能直接照搬的、类似旧 mma 的完整 `Precision and rounding` 段落。

因此本设计文档应分开写：

1. **PTX明确保证**：类型/合法tuple、实数运算关系、输入累加使能、scale输入、合法矩阵维度等。
2. **论文/设备观测**：由其他agent从论文和指定GPU提取，注明代际、型号与指令，不能推广到tcgen05。
3. **本项目确定性策略**：中间乘积位宽、对阶、加法树或分段归约、保护位/round/sticky、舍入、NaN/Inf、FTZ/渐进下溢、溢出、signed zero与C转换规则。必须标项目选择，并用参考模型验证。

尤其不能写“tcgen05规定每次IEEE单精度FMA、每项RNE、固定从左到右累加”，也不能写“PTX规定所有Tensor Core都RTZ”。

## 11. tcgen05 与矩阵前端的边界及完成语义

- **[ISA]** §9.7.18.10，PDF755/印743：A可在TMEM或SMEM，B在SMEM，D在TMEM；稀疏metadata和scale在TMEM。
- **[ISA]** 单线程发射的tcgen05仍可协同执行于CTA组；cta_group::1在本CTA，::2在本CTA与peer CTA。kernel内全部tcgen05使用同一cta_group值。（PDF827/印815。）
- **[ISA]** §9.7.18.6.1–.2.3，PDF732–734/印720–722：mma/cp/shift/ld/st是异步操作；不能把“发射成功”当作“完成”。
- **[ISA]** mma/cp/shift 通过 tcgen05.commit 与 mbarrier等待观察完成；ld/st 通过 tcgen05.wait::ld/st等待。`tcgen05.wait::ld`不是对mma的通用完成等待。（PDF734/印722。）
- **[ISA]** 相同cta_group、accumulator、shape和kind的mma序列存在规定的pipeline顺序关系；其他依赖需显式等待/同步。（PDF733/印721。）
- **[项目选择]** MALU只提供dot请求/响应以及错误状态；TMEM分配、矩阵descriptor、CTA协同、collector、屏障在外壳。`valid/ready`握手应清楚区分accept和complete，C作为每请求正式输入，并随请求tag跨流水携带。

## 12. 其他 matrix/dot 格式来源，不能冒充 tcgen05

| 家族 | 原文支持的相关格式/操作 | 证据 |
|---|---|---|
| mma.sync | F16、BF16、TF32、FP8及FP8/6/4混合、相应block scale、F64 | §9.7.16.5.14，PDF586–589/印574–577 |
| mma.sync整数 | S8/U8、S4/U4，S32 C/D；bitop+popc的B1输入与S32 C/D | 同上；B1不是普通整数乘法 |
| wgmma.mma_async | F16、BF16、TF32、E4M3/E5M2，I8与对应S32累加 | §9.7.17.5.2；具体合法组合仍按该家族表格，不继承tcgen05 |
| dp4a | 4个8-bit乘积+32-bit C；A/B各用32-bit容器；signedness分别选择 | §9.7.1.24，PDF171–172/印159–160 |
| dp2a | 2个16-bit A与2个8-bit B点积+32-bit C；B低/高半部选择 | §9.7.1.25，PDF172–173/印160–161 |

dp4a/dp2a的C：仅当A/B都unsigned时为U32，否则S32。这可用于补足项目“dot格式”研究，但它们不是 tcgen05 Tensor 指令，不应被用于推导 Rubin Tensor 峰值。

## 13. 算力配比与验证建议

**[项目选择]** 对每种模式列出 `P_dot_results_per_cycle`、`K_terms_per_result`、II、latency、频率、dense/sparse口径、scale配置。按常见MAC=2 ops的统计：`ops/s = 2 × K × P_dot_results_per_cycle × f_clk`；若II>1，P必须是平均完成率或额外除II。这个统计约定不意味着MALU包含标量FMA功能。

PTX格式支持不等于Rubin实际各格式峰值比，不能从表50的K值直接得出“FP4:FP8:FP16”的硬件吞吐比。

最低有意义验证集合：每种合法tuple、非法tuple与无副作用拒绝；C非零与C=0；跨block scale变化；block16/32切换；Ti16±2047及C邻近S32边界；特殊值/次正规数；dot取消抵消与舍入边界；稀疏metadata及packed_K映射；accept/complete backpressure/tag一致性。精确位比较采用项目数值契约；NVIDIA拟合结果另作设备级对照。

## 14. 为文档撰写与画图准备的原文截图

同目录已生成关键源页PNG，名称为 `ptx_page_701.png`、`ptx_page_702.png`、`ptx_page_703.png`、`ptx_page_704.png`、`ptx_page_724.png`、`ptx_page_725.png`、`ptx_page_726.png`、`ptx_page_781.png`、`ptx_page_782.png`。可用于人工复核和有限原文图例；主设计图应明确标为本项目建议架构。
