# tcgen05首版RTL：ISA实施清单与独立审查基线

> 历史审查基线，保留当时的建议和推论。当前实现以 [RTL_IMPLEMENTATION.md](RTL_IMPLEMENTATION.md) 和 [LAYOUT_IMPLEMENTATION.md](LAYOUT_IMPLEMENTATION.md) 为准。第4节的反方向shift推论已撤回：当前采用 `dst[r]=old[r+1]`、tail保留的有来源项目消歧。旧WORD32串行engine不在交付filelist中；正式top使用可配置多MALU并发、native/canonical地址生成与双端服务。本文早期“尚未运行”不表示最终central回归状态。

日期：2026-11-11。状态：实施前规范清单；尚未据此宣称新RTL通过。只读既有架构、微架构和固定PTX9.4源；本文件不修改既有文档，也不替主agent冻结首版capability/profile或端口位宽。

## 1. 来源优先级与实施范围

- 固定上传PTX9.4为原生语义来源；12个tcgen05说明节有14个标题名称，同节ld另含red/spcompress形式，不能以标题计数代替全部合法tuple。
- [Tensor架构](../TCGEN05_TENSOR_ARCHITECTURE.md) L27–48、L108–123、L149–176、L451–498：target、参与者、资源与完成合同。
- [Tensor微架构v1.1](../microarchitecture/TCGEN05_TENSOR_MICROARCHITECTURE.md) L64–132、L293–371、L480–572：项目实现与反压/生命周期约束。其队列深度、bank、PERF-S1砖数是项目设计，不是PTX强制物理组织。
- [PTX审查](../research/ptx94_architecture_audit.md)：保留target差异、Ti16编码/transpose及shape/source歧义，不用猜测关闭缺口。

首版可以是REF串行数据通路，但应明确入口是原始PTX字段译码、已合法化的规范化命令，还是更窄的项目测试接口。后两者不能宣称已完成PTX取指/汇编/native二进制译码。未编码并验证的layout/shape/target/alias/peer recipe应在任何越权访存或结果写入前明确拒绝，不能无声接受或返回伪成功。

## 2. 首版接口必须保留的合同

| 接口/状态 | 必需内容与不变量 | 来源文件/行 |
|---|---|---|
| 命令admission | opcode/form、完整issuer身份、CTA/warp/thread及动态collective实例、owner/generation/epoch、group、完整不可变描述符/配置；handshake后不得重读被覆盖的源寄存器 | 微架构L64–79、L86–104 |
| ready/valid | 受阻时payload/tag/owner稳定；一次握手对应一次责任；超时不允许静默重发带副作用事务 | 微架构L482–493 |
| 顺序ticket | 同issuer动态顺序在admission确定；commit/wait/fence捕获此前已接受工作的cutoff，不被CQ重排或后发操作改变 | 微架构L96–104、L513–519 |
| 资源与访问身份 | allocation record保存base/count、CTA/pair owner、generation、exclusive与live refs；地址值不构成权限。bitmap回收不得早于全部访问/返回引用关闭 | 微架构L136–158、L273–291 |
| SMEM接口 | owner-relative byte offset与完整range，经可见范围检查后只翻译一次owner base；descriptor swizzle由指定层一次应用，tensor map独立 | 微架构L174–187、L215–227；架构L133–141 |
| TMEM接口 | 32bit地址按lane/column解释；每cell32bit；read response与真实write ack各有token/fragment/generation。容量profile不因物理存得更多就默认开放 | 架构L129–147；微架构L136–172 |
| RF传输 | ld目的片段和所有权完整，源st寄存器捕获前受保护；RF写入ack不等待软件wait或consumer先运行 | 微架构L330–334、L488–489、L525–527 |
| barrier事件 | 完整barrier offset/目标owner/mask、事件身份及ack；commit产生规定arrive-one，不复制D。外部agent ack必须代表规定的真实barrier更新，而非只入普通队列 | 微架构L492、L515–521；架构L490–498 |
| MALU | 明确复用现有PROJECT_EXACT dot+C接口；每dot只提交一次C，AB beat有效前缀/last/scale边界稳定；响应写入D并ack后才能计dot/full完成 | 微架构L352–371；malu_pkg.sv L40–60 |
| 诊断/abort | 不支持、descriptor/range/tag错误是项目诊断，不能称PTX统一trap。失败命令已取得的责任须drain/cancel并关闭序号；不得伪成功或留下永久孔洞 | 微架构L96–104、L564–572 |

CTA launch的SMEM分配与tcgen05 TMEM分配是两个服务。SMEM必须与LSU/TMA/peer/barrier看到同一个owner字节对象，不能让Tensor私有副本冒充整个shared内存。若首版仅导出外部SMEM/barrier接口，应准确列明集成前提及未实现的服务端。

## 3. 指令逐项实施检查

| 操作 | 原生行为/参与者 | 最小正确性检查 | 源定位 |
|---|---|---|---|
| alloc | 一个warp；group2为两CTA各一warp；等待可用列并把返回地址写指定SMEM dst | 非exclusive 32/64/128/256/512且申请顺序不递增；exclusive按目标32倍数及512/576上限；permit有效；最终SMEM结果存储ack后发布 | 架构L155–176；微架构L136–158；PTX§9.7.18.7.1 PDF738–741 |
| dealloc | matching base/nCols/group/exclusive；可能阻塞 | 释放前本地与peer无并发访问；不先清bitmap再等旧返回；不把free当MMA wait | 架构L165–172；微架构L140–158 |
| relinquish_alloc_permit | warp collective放弃后续alloc权 | 只改变该CTA/pair相应permit；既有allocation和在途责任保持live；不能当free或完成事件 | 架构L174–176；微架构L158 |
| ld | warp collective TMEM→分布寄存器，warp内同base | 实例键含CTA/warp generation和动态指令实例；warp只访问规定quarter lanes；shape/num/pack寄存器映射由真实recipe给出；所有必需片段ack后才ready | 架构L112–123、L411–421；微架构L330–334 |
| st | warp collective分布寄存器→TMEM | 捕获/保护全部源；packing与word-mask正确；完成在TMEM真实写ack后，不在接收首beat时 | 同上；微架构L525 |
| wait::ld/st | 同thread先前对应传输；warp共同到达 | 两套stream分别等本次watermark；不等MCS，不让wait阻塞本应解除它的RF返回 | 架构L459–486；PTX§.8.5 PDF748–749 |
| cp | 一个thread发起SMEM→TMEM；group2涉及两端 | shape/multicast/descriptor、源版本与proxy合同、范围和写ack；低位展开是container/padding重排，不是数值FP8 cvt | 架构L405–427；微架构L338–342 |
| shift.down | 一个thread；选定32-row quarter的32byte片段沿row下移 | implicit31x256b、base lane32对齐、8columns内row移动；snapshot或高row→低row次序防覆盖；group2需双端完成 | 本文件§4；PTX§.2.3 PDF705、§.9.3 PDF754 |
| mma / mma.sp / mma.ws / mma.ws.sp | 一个thread发令；ws仅group1 | 联合kind/type/MNK/layout/group/scale/sparse/collector/target检查；A为SMEM或TMEM，B为SMEM，D为TMEM；读取真实对象、逐dot计算并写真实D | 架构L238–317、L339–407；微架构L293–324 |
| fence | 每个需要排序的thread对自己的访问执行 | before/after_thread_sync桥接core线程顺序token；不模拟为全endpoint结果drain，也不替代线程barrier或proxy fence | 架构L119、L464–490；微架构L527 |
| commit normal | 一个thread登记其先前mma/cp/shift完整完成 | 捕获MCS cutoff；空集合也能通知；数据完整写ack后推进full；barrier arrive-one事件独立并等ack保留metadata | 架构L459–498；微架构L501–521 |
| commit restricted | 仅先前SMEM-A MMA读取终点 | 独立SMEM-A MMA stream；TMEM-A/cp/shift不伪造SMEM-A读；Aread不清D lease/full token/peer child。未提前实现时可保守晚通知，但不得丢失义务 | 微架构L503、L515–521 |

## 4. shift定点核验：不是column-left

已实际重新提取并视觉读取PTX PDF754/印742：描述是32-byte元素沿rows向下移动一row，排除最后source row；taddr.lane须32对齐。PDF705/印693明确data movement tuple是 `lane × bits-across-columns`，shift为implicit `.31x256b`。

对于base lane L（32对齐）、base column C，实施解释为：

```text
for r = 30 down to 0:
    for j = 0 .. 7:
        TMEM[L+r+1, C+j] = old_TMEM[L+r, C+j]
```

每row8个32bit cell，31×8=248个word搬移。最后row是source被排除，目的最后row由old row30覆盖；不是保留old row31、rotate或columns左移。原PDF未给pseudocode，也未明示vacated row0的填充值。首版若保持row0，应标为项目policy，不声称原生规范保证fill-zero或固定其未说明行为；严格native bit-match需要对该边界另行闭合或gate。任何有限scratch复制必须防止读到本次已经覆盖的源。

shift的Target Notes单列sm_100a、sm_101a→110a、sm_103a、sm_107a、sm_110a；不能因为base tcgen05存在family target就自动开启shift的family支持。

## 5. 完成、源保护和收尾的不变量

1. `issued - prefix < window`约束包括尚未填平的完成孔洞；后完成操作只置bit，不能跳过旧孔洞。counter wrap比较及ready锁存有明确规则。
2. 同issuer commit在有序admission点快照cutoff，后接收的MMA/cp/shift不延长已接受commit。MMA仍在前端等待也须被正确纳入。
3. MCS full完成以本命令全部D/move写ack及所需peer终点为依据；ld/st分别以各自ARF/TMEM ack为依据，不把无关RF工作加入MCS等待。命令accept、最后输入beat、MALU response都不单独构成完整MMA完成。
4. Aread只在当前命令不再重读原SMEM A后置位。若之后仍需A值，则必须用私有snapshot；collector use不保证hit，不能当提前覆盖原A/B的许可。
5. A/D或scale/meta合法别名必须先保护源；无别名recipe时明确关闭该能力。不能边写D边读被自身覆盖的旧A。
6. 每dot `enable-input-d=false`不读旧D、注入零C；true传未缩放D_old和独立C shift。C shift在解码/指数/累加路径处理，不能先打包下溢后再送MALU，也不能双缩放。
7. block size16/32、A/B scale格式、两侧offset和逻辑/压缩K分别推进；按两侧最早块边界切beat；C仅注入一次。
8. PROJECT_EXACT稀疏结构零仍检查对应B NaN/Inf/零符号。省略有限乘法不等于忽略0×Inf分类。原生sparse layouts/scale数不能直接套dense ceil公式。
9. alloc等待不能卡住其他issuer的dealloc/commit/wait或返回；完成通知、释放和peer控制需要独立可前进路径。非阻塞project资源失败API不能冒称原生alloc阻塞语义。
10. soft drain保留已接受工作需要的后续tile/ld/wait/commit/free；abort/reset只有在旧访存/peer/barrier已落地或取消隔离后才回收owner并推进epoch。

依据：微架构L96–106、L273–324、L501–572；SM主架构第16.1–16.2章对Cseed/shift的补充合同。资源深度可以在首版收缩，以上责任和前进条件不能随深度缩减而消失。

## 6. 首版不得伪装支持的变体

| 条件 | 首版未实现时必须保持的边界 |
|---|---|
| CTA group2 / peer | 无双边join/reserve/child/ack和generation隔离则拒绝，不把group2当本地重复执行或M/2硬切 |
| 原始descriptor和复杂layout | 只支持canonical/normalized接口时明确声明；未解码swizzle/major/absolute/reserved bits不能任意接受raw64bit descriptor |
| 任意M/N/K/格式 | 现有MALU支持某格式或MAX_K不等于tcgen05存在对应shape/kind/target；一个合法baseline例为F16 group1 M128 N64 K16，不能推成任意tile |
| Ti16 raw/transpose | raw s1z4m11编码和transpose歧义未闭合；decoded项目模式独立；sparse Ti16 collector语法缺metadata operand处需source review |
| FP64 / full F32 / INT4 / B1 native MMA | 这些是项目MALU扩展，不是tcgen05表50原生A/B乘数行 |
| sparse / scaled / ws / LUT / collector | 没有完整recipe则按具体变体拒绝；不把稀疏当dense、scale常数1、use必命中、ws当普通MMA |
| ld.red / ld.spcompress | reduction/compression、特殊值/selection/metadata及独立target未实现时拒绝；不能只返回原数据冒充完成 |
| cp低位展开 / multicast | 不支持时拒绝；不能直接memcpy任意bitstream或忽略warp-group layout |
| write-disable / zero-column mask | 没有相应语义则gate；禁止把D写禁用与B列清零合成同一个开关 |
| exclusive / 576col特例 | 物理容量与target能力分开；未实现exclusive排他或对应target时不得静默降为普通alloc |
| multicast/restricted commit | 无目标mask/owner/barrier agent和相应完成域则明确拒绝；不能fake ack或复制D代替arrive |
| 目标设备逐位/吞吐 | PROJECT_EXACT只是项目profile；无原生精度oracle/性能证据不得称Rubin bit-match或达到其峰值比例 |

## 7. 首轮RTL审查与动态验证应收集的证据

- capability/合法化拒绝：所有未支持分支产生明确项目诊断、无越权访存/成功D写；保留accepted与rejected命令身份。
- allocator：owner/permit不混、nCols/匹配free、容量等待下释放前进、group一致性、generation重用及exclusive作用域。
- 数据路径：TMEM地址与SMEM offset区分；非重复pattern检查ld/st/cp布局与shift row移动；first/middle fragment stall不丢/重写。
- 数值：从真实SMEM/TMEM读取A/B/C，MALU只做dot+C；D ack前不full；disable-input-D旧NaN不泄漏；Cshift不提前舍入。
- 完成：早Aread/晚full、空commit、同issuer cutoff、其他issuer隔离、wrap/孔洞（若使用窗口）、外部barrier ack回压。
- 错误/复位：非法配置不伪成功；已接受请求出错后drain/abort；旧generation响应不写新owner；协议进度不依赖消费者先wait。

静态review与实际仿真必须分开记录；未运行的case保持NOT_RUN。后续代码独立审查在本文件追加具体文件/行、反例与关闭证据，不能用本清单替代新RTL执行证明。

## 8. 既有文档只读基线

- `docs/tcgen05/TCGEN05_TENSOR_ARCHITECTURE.md`：SHA-256 `4612f7b87d00ced9cda627ae002d840c7c4881f53031b3d8052417262294dc8e`。
- `docs/tcgen05/microarchitecture/TCGEN05_TENSOR_MICROARCHITECTURE.md`：SHA-256 `a1ed03c91884b7610c205cdf9c923fc6be6fd22ee129abfd505f3385bf3bd924`。
- `docs/tcgen05/research/ptx94_architecture_audit.md`：SHA-256 `ed7f2d2f0ec28a40713e1d5bd7cb93f6da7cd5a8ac1f83fd31507f3ca9ed07ed`。
