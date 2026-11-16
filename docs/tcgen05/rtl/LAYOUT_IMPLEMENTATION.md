# tcgen05 legalizer 与布局地址生成实现

实现与独立核查：2026-11-15。对应 `tcgen05_legalize.sv`、`tcgen05_layout_pkg.sv`；不把地址生成单元的测试称为整端、GPU或PPA验证。

## 接口与真实行为

`tcgen05_legalize` 接收不可变cmd、显式feature capabilities和strict_isa，输出状态及normalized_cmd。normalizer独立保留AB格式、scale格式、scale语法模式、BLOCK16/32、C shift；按表70产生scale_count，而不是把所有形式套入一个ceil公式。strict模式核表50形状与类型；canonical小矩阵测试和原生shape覆盖分别记录。owner/generation、完整访问footprint和在途责任由endpoint检查。

`tcgen05_layout_pkg` 提供以下公共函数，结果含对齐word地址、位偏移、peer、bad：

- `tc_byte_access`、`tc_tmem_access`、`tc_flat_tmem`、`tc_word_advance`。
- `tc_smem_access(desc,row,col_bits,k_major,element_bits)`：表49/51的relative/absolute LBO、SBO、pattern base-offset、no/32B/64B/128B swizzle、128B with32B atomicity。
- `mma_a_access(cmd,m,stored_k,n)`、`mma_b_access(cmd,k,n)`、`mma_d_access(cmd,m,n)`。
- `mma_meta_access(cmd,m,group,n)`、`mma_scale_a_access`、`mma_scale_b_access`、`mma_lut_access`。

WORD32_REF采用历史flatten word传输；CANONICAL采用明确packed/byte/word容器和stride；NATIVE采用规定descriptor与A–G TMEM layout。两端cmd的A/metadata/scaleA/D按M半区、B/scaleB/LUT按N半区路由，peer与发令CTA奇偶异或。CANONICAL不附加native的N-lane展开。native Layout B、E、G同时改变lane和局部N column，不仅改lane。

原生D的F16结果每TMEM word占低16bit，不能将两个结果打包进同一word。SMEM里的LUT index为3bit；desc.bit53选择48B K128压缩块的前/后24B。scale ID是byte偏移，跨word后的plane步长为A32布局4列、B布局按N≤128／N>128选择4／8列。A128-lane scale布局使用实际row作为lane。

FP6跨word需要真实下一片段地址：例如no-swizzle K-major、LBO256B时，bit126元素从byte12的bit30开始，剩余位位于byte256而非byte16。AGU在 `next_word_valid/next_byte_addr` 记录第二word地址，`tc_word_advance` 据此重定向；不将物理byte+4当成所有native布局的逻辑下一word。

## 规范与官方源码对照

- 上传PTX9.4 PDF700–705：表50 shape、target与move shape。
- PDF714、722：canonical shared-layout、descriptor字段、base-offset与relative/absolute LBO。
- PDF759–770：容器packing、原生D非packed、布局A–G及lane alignment。
- PDF783–811：scale-A/B、ID、32/128lane与跨列plane。
- PDF812–815：LUT每8列共享8候选值、两列TMEM。
- PDF819–823：metadata选择和F16/TF32/Ti16交错nibble／lowp行布局。
- NVIDIA CUTLASS `include/cute/arch/mma_sm100_desc.hpp`、`include/cute/atom/mma_traits_sm100_frag.hpp`：canonical swizzle形式和fragment layout交叉核对。
- `include/cute/atom/copy_traits_sm100.hpp`：正式4DP copy trait证明cp4目的lane为base+{0,32,64,96}；其Src/Dst stride是logical-refresh坐标，不能当作SMEM物理row步长32。

本次公开源码实际取自GitHub raw；快照位于ignored build/tcgen05/layout_research。它们是交叉证据，规范基准仍是上传9.4，而非假定最新CUTLASS覆盖9.4全部tuple。

## 实际测试

`tb_tcgen05_layout.sv` / `tb_tcgen05_layout.f` 实际Verilator仿真：

`TCGEN05_LAYOUT_PASS checks=825662 native_outputs=409600 layouts=7`

包括七种native layout、两种issuer奇偶、全M/N输出逐点比较与唯一word检查，canonical pair独立M/N路由、F64旧flatten、absolute/relative LBO、swizzle/baseoffset固定地址、metadata/scale/LUT原图点、跨atom下一word、非法位／溢出拒绝。该单元只运行组合地址函数，不把409600输出点说成409600次MMA执行。

`tb_tcgen05_legalize.sv` / `tb_tcgen05_legalize.f` 实际仿真：

`TCGEN05_LEGALIZE_PASS checks=166`

覆盖Table50主要基线与大K、i8/Ti16 N步长、WS/pair冲突、ashift/LUT、全部move语法边界、scale aliases及独立target capability。shift、exclusive、scale-input-d、legacy scale_vec、block qualifier门限各有disabled测试。新增检查确认scale_vec1X/2X独立导出BLOCK32，native元素block offset必须为0；scale data ID仍为独立字段。终审补齐1/2/3/4/6/8个scale对应的两侧ID合法集合、canonical B count溢出以及transpose+ashift预拒绝。没有用decode/合法化通过代替执行功能通过。早期单元报告97／102项对应旧快照，最终central报告的166项与源码hash为当前基准。

## 仍需精确保留的规范边界

以下不是函数空stub；它们是原件存在冲突或未披露的行为，必须与项目选择并列，不能包装成已在某款GPU验证：

1. 表50非MX f8f6f4大K跨页共享M/N及OR单元格，尚未在每个target汇编全组合。legalizer按表列形状与显式dense K1条件接受；未称所有tuple可汇编。
2. Ti16 raw内部编码与表53／表64的transpose差异没有由公开材料唯一消除。本项目MALU采用显式decoded整数传输；规范化接口的数学transpose可执行，不冒称原始位编码已逐bit复原。
3. Ti16 sparse collector语法一处未列metadata operand，与sparse章节有冲突；实现保留metadata对象，不删成零矩阵。
4. WS zero-column descriptor表56列说明与示例的skip/use span命名存在反向；MMA按公开示例的mask序列执行，测试和文档需记录该选择。
5. shift “down”无伪代码；结合专利C0..C3→C1..C4及官方cp4刷新tail的操作序列，当前算法为保留tail、dst[r]=old[r+1]。这是有来源的项目消歧；此前反方向推论已修正，不能反称原文写了伪代码。
6. 原生内部数值顺序、物理MALU数量和Rubin资源配置并非这些布局资料披露的内容。当前PROJECT_EXACT及可参数化array是项目实现，不借本测试宣称硬件逐bit／吞吐复原。

地址单元本身已经没有仅为未实现正常recipe而设置的default-bad分支；bad用于非法descriptor、非法shape／index、地址越界或不被该操作支持的组合。整端是否完整、全部功能是否通过，以central runner和逐功能状态记录为准。
