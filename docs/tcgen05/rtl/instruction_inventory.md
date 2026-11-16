# PTX 9.4 tcgen05 功能清单与 legalizer 合同

日期：2026-11-11。依据用户上传 `ptx_isa_9.4.pdf`，SHA256 `4be2905e240b70a8b176b4d6fb162714f2fc361a9503572d848ff723abf289c3`。页码为物理PDF页，印刷页码通常减12。此清单枚举功能类别与独立控制维度，不把类别数写成opcode数，也不把每种modifier的笛卡尔积都认定合法。

## 1. 完整指令族

| 功能族 | 必须实现的功能／变体 | 原件位置 |
|---|---|---|
| alloc | group1/group2、blocking容量等待、共享内存返回TMEM地址、exclusive/nonexclusive、32-column粒度、申请列数不增加 | §9.7.18.7.1 PDF738–741 |
| dealloc | matching base/count/exclusive、group2 collective、在途访问排除后释放 | 同上 |
| relinquish_alloc_permit | 放弃后续申请许可，保留现有allocation | 同上 |
| ld | 全五种shape、x1..x128合法重复、warp-quarter权限、全RF片段写回ack | §9.7.18.8.3 PDF742–746 |
| ld.pack::16b | 相邻columns的两个16bit chunk拼成b32 | PDF742/745 |
| ld.red | min/max、F32/S32/U32、abs、NaN传播、每lane跨column归约 | PDF743–746 |
| ld.spcompress | F32、32x32b、x4..128、2:4、b2索引、min/max选择、abs、NaN保留 | 同上 |
| ld.red.spcompress | 同时生成compressed data、metadata、reduction；NaN修饰只控制reduction | 同上 |
| st | 全五种shape、x1..x128合法重复、完整源捕获、全部TMEM写ack | §9.7.18.8.4 PDF746–748 |
| st.unpack::16b | b32的两个16bit chunk分别写相邻columns | PDF742/747 |
| wait::ld/st | warp collective、各自先前stream cutoff；不追踪MMA/cp/shift | §9.7.18.8.5 PDF748–750 |
| cp | 全五种copy shapes、group1/group2、warpx2两种配对、warpx4、b4x16_p64/b6x16_p32展开 | §9.7.18.9.2 PDF751–753 |
| shift.down | 隐式31x256b、32对齐lane、32-byte片段沿row滑动、group1/group2、防覆盖；方向消歧见布局实现说明 | §9.7.18.9.3 PDF753–754 |
| mma | dense、SMEM/TMEM A、SMEM B、独立kind/type/shape、enable-input-d、disable-output-lane、scale-input-d | §9.7.18.10.10.1 PDF823–830 |
| mma.block_scale | mxf8f6f4/mxf4/mxf4nvf4、独立scale类型、scale_vec1X/2X/4X与BLOCK16/32、TMEM scale矩阵 | 同上，§9.7.18.10.7 PDF780–781 |
| mma collector | A/B的fill/use/lastuse/discard；源仍须在MMA完成前保持合法 | PDF824–829，PDF756 |
| mma.ashift | A来自TMEM、M128/256、禁止同时A fill/use，实际移动A数据 | PDF828–829 |
| mma.decompress::lut::b | 3bit SMEM index→TMEM LUT中E4M3值；8-column slice共享8候选值、禁止B transpose及layout B/C/F | PDF826–830 |
| mma.sp | 全kind的structured sparse A、metadata位置恢复、TF32 1:2、普通2:4、MXFP4成对4:8 | §9.7.18.10.10.2 PDF830–837；§.10.9 PDF816–822 |
| mma.ws | group1、B collector b0..b3、zero-column-mask-desc、dense F16/TF32/f8f6f4/i8/Ti16 | §9.7.18.10.10.3 PDF837–840 |
| mma.ws.sp | ws与sparse组合、B collector、zero-column mask及metadata | §9.7.18.10.10.4 PDF840–842 |
| fence before/after_thread_sync | 与core执行顺序桥接；不是给出一个无副作用立即完成的空命令 | §9.7.18.11.1 PDF843–844 |
| commit normal/restricted | 捕获同thread/group的MCS或SMEM-A cutoff，异步mbarrier arrive count1，事件不依赖后续正常命令credit | §9.7.18.12.1 PDF844–846 |
| commit multicast | cluster同offset多个mbarrier、16bit默认mask或显式16/32bit mask、每目标恰一次 | 同上 |

## 2. Move 组合约束

`num` 是2的幂，范围1..128。每个thread的base register个数：32x32b、16x64b、16x32bx2为num；16x128b为2num且num≤64；16x256b为4num且num≤32。最大128个b32/thread，即warp共4096个b32，必须有完整片段输送／返回协议。

16x32bx2第二访问的base是 `taddr+immHalfSplitoff`。pack/unpack是两个16bit chunk与一个b32之间的位布局操作，不调用浮点转换。

普通ld.red只允许32x32b或16x32bx2且num≥2。abs/NaN修饰只适用于F32，integer仅S32/U32。spcompress只允许32x32b、F32、num∈{4,8,16,32,64,128}；每thread metadata寄存数为ceil(num/32)，compressed data为num/2。red.spcompress中的min/max、abs也用于压缩选择，但NaN只控制reduction，压缩始终保留NaN。

cp shape64x128b必须指定warpx2::02_13或warpx2::01_23；32x128b必须warpx4，其余shape不允许这些multicast组合。低位展开目标为b8x16，源b4x16_p64或b6x16_p32；不能把展开当作数值转FP8。

## 3. MMA 必须独立保留的维度

- `kind`：f16、tf32、f8f6f4、mxf8f6f4、i8、mxf4、mxf4nvf4、ti16。
- A/B精确格式、D格式；block-scale开关、scale格式、scale修饰模式；C shift分别控制。
- instruction M/N/K、逻辑K、压缩A的stored K、metadata索引、scale矩阵维度互不代替。
- dense/sparse、normal/ws、group1/group2、SMEM/TMEM A、negate/transpose、collector动作、ashift、LUT、output-disable和zero-column mask分别解释。
- non-ws output-disable是TMEM lane mask：group1四个b32，group2八个b32；ws zero-column-mask-desc影响B值，不能复用为D写使能mask。
- `.ashift`只M128/256并且A来自TMEM；与A collector fill/use非法。collector默认为discard，显式use/lastuse需要对应fill有效；即便允许复用，源仍可能被硬件重读。
- LUT B仅E4M3、不能transpose；LUT base two-column对齐，不能用于layout B/C/F。mxf8f6f4 LUT组合仅block32。
- 每kernel的CTA group固定。单thread发令不等于只处理一个warp数据。

## 4. Shape 与 scale 的规范入口

完整M/N/K见[几何核查](../research/TCGEN05_MALU_GEOMETRY_AUDIT.md)。strict legalizer须按表50检查，不把project测试的小M/N自动称为native shape。

特别注意表70的scale语法：mxf8f6f4 scale_vec1X／block32给M×1与1×N；mxf4／mxf4nvf4的scale_vec2X固定两列／行，mxf4nvf4 scale_vec4X固定四列／行。block32 K96对应3、K128对应4，其余表列2；block16 K96对应6、K128对应8，其余表列4。dense/sparse、alias与scale布局需按recipe解释，不能统一用ceil(logical K/block)推导全部原生形式。

## 5. Target capability 不做数值大小比较

| 功能 | 原件Target ISA Notes的重要限制 |
|---|---|
| base alloc/ld/st/wait/cp/fence/commit | sm100a、旧sm101a→sm110a，以及注明的100f/110f family forms；逐指令notes求交 |
| exclusive alloc | 9.4新增；family notes及target容量共同检查 |
| ld.red | 不与base ld完全同集合；原文列110a、110f、103f等 |
| ld{.red}.spcompress | 仅sm107a |
| shift | 列架构专属100a/101a(110a)/103a/107a/110a，不自动继承base family集合 |
| i8 MMA/ws/sp | 仅列架构专属100a/101a(110a)/110a，不能继承相邻float family集合 |
| Ti16 | 107f或同family后续 |
| B collector／LUT B | notes列sm107f；与kind、shape等联合求交 |
| scale-input-d | kind f16/tf32；target另按100a与100f family条件 |
| scale_vec1X/2X/4X | 原文列100a语法门限 |
| block16/32 | 原文列100f／110f语法门限 |
| UE5M3、UE4M3+block32 | 107f或同family后续 |
| FP8/MXFP8大K | dense64/sparse128：107f同family后续 |
| MXFP4大K | dense128/sparse192：107f同family后续；K96另列103a/107a |
| restricted commit、32bit multicast mask | 107f同family后续 |

capability位来自已批准target配置，不能由“sm版本数字更大”自动置位。内部规范化功能验证与原生target合法化应记录为不同模式；未验证的原生tuple不应通过宽松模式悄然加入native覆盖分母。

## 6. 验证证据要求

每个功能类别至少要有实际合法行为、边界、错误组合拒绝、回压稳定和生命周期检查。opcode被decode、返回OK、或只检查manifest都不等同功能通过。group2还需双端实际数据与原子资源协议；commit multicast需检查每目标实际事件责任。实际执行结果见[RTL实现与功能映射](RTL_IMPLEMENTATION.md)及central回归报告；本清单不是所有合法tuple的穷举证明。
