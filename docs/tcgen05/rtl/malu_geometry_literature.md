# MALU 数量与 M×N×K：论文、两份专利的几何证据复核

核验日期：2026-11-11。核验对象是已上传 PDF；没有重新联网。本记录不修改 RTL，也不把项目 REF/PERF 的资源配置写成 NVIDIA 硬件事实。页码均为 PDF 从 1 开始的物理页码；论文这些页的印刷页码与物理页码一致。

## 1. 可直接用于回答用户的结论

**这些来源没有确认“一个实际 Blackwell/Rubin Tensor Core 包含多少个项目定义的 MALU”，也没有确认该物理 MALU 的固定 M×N×K。** 它们分别给出了数值归约组、指令片段以及专利数据通路实施例，三者不能合并为一个未经披露的物理组织。

已确认的具体数值是：

| 层级 | 已确认数值 | 能确认什么 | 不能确认什么 |
|---|---|---|---|
| B200 数值归约模型 | FP16/BF16：16 项；TF32：8 项；原生 tcgen05 FP8：32 项 | 一个结果元素的乘积在何种分组边界规格化/舍入，见论文第 12、15 页 | 分组数不等于 MALU 数；项数不证明相同数量乘法器在同一周期工作 |
| 专利 partition 实施例 | 每 partition 32 datapath lanes | 专利明确披露的物理数据通路分区示例 | 不是 warp 数；不是已绑定第五/第六代 Tensor Core 的数量 |
| 专利完整 datapath 实施例 | 128 lanes，由 4 个 32-lane datapaths 组成 | 60938 第 54 页 [0108] 直接这样描述 | 不能自动命名成“4 MALU/Tensor Core”，也不能证明商品 SM 的内部划分 |
| 专利 lane 内部图 | 60938：2 AOp / 2 BOp / 2 Acc；77615：1 AOp / 2 BOp / 2 Acc | Fig.5A 中可直接读到的接口/累加器标注 | 不是完整矩阵几何定义；尤其不能把 2 AOp、2 BOp 直接视为 2×2 outer product，因为该图只标 2 Acc，且未定义各符号的容器、周期或 dot 长度 |
| 存储/搬运粒度 | 一个 activation element 可为 32-byte packed vector | 60938 第 54 页 [0110] 的示例 | 256 bit 的载荷不证明一次执行处理全部元素，更不证明每 lane 的固定 K=16/32/64 |

在项目坚持“MALU 是单结果向量 dot+C 单元”的定义时，可以把一个 **数值归约块** 写成 `1×1×K_group`，故上述 B200 观察对应 `1×1×16`、`1×1×8`、`1×1×32`。这是对单输出数学操作的记号，**不是已验证的物理 MALU M×N×K，也不是完整 tcgen05 指令形状**。如果用户要求实际硬件单元几何，当前证据的答案仍应写“未披露/未证实”，不能把该数学记号包装成硬件发现。

## 2. 论文证据：数值组长与片段，不是物理阵列计数

来源：Faizan A. Khattak、Mantas Mikaitis，《Accurate Models of NVIDIA Tensor Cores》，上传本 arXiv:2512.07004v3，2026-04-04，20 页。URL：<https://arxiv.org/abs/2512.07004>。本次使用上传 PDF 文本与原页定位；URL 仅为来源标识。

### 2.1 N_FMA 的明确定义

第 5 页 §2，在单输出表达式 `d = Σ p_l + c` 后定义：

> “the number of product terms … added in one go”

并用它表示 block fused multiply-accumulate 的大小 `N_FMA`，例子是 A100 FP16 的 `p1+…+p8+c` 在一次规格化/舍入下完成。

据此可以引用“单输出数值归约分组长度”，不能直接改称“并行 MALU 数”“每 Tensor Core 的 lane 数”或“每周期 MAC 数”。即便作者使用 “in one go”，该研究的方法是输出数值反推，未提供门级/RTL、时序拆分或乘法器实例计数。

### 2.2 B200 的具体数值

第 12 页 §4.1.7：

> “the FMA tile sizes are 16, 16 and 8, respectively.”

上下文分别是 FP16、BF16、TF32（论文称 tf19）输入和 FP32 输出。对于 `tcgen05.mma` 的原生 FP8 路径，该页又报告 `N_FMA=32`。第 15 页 Table 4 对应列为：

| B200 输入 → 输出 | N_FMA | Product alignment | Accumulator bits |
|---|---:|---:|---:|
| FP16/BF16 → FP32 | 16 | (2,25) | 32 |
| TF32 → FP32 | 8 | (2,25) | 31 |
| FP8 → FP32/FP16 | 32 | (2,25) | 33 |

图 5（第 13–14 页）标题明确称为 inner product 的 **model**。它给出的多个 Mult 方框是模型中的乘积节点；不能据此独立证明这些乘积节点一一对应同周期物理乘法器。第 15 页还说明软件 GEMM 使用递归算法，等效于反复用单个 tensor core 模型计算各 inner product；这描述的是建模方法，不是 GPU 的物理调度或实体数量。

### 2.3 片段形状与指令入口不能混淆

第 11 页 §4.1.6 的 TF32 例子：WMMA 的 `m16n16k8` 可以映射为 `m16n8k4` HMMA 片段，而直接 `mma.sync` 的 `m16n8k8` 路径得到 `HMMA.1688` 和更大的数值组长。第 14 页 Table 3 列出这些 CUDA/PTX 到 SASS 的实验映射。

这些是指令/编译映射的片段信息。不能把某个 SASS 名字中的 16、8、4/8 直接宣布成一个物理 MALU 的 M、N、K，也不能将旧 `mma.sync` 片段当作 `tcgen05` 硬件阵列几何。

第 11–12 页还区分 FP8 经 `mma.sync` 转换为 FP16 的交错两组路径与原生 `tcgen05` FP8 路径。若未固定入口，连数值分组也可能不同。

### 2.4 适用范围

第 12 页明确没有研究 FP6/FP4；第 14 页明确 DMMA 不在随机模型复现范围内。本文不能提供 Rubin、Ti16、block-scaled dot、各低精度模式物理 packing 的证据。这里的 32 不能外推为所有 FP8/FP6/FP4 都共用 32 个物理乘法器。

## 3. US20250060938A1：明确的数据通路实施例

标题：METHOD AND APPARATUS FOR DIRECT CONVOLUTION CALCULATION。NVIDIA；公开日 2025-02-20。URL：<https://patents.google.com/patent/US20250060938A1/en>。本次依据上传扫描 PDF 的局部 OCR，并直接查看 Fig.5A/5B 原图。

| 位置 | 原文短引/图内原标注 | 可以得出的结论 | 证据边界 |
|---|---|---|---|
| 第 52 页 [0088] | “one or more datapath processors 510” | 一个 SM 示例可包含一个或多个该 datapath processor | 没有给出每实际 SM 或每商品 Tensor Core 的定数 |
| 第 52 页 [0089] | “each comprises datapath processing circuitry 504” | lane 这里确实有对应数据通路处理电路，不能简单说它完全只是软件线程 lane | 仍未定义项目名 MALU 与 lane 的一一对应关系 |
| 第 52 页 [0093] | “comprises 32 datapath lanes 502” | 图示 portion/partition 有 32 个 datapath lanes | 该段明确以 illustrated embodiment 限定 |
| 第 53 页 [0094] | “the datapath comprises 128 datapath lanes” | 一个 example implementation 总共 128 个 datapath lanes | 同段说明图中小矩阵只是示意，不限制最大矩阵尺寸 |
| 第 54 页 [0108] | “a 128-lane datapath made up of 4 32-lane datapaths” | 该示例的物理分区关系确为 4×32 | 不是 4 个商品 Tensor Core，也不是直接证实 4 个用户定义 MALU |
| 第 11 页 Fig.5A | “2 AOp”, “2 BOp”, “2 Acc” | 图展示 lane 的输入与累计端标注 | 没有披露乘法器实例数、向量各项数量、精度或周期，因此不能推出 lane 的 M×N×K |
| 第 11 页 Fig.5B | lane 0…31；“32 AOp”, “2 BOp” | 一个分区有 lane 列表及广播/供数路径 | lane 图与分区图的 AOp 粒度不应机械相乘；该图不提供完整时序/载体定义 |
| 第 54 页 [0109] | “stacked along the A operand’s ‘GEMM_M’ dimension” | TMEM RAM 的组织沿 GEMM_M 提供行切片 | 这不是 GEMM_K 乘积项数量 |
| 第 54 页 [0110] | “a 32-byte vector … of packed values” | 一个被搬运/存储的 element 可本身是 packed 向量 | 不能用 256/元素位宽直接当该 lane 的同周期 dot 项数 |

### 3.1 专利中的字母 K 与 GEMM_K 不同

第 51 页 [0080] 明确说 K filters 对应 GEMM_N。第 54 页 [0118]–[0119] 将通道扩展写成：

`(M×C activations) × (C×K filters) → M×K outputs`。

因此映射为通用 GEMM 命名时是：

| 专利字母 | 数学含义 | 通用 GEMM 命名 |
|---|---|---|
| M | activation rows / output positions | M |
| C | input channels / dot reduction | K |
| K | output feature maps / filters | N |

这些是可变数学维度，不是每 lane 固定硬件尺寸。将“128-lane + K filters + 32-byte packed element”拼成物理 `128×K×32` 是无依据的。

### 3.2 权利要求不补足物理几何

独立权利要求 1 在第 69 页描述 “a plurality of processing lanes”、输入/输出存储、MMA、shift/reload 和累加，没有把 32/128 或某个 M×N×K 作为该独立权利要求的固定数量。第 66 页 [0248] 的 SM 背景也只说 “one or more tensor cores”。

## 4. US20250077615A1：weight-stationary 版本

标题：METHOD AND APPARATUS FOR WEIGHT-STATIONARY DIRECT CONVOLUTION CALCULATION。NVIDIA；公开日 2025-03-06。URL：<https://patents.google.com/patent/US20250077615A1/en>。依据上传扫描 PDF 的局部 OCR与原图。

| 位置 | 原文短引/图内原标注 | 可用结论 |
|---|---|---|
| 第 61 页 [0095]–[0096] | “one or more datapath processors 510”；每 lane 含 datapath circuitry | 是数据通路实施例，SM 内实例数未固定 |
| 第 61 页 [0100] | “comprises 32 datapath lanes 502” | 每 portion/partition 32 lanes；多个 portion 联接为 datapath processor |
| 第 62 页 [0106] | “the datapath comprises 128 datapath lanes” | 128-lane example implementation，与卷积数据复用映射一起描述 |
| 第 11 页 Fig.5A | **“1 AOp”**, “2 BOp”, “2 Acc” | 此图 AOp 标注不同于 60938 的 2 AOp，不能把两份专利图一概合并 |
| 第 11 页 Fig.5B | lane 0…31；“32 AOp”, “2 BOp” | 32-lane partition 的供数/广播示例 |
| 第 61 页 [0101]，第 12 页 Fig.5C | “tensor core state machine” 与 AGU/SMEM/XBAR/collector/replay buffer | 说明控制与供数结构，没有给每 MALU 固定 M×N×K |
| 第 62 页 [0105] | B 可每周期或每 p 周期接收新数据，p<n | 明确保留多种时分供数方式；不能自动假定每周期消费一个完整矩阵 K 片段 |
| 第 77 页 [0274] | “one or more tensor cores” | 通用 SM 背景没有补足具体 Tensor Core/MALU 个数 |

独立权利要求 1（第 80 页）重点是保持 weights vector 不变并执行 MMA 序列，使用 “a plurality of processing lanes”，没有限定 MALU 数量和单元形状。

## 5. 32、64、128 与 dotgroup16/32 的最终分类

- **32 physical datapath lanes/partition、128 physical datapath lanes/datapath**：在专利给定实施例中是明确的硬件组织描述，不能因为不是商品证明而抹去其物理含义。
- **4 partitions**：60938 [0108] 明确给出；只是该例中的分区组合数。没有证据把 partition 重命名为 MALU 或把整个 datapath processor 等同某代商品 Tensor Core。
- **64 physical MALUs/lanes**：本次已核验论文与专利核心数据通路段落中没有支撑此数值的证据；这里不声称已逐字检索两份扫描专利全部页面。
- **dotgroup16/32**：若指论文 N_FMA，是数值组长；若指 PTX block-scale vector size，是缩放分组；二者不能互代，也不是物理单元数。
- **TMEM 128 lanes**：属于 ISA 存储抽象时，不能因数值同为 128 就宣布与专利 lane/物理 MALU 一一对应。需要额外映射证据。
- **warp 32 threads / warpgroup 128 threads**：是执行参与者，不可与专利 32/128 datapath lanes 按数字相同直接等同。
- **M、N、K 指令形状**：是指令请求的矩阵运算范围；可以通过多周期、多片段和多个硬件单元执行，不直接确定单元物理 M、N、K。

## 6. 给当前项目与答复的建议

1. 若问题是“当前 WORD32_REF 集成有几个 MALU”，应直接由 RTL 实例化数量回答，并标为项目配置；不能说这就是 NVIDIA Tensor Core 的实际数量。
2. 若问题是“NVIDIA tcgen05 硬件实际有几个 MALU、每个 M×N×K 是多少”，当前三件来源只能报告上述已知层级，不能诚实给出唯一数字。
3. 如需继续设计，分别冻结 `NUM_DOT_ENGINES`、每引擎并行 output 数、每拍输入 product terms 数、每次任务 K、累加 contexts、数值归约组长和指令 M/N/K。它们是不同参数，不能全部由一个“lane”代称。
4. 要把候选物理组织提升为实际硬件结论，至少还需要明确代际的厂商资料或能约束吞吐、发射间隔、延迟、共享资源与格式 packing 的独立实验；只依赖数值模型或峰值 FLOP/s 不能唯一反推出阵列。

## 7. 本次实际审阅范围与复现材料

- 论文：全文文本检索，重点复核第 5、11–15 页；既有提取 `/workspace/output/malu/research/tensor_models.txt`，本次 layout 提取 `/tmp/geometry_tensor_models.txt`。
- 60938：核心说明第 51–54 页、Fig.5A/5B 第 11 页、独立权利要求第 69 页；另 OCR 复核 SM 背景第 64–66 页。
- 77615：核心说明第 61–62 页、Fig.5A/5B 第 11 页、Fig.5C 第 12 页、独立权利要求第 80 页；另 OCR 复核 SM 背景第 75–77 页。
- 先前已保留各核心页 OCR 与图 crop 于 `/workspace/output/malu/research/`；本次新增六页局部 OCR 于 `/tmp/malu_geometry_ocr/`。扫描 OCR 用于定位，图中数量已直接看原图，细节仍以原 PDF 为准。
- 没有逐字核验两份专利全部 151 页，也没有将“已核验页未找到”写成对所有公开资料的全局否定。

上传本 SHA-256：论文 `63588196a40b61d41c6f4b435ef97cc69a4c2906f4493878a792be52d9e78307`；77615 `88b73c778dd37f17abfccdb3878bd0b6e926d61544abdecdbaa999293f6682b4`；60938 `c92a6ddcf5986ce62daa2f7b4e8c71b575f24bd9aeee36faf84095d07e84a12f`。

## 8. 对汇总几何审计稿的独立复核

同日只读复核 `../research/TCGEN05_MALU_GEOMETRY_AUDIT.md`，并重新直接读取上传 PTX 9.4 的物理第 700–705 页：Table 50 全五页、Target ISA Note、搬运 shape。未发现基线表、MX 大 K 或 `.ws` 表中的阻断错误。特别核对了 i8 CTA1 的 N 步长转折、Ti16 按 M 区分 N 步长、MX CTA2 sparse 仅 M256、FP4 CTA2 大 K 仅 M256、`.ws` 禁止 CTA2，以及 K96/K64/K128 的 target 条件。

非 MX f8f6f4 跨页合并单元格的 N 列 OR 与 K64 类型脚注，汇总稿已保留联合组合尚未闭合的边界；本次没有运行汇编器或硬件，不能把表文阅读写成全笛卡尔积可汇编/执行验证。

论文组长、专利物理实施例与商品 Tensor Core 数量之间的分界正确；两份 Fig.5A 的 AOp 标注差异保留准确。未发现把 Rubin 等同某个 SM target 编号的表述。补查源码/网络过程由主 agent 提供记录，本次独立复核不声称重复执行其网络获取。

已向主 agent 提出两项措辞澄清：吞吐关系 `count×K_slice/II_dot` 需限定一次 invocation 消费单个 slice 并产生一个输出，否则应分别定义 `II_slice` 与完整 dot 的 `II_dot`；`2MNK` 对整数使用 OPS 口径，对浮点使用 FLOPs 口径。这不是物理阵列已获证实，也不是任何 RTL/性能验收结论。
