# MALU 工程示意图说明

本目录提供随文档发布的工程图与生成器；生成器不执行 Git 操作，也不代表已有 RTL 实现。各图均为本项目拟议架构，不是 NVIDIA 原始架构图，不代表已逆向确认的 NVIDIA 微架构。

所有 PNG 为 **2400 × 1320 像素**、白底，宽高比约 **1.82:1**，使用 Noto CJK 字体。按 **17 cm** 宽插入文档时，图中最小字体等效约 **9.04 pt**；同时提供文字转路径的 SVG，便于无字体环境使用。生成器为 `generate_figures.py`。

| 图片 | 建议图题 | 要点 |
|---|---|---|
| `01_malu_dot_datapath.png` | 纯向量点积 MALU 数据通路 | 正式 A/B/C 输入和 D 输出；A/B/C/D 格式、scale 数据和格式、块配置分离。C 每事务按 profile 纳入一次；跨拍累加状态保持。 |
| `02_block_scale_groups.png` | K=64 时 BLOCK16 与 BLOCK32 分组 | A/B 均 offset=0，示例中两侧块长相同；BLOCK16 为四组，每组16元素；BLOCK32 为两组，每组32元素。A/B 每组各一个独立 scale。 |
| `03_transaction_and_backpressure.png` | 描述符、数据拍与结果事务 | 接收 descriptor+C，分拍接收 A/B，必要时更新 scale，完成后输出 D+tag。图的列表示阶段，不表示周期数；允许省略的中间拍。 |
| `04_throughput_and_bandwidth.png` | 资源、有效吞吐与最低带宽关系 | 区分 P_peak=L_f/II_f 与有效平均 P_f=P_eff=ηP_peak，定义2P_f MAC计数及每DOT最低位数；通用图中保留符号 r_f，已核验模式数值另见图 5，绝对规模 S 独立决定。 |

## 接口与数值边界

- **仅向量 DOT**：单输出/事务，不提供标量 FMA、SFU 或通用 ALU 接口。
- A/B 的原始数据格式、C/D 格式、A/B scale 格式及 BLOCK16/32 配置分别描述；独立字段不意味着所有组合都合法。仍需通过已核验的合法 profile 筛选。PTX 官方 A/B scale-format 共用字段；对应的原生 tcgen05 profile 必须检查项目 `a_scale_fmt == b_scale_fmt`，混合两种 scale format 不能宣称原生合法组合。
- 块长16/32表示**元素数**，不是字节数、周期数、总线位宽或物理 lane 数。图2仅展示两侧块长相同的情况；不取消接口的独立配置。
- K 从0到K−1，全事务连续；偏移 offset 是首元素在首个涉及缩放块内的位置。启用时，逻辑元素 k 的 scale 索引为 `floor((offset+k)/block_len)`，输入 scale 数据从首个涉及块开始。禁用缩放时不计算块索引；块长和 offset 须在事务开始校验。
- 图3采用最简无跨块拍：每拍有效元素数同时受剩余 K、A/B 载荷容量及两侧下一块边界限制。新块所需 scale 与数据配对完成后，才接受该拍。反压期间有效载荷保持、k 不变。
- BLOCK16/32 可运行时选择，但同一在途事务内配置冻结；数值归约和舍入规则不随总线切拍改变。
- C 是正式输入，每事务锁存并纳入一次；**不预设 C 必须最后才加**，纳入时机和数值处理按已核验 profile 定义。
- 浮点内部精度、归约顺序、乘积和部分和的舍入点均由 profile 明确。图中最终 `round / pack` 不能解释为整个 DOT 只有一次舍入。整型仅执行适用的截断、溢出或饱和规则。
- 输出 `valid=1 && ready=0` 时，D 与 tag 保持。单上下文基线在结果消费前不接收下一事务；由此造成的空隙必须计入持续吞吐。
- Ti16 不画猜测位域。研究 agent 核验 PTX 名为 `.s1z4m11`，A/B 为16-bit受限有符号整数，数学范围 [-2047,2047]，D=S32；具体 raw-bits 负数编码不由本图推断，图中不以用户早期名称 `e1z4m11` 画格式布局。

## 吞吐公式适用范围

- `P_f` 是模式 f 的有效平均 products/cycle，对应正文 `P_eff=ηP_peak`；`P_peak=L_f/II_f`，L_f 为每issue乘积数，II_f为issue间隔。它不是物理乘法器个数，可以为非整数平均值；固定 K 时，DOT/cycle=`P_f/K`，统一 MAC 计数为 `2P_f ops/cycle`，不再重复乘η或除II。各项开销根据定义只计入II或η一次。
- Rubin格式比率映射标称 `P_peak,f=S*r_f`；不能把运行时反压后的P_eff直接当成Rubin标称峰值比率。
- 理想无重复 scale 传输时：`B_in=K(s_A+s_B)+s_C+N_A*s_scaleA+N_B*s_scaleB`；`B_out=s_D`。启用缩放时 `N_X=1+floor((offset_X+K−1)/block_len_X)`；禁用时 `N_X=0`，要求K>0。
- 各 s 表示实际传输位宽，A/B 的 slot 位宽不能用有效数值精度替代。协议元数据、握手开销、总线填充及重复传送不计入最低值，真实预算应加上这些成本。
- 图4为节省空间以 `s_SA/s_SB` 表示 A/B scale 传输位宽，`o_X/L_X` 表示该侧 offset/block_len。
- 64-bit A/B 各自独占一拍/周期时，必要条件为 `P_f*s_A<=64`、`P_f*s_B<=64`，并非充分条件；scale、归约、累加、响应端口和事务 II 可能成为限制。
- dense 与 sparse 分开；实际非零产品数和 dense-equivalent 算力分别报告。图未填写 Rubin 数值、未推导硬件 lane 数，也未声称理想位宽比例等于 NVIDIA 硬件吞吐比例。

## 复现

在具有 Python、matplotlib 及 Noto CJK 字体的机器运行：

`python /workspace/output/malu/figures/generate_figures.py`

生成器会检查盒内文字尺寸；PNG/SVG 在同目录覆盖重建。输出目录之外不写项目源文件。

## 图 5：Rubin dense 模式配比

官方单 GPU TF32/FP16-BF16/FP8-FP6 Training/NVFP4 Training = 2/4/17.5/35 PFLOPS（dense），归一化为0.5/1/4.375/8.75。50 PFLOPS NVFP4 inference 为 sparse，未纳入 dense 图。出处为 NVIDIA Vera Rubin NVL72 产品页脚注²/³，访问2026-10-23；这是产品峰值参考而非本项目实测。
