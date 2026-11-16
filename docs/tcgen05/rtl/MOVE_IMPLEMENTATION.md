# tcgen05 数据移动 RTL

`tcgen05_move.sv`实现LD/ST片段传输、load reduction、load sparse compression、CP格式展开与multicast，以及SHIFT。它通过规范化命令接入；原生SMEM描述符使用公共`tcgen05_layout_pkg`，不将未识别描述符静默解释成线性地址。全局target、owner/allocation和recipe准入由上层legalizer、allocator及peer协调器负责。

## 接口与完成

- 命令`req/rsp`带tag与owner generation；`rf_in`为store寄存器片段输入，`rf_out`为load片段输出。
- 每个RF片段携带32个thread的一个b32寄存器、kind、index、mask与last。kind区分DATA、META和RED。宽x128请求分片，不分配整条16KiB寄存器向量缓存。
- store必须按index提供全部DATA片段，tag、owner generation、mask和last均核对；load在所有DATA/META/RED片段被RF接收后才产生完成响应。
- TMEM与SMEM两端合计最多一个请求在途。每笔有64位事务号，返回号或状态错误会终结命令；ready受阻时payload稳定。
- pair CP/SHIFT先做local再做peer，两个端点全部ack后才成功完成。上层必须在开始前取得两端资源与生命周期责任。
- 错误不回滚已经提交的TMEM写入。上层错误隔离与owner清理不能将partial write当成正常结果。
- legacy WORD32、`rf_stream=0`仅保留旧单列quarter LD/ST内联128B数据适配；不是原生PTX寄存器布局的替代品。

## LD/ST形状与转换

支持32x32b、16x64b、16x128b、16x256b和16x32bx2；repeat为x1…x128的合法2次幂。16x128b最高x64，16x256b最高x32，每thread最多128个b32寄存器。thread/lane/column映射依PTX图186–190；16x32bx2的第二half单独加immHalfSplitoff，pack/unpack不会把该地址偏移翻倍。

pack16将相邻TMEM column的低16位拼入一个RF word；unpack16反向写入两个column的低16位，使用byte mask保留无关高16位。寄存器向量长度不变，实际访问column数加倍。

## Reduction与compression

`tcgen05_move_math.sv`为单个共享比较/选择电路，不调用real/shortreal。

- F32/S32/U32的min/max；F32支持abs与NaN传播，整数不接受这些修饰。
- IEEE位序处理NaN、Inf、subnormal及signed zero；min选择-0，max选择+0。无NaN传播时优先返回非NaN，两个NaN返回canonical NaN；NaN传播开启时任一NaN令reduction结果为canonical NaN。
- 2:4 compression按每thread的连续4个F32选择两项。NaN始终优先保留；相等或NaN数超过2时选低源index，是明确的实现选择。cdata保持源index顺序并保留原始payload，abs仅作用于选择和reduction，不改写cdata。
- 每组metadata为两个b2索引，连续8组装入一个b32；最后不足32位时高位为0。x4…x128的cdata长度num/2，metadata长度ceil(num/32)。
- `.red.spcompress`的NaN控制只影响RED输出，不影响compression保留NaN。

## CP与SHIFT

CP支持4x256b、32x128b、64x128b、128x128b、128x256b。32x128b broadcast到四个quarter；64x128b按02_13或01_23配对，源行选择由公开CUTLASS formal traits交叉核对。

**4x256b的目的lane为base+{0,32,64,96}**，不是4个相邻lane。4个SMEM source row仍是4个独立行；CUTLASS SrcLayout中的stride32表示logical refresh坐标，不是要求SMEM物理source row再乘32。base_lane=31可刷新31、63、95、127四个tail。

CP B4把16个4bit packed值及64bit padding的128bit容器展开为16个8bit值，单元素执行`raw4<<2`；B6把16个6bit及32bit padding展开为16个8bit值，高2位清0。它们是规范中的容器重排，不是任意FP8数值转换；输入padding即使非0也不会进入输出。

SHIFT按32-lane quarter滑动窗口：`dst[row0…30]=old[row1…31]`，按目标row升序避免覆盖未读源。最后row31保持，供后续CP4 tail refresh。该方向结合专利C0…C3→C1…C4窗口序列和公开CUTLASS的last-lane refresh使用方式确认；不沿用早期草稿的相反方向。

## 资源与验证

每次只保存一个128B load片段、一个128B store片段、512B compression窗口、256B compression输出、128B metadata及128B reduction状态，另有16B CP容器。容量不随repeat增加；这些是显式数据寄存器容量，未包含命令/响应记录、综合优化、宏或PPA估计。

专用测试文件：

- `verif/core/src/rtl/sp/eu/tensor/tcgen05/tb_tcgen05_move.sv`：独立scalar TMEM/SMEM模型、所有合法shape/repeat、pack/unpack、reduction、compression、CP展开/multicast、pair和滑窗链，含内存/RF回压、错误和事务号错配。
- `tb_tcgen05_move_math.sv`与`generate_move_vectors.py`：用Python IEEE F32解码及独立排序规则生成比较/selection oracle，覆盖NaN、signed zero、Inf、subnormal和整数。
- 测试不调用DUT地址helper来生成expected RF映射或CP源地址；CP4、halfSplit和shift均有明确地址断言／逐word内存比较。

当前实际结果与源码hash以构建目录`build/tcgen05/move_unit/`及主集成检查报告为准，不能把本单元通过算作整套SM指令发生器106个testplan用例已运行。
