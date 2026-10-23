# MALU 文献与专利核验记录

研究角色：agent2。核验日：2026-10-23。范围：MALU 是 Matrix ALU，仅执行向量点积加正式输入 C；此记录不扩展任何标量指令范围。本文中的 PDF 页码均为从 1 开始的物理页码，避免与专利说明书页码混淆。

## 1. 证据等级与读取方法

- **论文观察**：作者对特定 GPU 和指令入口的实验与软件模型；不是 NVIDIA 官方 RTL，也不是 PTX 对所有实现的保证。
- **专利披露**：分别标明具体实施例和权利要求。某幅专利图不能证明某代商品 GPU 必然使用该实现。
- **工程建议**：由本项目选择，不能写成已获文献确认的 NVIDIA 实现。
- **未覆盖**：所核验材料不能证明的事项，必须由 PTX 9.4 原文或进一步实验补足。

论文有文本层，已使用 PyMuPDF 提取全部 20 页文本。两份专利为扫描 PDF，已对首页、核心实施例、权利要求做局部 Tesseract OCR；并查看原页/图页校验标题和图号。没有声称已经逐字核验专利全部 151 页。OCR 原始输出在本目录保留，细节以原 PDF 为准。

## 2. 论文：《Accurate Models of NVIDIA Tensor Cores》

### 2.1 身份与适用范围

- 作者：Faizan A. Khattak、Mantas Mikaitis；University of Leeds, School of Computer Science。
- 上传版本：arXiv:2512.07004v3，2026-04-04；PDF 第 1 页明确版本日期。
- 原文入口：https://arxiv.org/abs/2512.07004 。本次依据上传 PDF 阅读，而非假设网页内容与上传本相同。
- 作者软件：MATLAB Tensor Core v0.4.1，https://github.com/north-numerical-computing/MATLAB-tensor-core ；该 URL 由论文第 1 页给出。本次未执行该模型。
- 论文正文第 3 页 §1.2 列出 V100、A2、A30、A100、H100、H200、L40S、Ada RTX 1000、B200 的研究，31 个格式/输出模型组合。第 12 页 §4.2 说明 FP6/FP4 不在随机验证范围内；第 14 页还说明 DMMA 不在随机模型复现范围。
- 不支持把实验结果推广至 Rubin、Ti16、所有 block-scale 模式、所有编译器路径。

### 2.2 与点积直接相关的证据表

| 证据 | 原文位置 | 已核验内容 | 对 MALU 的意义与边界 |
|---|---|---|---|
| 运算定义 | 第 4–5 页 §2，式 (1) | 一个矩阵结果元素写成 d = Σ(a_l b_l) + c | 正式 C 输入属于点积输出定义；不需要引入外部标量运算指令 |
| 分组与对阶定义 | 第 5 页 §2 | 多项浮点求和可先按最大指数对阶，再经 compressor/加法树，在分组边界规格化与舍入；作者用 N_FMA 表示一个分组中的乘积数 | 设计正文可称“点积归约分组长度”，引用时说明论文原符号，不能把它当成 PTX 指令形状 K 的同义词 |
| 同一数学乘积也可能产生不同后续截断 | 第 7–8 页 §4.1.1、Fig.2 | V100 中 1.5×1.5 与 1×2.25 的未规格化乘积表示不同；配合小乘积时可产生不同输出 | 若要复现作者 profile，不能先把每个乘积规格化成统一已舍入浮点数，再简单相加 |
| 不同代际内部精度不同 | 第 15 页 Table 4 | V100、Ampere、Hopper/Blackwell 的对阶位数、归约分组长度和内部累加位数不同 | 把这些数值写成 profile 参数，不可写成通用 ISA 硬约束 |
| C 改变极小乘积对阶行为 | 第 9 页 §4.1.2；第 11 页 §4.1.6 | 作者观察到 bf16/tf19 极小乘积时，C=0 与 C 为非零次正规数的对阶指数下限分别涉及 −133 与 −126 | C 不是可随意放在归约后端的独立普通加数；复现 profile 时需按作者路径建模 |
| 指令入口决定所测路径 | 第 11–12 页 §4.1.6–4.1.7；第 14 页 Table 3 | 相同 FP8 输入经 mma.sync、Hopper wgmma、B200 tcgen05，可到达不同转换/硬件路径 | 必须固定 GPU、PTX 入口、编译及 SASS 证据，不能只按 ABfmt 选择数值 profile |
| B200 原生 FP8 路径 | 第 12 页 §4.1.7；第 15 页 Table 4 | tcgen05.mma 的 f8f6f4 类仅以 FP8 做数值测试；group=32、对阶 (2,25)、内部累加 33 位；FP32 输出最终 Trunc，FP16 输出最终 RNE | 可作为 B200 FP8 实验 profile 的来源；不是 FP6/FP4/Ti16 的证据 |
| 特殊值与验证范围 | 第 6 页 §3.2、第 12/14 页 §4.2 | 正态/均匀随机、目标次正规区间、NaN/Inf 等测试，作者报告与对应硬件逐位一致；也明确输入空间无法穷尽 | 不把随机匹配描述成形式证明。异常值处理仍要与目标指令合法类型核对 |

### 2.3 可供正文引用的模型参数

下表照录第 15 页 Table 4 的对应项目，并保留其“数值模型”属性。`(2,f)` 表示未规格化数值对阶时的 2 个整数位和 f 个小数位；内部累加位数并不等于最终结果格式的有效数位数，也不能仅凭此推导物理加法器单元数。

| 输入/输出 | 实验对象/入口类别 | 对阶 (integer,fraction) | 内部累加位数 | 点积归约分组长度 | 最终处理 |
|---|---|---:|---:|---:|---|
| FP16→FP32 | V100 | (2,23) | 28 | 4 | Trunc |
| FP16/BF16→FP32 | A100/A2/A30、L40S/Ada | (2,24) | 30 | 8 | Trunc |
| TF32（论文称 tf19）→FP32 | A100/A2/A30、L40S/Ada | (2,24) | 29 | 4 | Trunc |
| FP16/BF16→FP32 | H100/H200/B200 | (2,25) | 32 | 16 | Trunc |
| TF32（论文称 tf19）→FP32 | H100/H200/B200 | (2,25) | 31 | 8 | Trunc |
| FP8→FP32 | L40S/Ada 原生路径 | (2,13) | 20 | 16 | Trunc |
| FP8→FP32 | H100/H200 原生路径 | (2,13) | 21 | 32 | Trunc |
| FP8→FP32 | B200 tcgen05 原生路径 | (2,25) | 33 | 32 | Trunc |

作者 Table 4 将上述 FP8→FP16 对应最终模式列为 RNE。TF32 的“tf19”是论文自己的数值格式简称，第 4 页 §2 明确其为 TensorFloat32，不能因此把承载寄存器位宽写成 19 位。

### 2.4 特别需要避免的误读

1. 第 4 页 Table 2 虽列出 FP6/FP4 的格式参数，不能因此声称这些运算模型已验证；第 12 页明确未研究它们。
2. 第 10 页末至第 11 页对 H100 对阶位宽的叙述先出现 26，随后解释未规格化整数位后使用 (2,23,2)=27；正文引用时采用 Fig.5 与 Table 4 的清晰表示 `(2,25)`，不传播前一句的模糊表达。
3. 第 11 页指出 FP8 经某些 mma.sync 入口被转换为 FP16，再有交错分组与 C 的后加路径；不能将该路径作为 B200 原生 tcgen05 FP8 的统一结构。
4. 论文中的 truncation 应按作者对应数值模型理解，不可无依据替换成任意 IEEE 舍入模式或为本项目所有格式指定同一策略。

## 3. 专利 US20250077615A1

### 3.1 身份

- 标题：**METHOD AND APPARATUS FOR WEIGHT-STATIONARY DIRECT CONVOLUTION CALCULATION**。
- 申请人：NVIDIA Corporation。
- 申请号：18/458,638；申请日：2023-08-30；公开日：2025-03-06。均见物理第 1 页。
- 第 55 页 [0001] 明确关联申请 18/449,381，即另一份上传专利对应申请；这种关联不能把两件权利要求合并为同一范围。
- 公开号入口：https://patents.google.com/patent/US20250077615A1/en 。本次证据来自上传扫描 PDF 的局部 OCR 和原页检查。

### 3.2 实施例与权利要求分列

| 性质 | 位置 | 核验内容 | MALU 关联 |
|---|---|---|---|
| 实施例概述 | 第 57 页 [0049]–[0054] | D=A*B+C；一次结果 D 可成为下一次 C。通过 peer shift、参数化 copy 等减少卷积供数重复 | 支持分块结果回馈 C 的集成背景；不规定点积内部舍入 |
| 数据流实施例 | 第 61 页 [0093]–[0094]，Fig.4（第 10 页） | weights 固定在物理 stationary A-input；activations 在 B-input 流入，通过 local/replay buffer 与滑窗复用 | 可供操作数 collector/replay 接口设计；不需要将卷积地址生成塞进纯点积 MALU |
| lane 与存储实施例 | 第 61 页 [0095]–[0100]，Fig.5A/5B（第 11 页） | 多 lane，每 lane datapath circuitry；寄存器 collector、可选 auxiliary/TMEM、共享 activations bus；32-lane partition 与 128-element 组合为示例 | 可借鉴 lane 分区与 collector，不能声称 PTX 强制 32/128 个物理 lane |
| 控制/供数实施例 | 第 61 页 [0101]–[0103]，Fig.5C（第 12 页） | datapath state machine→AGU→SMEM→crossbar/transpose；A collector、B local buffer、column select；A stationary，B 每时钟供数 | 宜在文档框图区分外部供数控制与 MALU 点积核心 |
| stationary 时长 | 第 62 页 [0105] | A collector 可保持 n 周期；n 与结果 tile 的 N 维有关 | 是该实施例的复用策略，不是 MALU 数值格式约束 |
| **独立权利要求 1** | 第 80 页（说明书第 26 页） | 两个输入接口、输入/输出存储、多 processing lanes；将 weights 保持不变，执行 MMA 序列并累加到输出存储 | 权利要求技术重点是 weight-stationary 执行与数据流 |
| 从属权利要求 2、4、5 | 第 80 页 | shift 部分 activations，补入新元素，再执行另一 MMA 序列；shift/copy 指令 | 供数复用机制；不是浮点乘法/归约微结构规范 |
| 独立方法权利要求 18、20 | 第 81 页 | weight-stationary MMA 序列、移动/补入 activations、累加结果 | 与权利要求 1 同属数据流与操作序列层面 |

### 3.3 边界

这些已核验段落和图没有给出 Ti16 编码、精确乘积/累加位宽、归约树、舍入、FTZ、scale_fmt 或 block16/32 的合法表。不要将“专利披露一个 MMA datapath”扩大成“已公开所有数值后端实现”。本专利文字的符号矩阵 A/B 与物理 A-input/B-input 还可能使用不同命名上下文；本项目应以自有接口规范消除歧义。

## 4. 专利 US20250060938A1

### 4.1 身份

- 标题：**METHOD AND APPARATUS FOR DIRECT CONVOLUTION CALCULATION**。
- 申请人：NVIDIA Corporation。
- 申请号：18/449,381；申请日：2023-08-14；公开日：2025-02-20。均见物理第 1 页。
- 公开号入口：https://patents.google.com/patent/US20250060938A1/en 。本次证据来自上传扫描 PDF 的局部 OCR 和原页检查。

### 4.2 实施例与权利要求分列

| 性质 | 位置 | 核验内容 | MALU 关联 |
|---|---|---|---|
| 运算与复用概述 | 第 49 页 [0045]–[0050] | D=A*B+C；peer transfer/UTCSHIFT、参数化 UTCCP 供数 | 对 C 回馈、供数路径给出集成背景 |
| 存储数据流实施例 | 第 52 页 [0086]–[0092]，Fig.4（第 10 页）、Fig.5A/5B（第 11 页） | activation 驻留 TMEM/collector，weights 通过 SMEM/bus 供数；TMEM 可为 auxiliary RAM | 与 weight-stationary 专利形成“驻留哪一侧”的设计对照；不能把两个驻留策略都当成同一实现的必选项 |
| lane 实施例 | 第 52 页 [0093]–第 53 页 [0094] | 32-lane partition，可组成 128-lane 例子，结果列与 lane 关联 | 仅是示例，不是 PTX 矩阵 shape→物理单元数的推导依据 |
| 滑窗实施例 | 第 53–54 页 [0102]–[0106]，Fig.6A（第 12 页） | 已加载 activations 在邻接 lane/TMEM 间 shift，只补入缺少的新元素；概念上的列移动可能对应实际图像的行移动 | 提醒格式无关的 layout/索引应由外部展开，不应与 ABfmt 混成一层控制 |
| 指令实施例 | 第 54 页 [0108]–[0116] | UTCSHIFT 可跨整个 datapath 或限定子分区；UTCCP 可全向量或局部补入；UTCMMA 做 TMEM activations 与 SMEM filters 的 dot；bitmask 可抑制特定输出写入 | 为 lane mask、输入有效性及复用接口提供线索，不能直接等同本项目 tail-element mask |
| 向量点积映射 | 第 54 页 [0117]–[0119] | 单通道可扩展成 1×C 与 C×1 的点积，再扩展到多个输出 feature maps 的矩阵乘法 | 与 MALU 仅负责单个向量 dot+C 的边界直接对应 |
| **独立权利要求 1** | 第 69 页（说明书第 23 页） | 用驻留 first vector 执行 MMA，shift 后保留其子集并补新元素，再执行下一序列，结果累加进输出存储 | 核心保护叙述在复用/shift/补入/MMA 的组合，不是数值归约细节 |
| 从属权利要求 3、4 | 第 69 页 | 每 lane 存储关联、改变关联、shift/copy 补入空位 | 数据移动结构 |
| 独立方法权利要求 17、19 | 第 70 页 | 前述序列的系统方法/数据通路方法表述 | 不能以它们推断商品 GPU 的数值 backend |

## 5. 对项目的可执行结论

### 可采用的工程架构建议（项目自定）

1. 将操作数供数、layout、滑窗、地址生成与纯 dot+C 核心分开。专利的 collector、replay buffer、lane 分区是外部供数集成的候选，不是本版 MALU 必须实现完整卷积。
2. 数值后端至少明确：输入解码、并行乘积、对阶/归约、C 参与位置、最终规格化/舍入/截断，以及跨 block 的累加边界。
3. 建立独立 numeric profile：目标 PTX 合规语义、项目确定性实现、特定 B200 指令入口实验复现。不能只凭同一 ABfmt 认定三者等价。
4. 使用论文的定向测试方法设计相消、极小乘积、C=0/非零次正规、交错归约位置敏感的验证；随机结果匹配之后仍保留所有发现的回归向量。
5. ABfmt、scale_fmt、block16/32 分开编码，但只有 PTX 合法组合表中的组合才可接受。独立字段不意味着任意笛卡尔积合法。

### 与 agent1 的 PTX 9.4 核验交叉对照

agent1 已在同目录 `ptx_findings.md` 给出 PTX 9.4 精确证据：§9.7.18.4.2、表 53，PDF 724–725/印刷页 712–713，正式名为 **`.s1z4m11`**，而非用户最初写的 e1z4m11；是 16-bit signed integer，数学范围 `[-2047,2047]`，输出/累加 `.s32`。本记录的三件文献没有补足该格式负数的逐 bit 编码，因此不能依据名称猜成 sign-magnitude、普通二补码 s16 或浮点格式。

agent1 还核验了 scale types 与 block 大小的合法表，本记录不重复其完整表；设计正文应交叉引用该文件的 PTX 页码，而不是把这些内容归因于本论文/专利。

### 仍须补足的数值证据

- Ti16 `.s1z4m11` 的逐 bit 解码方程、负数/零编码与输入转换依据。格式名、容器宽度、数学范围与 S32 累加已有 PTX 证据，不能继续全部标为未知；bit 编码缺口仍不能猜测。
- 所有整数格式和 mixed signedness 合法点积组合；完整乘积、累加截断或饱和的位置。
- block scale 的 scale 编码、向量分组索引、16/32 分组语义，以及缩放发生在乘积之前、乘积之后还是某个归约层次。
- 各目标组合的 FTZ、NaN/Inf、舍入、特殊控制位与合法 C/acc/dst 格式。

## 6. 提取产物与溯源

- `tensor_models.txt`：论文全文文本及物理页分隔。
- `patent_77615_front.txt`、`patent_60938_front.txt`：专利首页 OCR。
- `patent_77615_ocr_selected.txt`：物理第 55–62、79–81 页 OCR。
- `patent_60938_ocr_selected.txt`：物理第 47–54、68–70 页 OCR。
- 各页 `*_ocr_p*.txt` 与对应 PNG 供复核。
- 原图局部 `source_patent_77615_fig5ab.png`、`source_patent_77615_fig5c.png`、`source_patent_60938_fig5ab.png`、`source_patent_60938_fig6a.png` 仅用于少量技术图讨论；文档插入时需保留公开号、图号和物理页码。

上传 PDF SHA-256：

| 文件 | SHA-256 |
|---|---|
| Accurate Models of NVIDIA Tensor Cores.pdf | 63588196a40b61d41c6f4b435ef97cc69a4c2906f4493878a792be52d9e78307 |
| US20250077615A1.pdf | 88b73c778dd37f17abfccdb3878bd0b6e926d61544abdecdbaa999293f6682b4 |
| US20250060938A1.pdf | c92a6ddcf5986ce62daa2f7b4e8c71b575f24bd9aeee36faf84095d07e84a12f |
