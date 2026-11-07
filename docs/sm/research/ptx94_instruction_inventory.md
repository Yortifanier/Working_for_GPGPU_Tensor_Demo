# PTX ISA 9.4 全量指令目录核对（SM 架构输入）

本目录以用户上传的 PTX ISA 9.4 PDF 为准，覆盖第 9 章全部指令说明叶子。执行域列是本项目 SM 设计的路由建议；它不声称 NVIDIA 将这些 PTX 语义映射到同名物理管线。PTX 是虚拟 ISA，完整支持也不意味着每种语义各有一个硬件单元。

## 1. 来源与统计口径

- 原文件：`ptx_isa_9.4.pdf`；封面 Release 9.4，2026-07-17；1002 个物理 PDF 页。
- SHA-256：`4be2905e240b70a8b176b4d6fb162714f2fc361a9503572d848ff723abf289c3`。
- 第 9 章：物理 PDF 133–874 页；本章正文印刷页 = 物理页 − 12。以下表格同时给出两种页码。
- 方法：重建 PDF 书签的节号；逐项在指定物理页匹配正文编号；再对整章正文的独立 `Syntax` 标题反向核对。
- **217 个说明叶子 = 215 个实际指令说明节 + 2 个控制语法节（`{}`、`@`）**；整章恰有 217 个 Syntax 块，一一归属，无游离 Syntax。
- 拆开同节的多个名称后，有 **240 次实际指令标题名称出现、210 个唯一标题标签**。`add` 等按类型分散在多个节；`rcp.approx.ftz.f64` 等专用标题仍是独立标签；alias 尚未按硬件去重。
- 上述数目均不是 SASS opcode 数，也不是所有 type/shape/qualifier 合法 tuple 的笛卡尔积。正文 Syntax 保留全部限定符和同节形式，不因标题只有 `tcgen05.ld` 就遗漏其 reduction/compression 形式。
- JSON 附全量 459 个第 9 章书签小节、每个指令的原 Syntax/PTX ISA Notes/Target ISA Notes，并附第 11 章 34 个 directive 说明叶子；这些 directive 不计入指令数。第 5 章声明语法并非第 11 章 directive 附表的覆盖对象。

配套机器清单：[ptx94_instruction_inventory.json](ptx94_instruction_inventory.json)。PDF 抽取的 Syntax 可能保留跨页折行/图表文字，不能直接当作可汇编字符串使用。

## 2. 类别覆盖与计数

| 类别节 | PDF/印刷页 | 原文类别 | 指令说明节 | 控制语法节 | 拆分名称出现 |
|---|---:|---|---:|---:|---:|
| 9.7.1 | 141/129 | Integer Arithmetic Instructions | 25 | 0 | 25 |
| 9.7.2 | 174/162 | Extended-Precision Integer Arithmetic Instructions | 6 | 0 | 6 |
| 9.7.3 | 181/169 | Floating-Point Instructions | 22 | 0 | 22 |
| 9.7.4 | 220/208 | Half Precision Floating-Point Instructions | 10 | 0 | 10 |
| 9.7.5 | 240/228 | Mixed Precision Floating-Point Instructions | 4 | 0 | 4 |
| 9.7.6 | 247/235 | Alternate Floating-Point Instructions | 4 | 0 | 4 |
| 9.7.7 | 257/245 | Comparison and Selection Instructions | 4 | 0 | 4 |
| 9.7.8 | 264/252 | Half Precision Comparison Instructions | 2 | 0 | 2 |
| 9.7.9 | 269/257 | Logic and Shift Instructions | 9 | 0 | 9 |
| 9.7.10 | 280/268 | Data Movement and Conversion Instructions | 41 | 0 | 45 |
| 9.7.11 | 396/384 | Fabric Instructions | 6 | 0 | 6 |
| 9.7.12 | 409/397 | Texture Instructions | 4 | 0 | 4 |
| 9.7.13 | 423/411 | Surface Instructions | 4 | 0 | 4 |
| 9.7.14 | 431/419 | Control Flow Instructions | 5 | 2 | 5 |
| 9.7.15 | 439/427 | Parallel Synchronization and Communication Instructions | 28 | 0 | 31 |
| 9.7.16 | 505/493 | Warp Level Matrix Multiply-Accumulate Instructions | 8 | 0 | 9 |
| 9.7.17 | 645/633 | Asynchronous Warpgroup Level Matrix Multiply-Accumulate Instructions | 5 | 0 | 5 |
| 9.7.18 | 699/687 | TensorCore 5th Generation Family Instructions | 12 | 0 | 14 |
| 9.7.19 | 847/835 | Stack Manipulation Instructions | 3 | 0 | 3 |
| 9.7.20 | 851/839 | Video Instructions | 8 | 0 | 23 |
| 9.7.21 | 868/856 | Miscellaneous Instructions | 5 | 0 | 5 |

## 3. 全部指令说明叶子

表中每行对应一个完整原文说明节；同名节保留。完整标题、所有 Syntax 形式及逐形式 target 限制见 JSON 对应 `section`；域建议不能覆盖其原始限制。

### 9.7.1 Integer Arithmetic Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.1.1 | 142/130 | `add` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.2 | 143/131 | `sub` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.3 | 145/133 | `mul` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.4 | 146/134 | `mad` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.5 | 148/136 | `clmad` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.6 | 149/137 | `mul24` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.7 | 150/138 | `mad24` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.8 | 151/139 | `sad` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.9 | 152/140 | `div` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.10 | 153/141 | `rem` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.11 | 154/142 | `abs` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.12 | 155/143 | `neg` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.13 | 157/145 | `min` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.14 | 159/147 | `max` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.15 | 160/148 | `popc` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.16 | 161/149 | `clz` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.17 | 162/150 | `bfind` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.18 | 164/152 | `fns` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.19 | 165/153 | `brev` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.20 | 166/154 | `bfe` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.21 | 167/155 | `bfi` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.22 | 168/156 | `szext` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.23 | 170/158 | `bmsk` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.24 | 171/159 | `dp4a` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |
| 9.7.1.25 | 172/160 | `dp2a` | 整数寄存器算术/位操作管线；长延迟操作可分步实现 |

### 9.7.2 Extended-Precision Integer Arithmetic Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.2.1 | 174/162 | `add.cc` | 整数扩展精度管线及每线程CC状态 |
| 9.7.2.2 | 175/163 | `addc` | 整数扩展精度管线及每线程CC状态 |
| 9.7.2.3 | 176/164 | `sub.cc` | 整数扩展精度管线及每线程CC状态 |
| 9.7.2.4 | 177/165 | `subc` | 整数扩展精度管线及每线程CC状态 |
| 9.7.2.5 | 179/167 | `mad.cc` | 整数扩展精度管线及每线程CC状态 |
| 9.7.2.6 | 180/168 | `madc` | 整数扩展精度管线及每线程CC状态 |

### 9.7.3 Floating-Point Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.3.1 | 184/172 | `testp` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.2 | 185/173 | `copysign` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.3 | 186/174 | `add` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.4 | 188/176 | `sub` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.5 | 190/178 | `mul` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.6 | 192/180 | `fma` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.7 | 194/182 | `mad` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.8 | 196/184 | `div` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.9 | 198/186 | `abs` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.10 | 199/187 | `neg` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.11 | 200/188 | `min` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.12 | 203/191 | `max` | 浮点寄存器ALU/FMA；按操作和精度分发 |
| 9.7.3.13 | 205/193 | `rcp` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.14 | 207/195 | `rcp.approx.ftz.f64` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.15 | 208/196 | `sqrt` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.16 | 210/198 | `rsqrt` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.17 | 212/200 | `rsqrt.approx.ftz.f64` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.18 | 213/201 | `sin` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.19 | 215/203 | `cos` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.20 | 216/204 | `lg2` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.21 | 218/206 | `ex2` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |
| 9.7.3.22 | 219/207 | `tanh` | 浮点特殊函数/除法服务；可为专用管线或编译展开，PTX未规定硬件映射 |

### 9.7.4 Half Precision Floating-Point Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.4.1 | 221/209 | `add` | 半精度/打包浮点寄存器ALU |
| 9.7.4.2 | 223/211 | `sub` | 半精度/打包浮点寄存器ALU |
| 9.7.4.3 | 225/213 | `mul` | 半精度/打包浮点寄存器ALU |
| 9.7.4.4 | 227/215 | `fma` | 半精度/打包浮点寄存器ALU |
| 9.7.4.5 | 229/217 | `neg` | 半精度/打包浮点寄存器ALU |
| 9.7.4.6 | 231/219 | `abs` | 半精度/打包浮点寄存器ALU |
| 9.7.4.7 | 232/220 | `min` | 半精度/打包浮点寄存器ALU |
| 9.7.4.8 | 235/223 | `max` | 半精度/打包浮点寄存器ALU |
| 9.7.4.9 | 237/225 | `tanh` | 半精度特殊函数服务；不能据PTX名称推断物理SFU吞吐 |
| 9.7.4.10 | 238/226 | `ex2` | 半精度特殊函数服务；不能据PTX名称推断物理SFU吞吐 |

### 9.7.5 Mixed Precision Floating-Point Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.5.1 | 241/229 | `add` | 混合精度寄存器ALU；按目标与tuple启用 |
| 9.7.5.2 | 242/230 | `sub` | 混合精度寄存器ALU；按目标与tuple启用 |
| 9.7.5.3 | 244/232 | `fma` | 混合精度寄存器ALU；按目标与tuple启用 |
| 9.7.5.4 | 246/234 | `mul` | 混合精度寄存器ALU；按目标与tuple启用 |

### 9.7.6 Alternate Floating-Point Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.6.1 | 247/235 | `add` | 低位宽/打包浮点寄存器ALU；按具体形式启用 |
| 9.7.6.2 | 250/238 | `sub` | 低位宽/打包浮点寄存器ALU；按具体形式启用 |
| 9.7.6.3 | 252/240 | `mul` | 低位宽/打包浮点寄存器ALU；按具体形式启用 |
| 9.7.6.4 | 254/242 | `fma` | 低位宽/打包浮点寄存器ALU；按具体形式启用 |

### 9.7.7 Comparison and Selection Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.7.1 | 258/246 | `set` | 比较/谓词与选择通路 |
| 9.7.7.2 | 260/248 | `setp` | 比较/谓词与选择通路 |
| 9.7.7.3 | 262/250 | `selp` | 比较/谓词与选择通路 |
| 9.7.7.4 | 263/251 | `slct` | 比较/谓词与选择通路 |

### 9.7.8 Half Precision Comparison Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.8.1 | 264/252 | `set` | 半精度比较/谓词通路 |
| 9.7.8.2 | 267/255 | `setp` | 半精度比较/谓词通路 |

### 9.7.9 Logic and Shift Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.9.1 | 270/258 | `and` | 逻辑/移位寄存器ALU |
| 9.7.9.2 | 271/259 | `or` | 逻辑/移位寄存器ALU |
| 9.7.9.3 | 272/260 | `xor` | 逻辑/移位寄存器ALU |
| 9.7.9.4 | 273/261 | `not` | 逻辑/移位寄存器ALU |
| 9.7.9.5 | 274/262 | `cnot` | 逻辑/移位寄存器ALU |
| 9.7.9.6 | 275/263 | `lop3` | 逻辑/移位寄存器ALU |
| 9.7.9.7 | 277/265 | `shf` | 逻辑/移位寄存器ALU |
| 9.7.9.8 | 278/266 | `shl` | 逻辑/移位寄存器ALU |
| 9.7.9.9 | 279/267 | `shr` | 逻辑/移位寄存器ALU |

### 9.7.10 Data Movement and Conversion Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.10.3 | 284/272 | `mov` | 寄存器搬运、特殊寄存器读取、打包/重排通路 |
| 9.7.10.4 | 285/273 | `mov` | 寄存器搬运、特殊寄存器读取、打包/重排通路 |
| 9.7.10.5 | 287/275 | `shfl`（deprecated） | warp内寄存器交换与成员掩码控制 |
| 9.7.10.6 | 290/278 | `shfl.sync` | warp内寄存器交换与成员掩码控制 |
| 9.7.10.7 | 292/280 | `prmt` | 寄存器搬运、特殊寄存器读取、打包/重排通路 |
| 9.7.10.8 | 294/282 | `ld` | load按合法const/global/local/param/shared空间与具体MMIO/readonly形式路由 |
| 9.7.10.9 | 299/287 | `ld.global.nc` | global非coherent缓存读取服务；不能泛化到shared/local |
| 9.7.10.10 | 302/290 | `ldu` | global只读uniform load服务；按本指令地址/收敛要求检查 |
| 9.7.10.11 | 303/291 | `st` | store按合法global/local/param::func/shared空间路由；MMIO为global形式 |
| 9.7.10.12 | 308/296 | `st.async` | 按形式分发shared::cluster写入及mbarrier字节完成，或global release写入（可MMIO） |
| 9.7.10.13 | 310/298 | `multimem.st.async` | global多地址异步release写入及gpu/sys顺序；不使用shared写入的mbarrier完成形式 |
| 9.7.10.14 | 312/300 | `st.bulk` | shared::cta区域零初始化服务；不支持global/local/constant目的空间 |
| 9.7.10.15 | 313/301 | `multimem.ld_reduce`, `multimem.st`, `multimem.red` | 多地址/多副本内存访问与归约服务 |
| 9.7.10.16 | 316/304 | `prefetch`, `prefetchu` | cache预取/优先级/丢弃/策略对象服务 |
| 9.7.10.17 | 318/306 | `applypriority` | cache预取/优先级/丢弃/策略对象服务 |
| 9.7.10.18 | 319/307 | `applypriority.async.bulk` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.19 | 320/308 | `applypriority.async.bulk.tensor` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.20 | 321/309 | `discard` | cache预取/优先级/丢弃/策略对象服务 |
| 9.7.10.21 | 322/310 | `createpolicy` | cache预取/优先级/丢弃/策略对象服务 |
| 9.7.10.22 | 324/312 | `isspacep` | 状态空间/CTA地址转换或查询；不等价于实际数据读写 |
| 9.7.10.23 | 325/313 | `cvta` | 状态空间/CTA地址转换或查询；不等价于实际数据读写 |
| 9.7.10.24 | 327/315 | `cvt` | 寄存器类型转换/打包/舍入服务 |
| 9.7.10.25 | 341/329 | `cvt.pack` | 寄存器类型转换/打包/舍入服务 |
| 9.7.10.26 | 342/330 | `mapa` | 状态空间/CTA地址转换或查询；不等价于实际数据读写 |
| 9.7.10.27 | 344/332 | `getctarank` | 状态空间/CTA地址转换或查询；不等价于实际数据读写 |
| 9.7.10.28.3.1 | 348/336 | `cp.async` | 非bulk全局到shared拷贝与每线程async-group完成域 |
| 9.7.10.28.3.2 | 350/338 | `cp.async.commit_group` | 非bulk全局到shared拷贝与每线程async-group完成域 |
| 9.7.10.28.3.3 | 351/339 | `cp.async.wait_group`, `cp.async.wait_all` | 非bulk全局到shared拷贝与每线程async-group完成域 |
| 9.7.10.28.4.1 | 352/340 | `cp.async.bulk` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.4.2 | 358/346 | `cp.reduce.async.bulk` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.4.3 | 362/350 | `cp.async.bulk.prefetch` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.4.4 | 363/351 | `multimem.cp.async.bulk` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.4.5 | 365/353 | `multimem.cp.reduce.async.bulk` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.5.5 | 372/360 | `cp.async.bulk.tensor` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.5.6 | 379/367 | `cp.reduce.async.bulk.tensor` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.5.7 | 382/370 | `cp.async.bulk.prefetch.tensor` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.6.1 | 385/373 | `cp.async.bulk.commit_group` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.28.6.2 | 386/374 | `cp.async.bulk.wait_group` | bulk/TMA/多播或异步cache-control发令与其完成服务；按具体指令路由 |
| 9.7.10.29 | 388/376 | `tensormap.replace` | tensor-map对象更新及其可见性管理；非矩阵描述符解码 |
| 9.7.10.30 | 391/379 | `spcompress` | 寄存器向量稀疏压缩/解压格式服务；独立于MMA运算 |
| 9.7.10.31 | 394/382 | `spdecompress` | 寄存器向量稀疏压缩/解压格式服务；独立于MMA运算 |

### 9.7.11 Fabric Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.11.5.1 | 399/387 | `fabric.try_get` | SM发令与提交/完成端点，加外部fabric服务；非本地ALU |
| 9.7.11.5.2 | 401/389 | `fabric.try_put` | SM发令与提交/完成端点，加外部fabric服务；非本地ALU |
| 9.7.11.5.3 | 403/391 | `fabric.try_red` | SM发令与提交/完成端点，加外部fabric服务；非本地ALU |
| 9.7.11.5.4 | 405/393 | `fabric.try_pullred` | SM发令与提交/完成端点，加外部fabric服务；非本地ALU |
| 9.7.11.5.5 | 407/395 | `fabric.submit` | SM发令与提交/完成端点，加外部fabric服务；非本地ALU |
| 9.7.11.5.6 | 408/396 | `fabric.wait` | SM发令与提交/完成端点，加外部fabric服务；非本地ALU |

### 9.7.12 Texture Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.12.3 | 411/399 | `tex` | 纹理查询/采样服务及寄存器返回 |
| 9.7.12.4 | 417/405 | `tld4` | 纹理查询/采样服务及寄存器返回 |
| 9.7.12.5 | 420/408 | `txq` | 纹理查询/采样服务及寄存器返回 |
| 9.7.12.6 | 422/410 | `istypep` | 纹理查询/采样服务及寄存器返回 |

### 9.7.13 Surface Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.13.1 | 423/411 | `suld` | surface地址/访存/原子服务 |
| 9.7.13.2 | 425/413 | `sust` | surface地址/访存/原子服务 |
| 9.7.13.3 | 427/415 | `sured` | surface地址/访存/原子服务 |
| 9.7.13.4 | 429/417 | `suq` | surface地址/访存/原子服务 |

### 9.7.14 Control Flow Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.14.1 | 431/419 | `{}`（非 opcode） | 作用域/谓词汇编语法；不是独立硬件opcode |
| 9.7.14.2 | 432/420 | `@`（非 opcode） | 作用域/谓词汇编语法；不是独立硬件opcode |
| 9.7.14.3 | 433/421 | `bra` | SIMT前端、谓词、分支、调用及线程生命周期 |
| 9.7.14.4 | 434/422 | `brx.idx` | SIMT前端、谓词、分支、调用及线程生命周期 |
| 9.7.14.5 | 435/423 | `call` | SIMT前端、谓词、分支、调用及线程生命周期 |
| 9.7.14.6 | 437/425 | `ret` | SIMT前端、谓词、分支、调用及线程生命周期 |
| 9.7.14.7 | 438/426 | `exit` | SIMT前端、谓词、分支、调用及线程生命周期 |

### 9.7.15 Parallel Synchronization and Communication Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.15.1 | 440/428 | `bar`, `barrier` | CTA命名屏障/cluster双阶段同步与线程进度管理 |
| 9.7.15.2 | 443/431 | `bar.warp.sync` | warp成员集合、交换/归约/选举与warp同步服务 |
| 9.7.15.3 | 444/432 | `barrier.cluster` | CTA命名屏障/cluster双阶段同步与线程进度管理 |
| 9.7.15.4 | 446/434 | `membar`, `fence` | 内存顺序与proxy交接；不等价于所有异步引擎完成 |
| 9.7.15.5 | 449/437 | `atom` | 按地址空间路由原子/RMW/内存归约；不同于warp寄存器归约 |
| 9.7.15.6 | 455/443 | `red` | 按地址空间路由原子/RMW/内存归约；不同于warp寄存器归约 |
| 9.7.15.7 | 460/448 | `red.async` | 按地址空间路由原子/RMW/内存归约；不同于warp寄存器归约 |
| 9.7.15.8 | 463/451 | `multimem.red.async` | 按地址空间路由原子/RMW/内存归约；不同于warp寄存器归约 |
| 9.7.15.9 | 465/453 | `vote`（deprecated） | warp成员集合、交换/归约/选举与warp同步服务 |
| 9.7.15.10 | 466/454 | `vote.sync` | warp成员集合、交换/归约/选举与warp同步服务 |
| 9.7.15.11 | 468/456 | `match.sync` | warp成员集合、交换/归约/选举与warp同步服务 |
| 9.7.15.12 | 469/457 | `activemask` | warp成员集合、交换/归约/选举与warp同步服务 |
| 9.7.15.13 | 470/458 | `redux.sync` | warp成员集合、交换/归约/选举与warp同步服务 |
| 9.7.15.14 | 471/459 | `griddepcontrol` | grid依赖/启动协作接口；SM外launch系统共同参与 |
| 9.7.15.15 | 472/460 | `elect.sync` | warp成员集合、交换/归约/选举与warp同步服务 |
| 9.7.15.16.12 | 479/467 | `mbarrier.init` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.13 | 480/468 | `mbarrier.inval` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.14 | 482/470 | `mbarrier.expect_tx` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.15 | 483/471 | `mbarrier.complete_tx` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.16 | 485/473 | `mbarrier.arrive` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.17 | 487/475 | `mbarrier.arrive_drop` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.18 | 490/478 | `cp.async.mbarrier.arrive` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.19 | 492/480 | `mbarrier.test_wait`, `mbarrier.try_wait` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.20 | 498/486 | `mbarrier.pending_count` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.16.21 | 499/487 | `mbarrier.check_layout` | 真实shared内存中的opaque mbarrier对象及相关异步事件 |
| 9.7.15.17 | 500/488 | `tensormap.cp_fenceproxy` | 内存顺序与proxy交接；不等价于所有异步引擎完成 |
| 9.7.15.18 | 501/489 | `clusterlaunchcontrol.try_cancel` | 尚未启动cluster取消/响应解码；launch系统共同参与 |
| 9.7.15.19 | 504/492 | `clusterlaunchcontrol.query_cancel` | 尚未启动cluster取消/响应解码；launch系统共同参与 |

### 9.7.16 Warp Level Matrix Multiply-Accumulate Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.16.4.3 | 518/506 | `wmma.load` | warp协同矩阵load/store与fragment映射 |
| 9.7.16.4.4 | 521/509 | `wmma.store` | warp协同矩阵load/store与fragment映射 |
| 9.7.16.4.5 | 523/511 | `wmma.mma` | warp协同WMMA/MMA计算；类型/shape/metadata/target分别校验 |
| 9.7.16.5.14 | 586/574 | `mma` | warp协同WMMA/MMA计算；类型/shape/metadata/target分别校验 |
| 9.7.16.5.15 | 597/585 | `ldmatrix` | warp协同矩阵load/store与fragment映射 |
| 9.7.16.5.16 | 603/591 | `stmatrix` | warp协同矩阵load/store与fragment映射 |
| 9.7.16.5.17 | 606/594 | `movmatrix` | warp协同矩阵寄存器转置/重排 |
| 9.7.16.6.3 | 637/625 | `mma.sp`, `mma.sp::ordered_metadata` | warp协同WMMA/MMA计算；类型/shape/metadata/target分别校验 |

### 9.7.17 Asynchronous Warpgroup Level Matrix Multiply-Accumulate Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.17.5.2 | 675/663 | `wgmma.mma_async` | warpgroup异步矩阵服务及专属组完成状态 |
| 9.7.17.6.3 | 690/678 | `wgmma.mma_async.sp` | warpgroup异步矩阵服务及专属组完成状态 |
| 9.7.17.7.1 | 695/683 | `wgmma.fence` | 专属wgmma寄存器/组发令/完成管理 |
| 9.7.17.7.2 | 696/684 | `wgmma.commit_group` | 专属wgmma寄存器/组发令/完成管理 |
| 9.7.17.7.3 | 697/685 | `wgmma.wait_group` | 专属wgmma寄存器/组发令/完成管理 |

### 9.7.18 TensorCore 5th Generation Family Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.18.7.1 | 738/726 | `tcgen05.alloc`, `tcgen05.dealloc`, `tcgen05.relinquish_alloc_permit` | TMEM列分配/回收及CTA分配许可；含collective/group2生命周期 |
| 9.7.18.8.3 | 742/730 | `tcgen05.ld` | warp协同TMEM/寄存器传输与专属load/store等待 |
| 9.7.18.8.4 | 746/734 | `tcgen05.st` | warp协同TMEM/寄存器传输与专属load/store等待 |
| 9.7.18.8.5 | 748/736 | `tcgen05.wait` | warp协同TMEM/寄存器传输与专属load/store等待 |
| 9.7.18.9.2 | 751/739 | `tcgen05.cp` | SMEM到TMEM搬运或TMEM内部shift；mbarrier正常完成 |
| 9.7.18.9.3 | 753/741 | `tcgen05.shift` | SMEM到TMEM搬运或TMEM内部shift；mbarrier正常完成 |
| 9.7.18.10.10.1 | 823/811 | `tcgen05.mma` | tcgen05矩阵计算；单线程发令与CTA-group资源协同 |
| 9.7.18.10.10.2 | 830/818 | `tcgen05.mma.sp` | tcgen05矩阵计算；单线程发令与CTA-group资源协同 |
| 9.7.18.10.10.3 | 837/825 | `tcgen05.mma.ws` | tcgen05矩阵计算；单线程发令与CTA-group资源协同 |
| 9.7.18.10.10.4 | 840/828 | `tcgen05.mma.ws.sp` | tcgen05矩阵计算；单线程发令与CTA-group资源协同 |
| 9.7.18.11.1 | 843/831 | `tcgen05.fence` | tcgen05线程同步桥接/发起mbarrier完成跟踪；非阻塞全局drain |
| 9.7.18.12.1 | 844/832 | `tcgen05.commit` | tcgen05线程同步桥接/发起mbarrier完成跟踪；非阻塞全局drain |

### 9.7.19 Stack Manipulation Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.19.1 | 847/835 | `stacksave` | 函数栈/本地地址与动态栈帧管理 |
| 9.7.19.2 | 848/836 | `stackrestore` | 函数栈/本地地址与动态栈帧管理 |
| 9.7.19.3 | 849/837 | `alloca` | 函数栈/本地地址与动态栈帧管理 |

### 9.7.20 Video Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.20.1.1 | 853/841 | `vadd`, `vsub`, `vabsdiff`, `vmin`, `vmax` | 寄存器标量/打包整数video语义；按目标支持 |
| 9.7.20.1.2 | 854/842 | `vshl`, `vshr` | 寄存器标量/打包整数video语义；按目标支持 |
| 9.7.20.1.3 | 856/844 | `vmad` | 寄存器标量/打包整数video语义；按目标支持 |
| 9.7.20.1.4 | 858/846 | `vset` | 寄存器标量/打包整数video语义；按目标支持 |
| 9.7.20.2.1 | 860/848 | `vadd2`, `vsub2`, `vavrg2`, `vabsdiff2`, `vmin2`, `vmax2` | 寄存器标量/打包整数video语义；按目标支持 |
| 9.7.20.2.2 | 863/851 | `vset2` | 寄存器标量/打包整数video语义；按目标支持 |
| 9.7.20.2.3 | 864/852 | `vadd4`, `vsub4`, `vavrg4`, `vabsdiff4`, `vmin4`, `vmax4` | 寄存器标量/打包整数video语义；按目标支持 |
| 9.7.20.2.4 | 867/855 | `vset4` | 寄存器标量/打包整数video语义；按目标支持 |

### 9.7.21 Miscellaneous Instructions

| 节号 | PDF/印刷页 | 指令标题名称 | 建议 SM 执行域 |
|---|---:|---|---|
| 9.7.21.1 | 869/857 | `brkpt` | 调试/暂停/性能事件/寄存器资源控制 |
| 9.7.21.2 | 869/857 | `nanosleep` | 调试/暂停/性能事件/寄存器资源控制 |
| 9.7.21.3 | 870/858 | `pmevent` | 调试/暂停/性能事件/寄存器资源控制 |
| 9.7.21.4 | 871/859 | `trap` | 调试/暂停/性能事件/寄存器资源控制 |
| 9.7.21.5 | 872/860 | `setmaxnreg` | warp请求/释放CTA寄存器池资源；可能阻塞 |

## 4. 同节隐藏形式与不可合并的完成域

以下是避免仅按标题漏项的导航表；星号和花括号是压缩展示，精确合法拼写/tuple仍以 JSON 原 Syntax 及指定原页为准。并非把每个限定符视为新增 opcode。

| 说明节 | PDF/印刷页 | 必须保留的形式/语义 |
|---|---:|---|
| 9.7.10.23 | 325/313 | `cvta.space`；`cvta.to.space` |
| 9.7.15.1 | 440/428 | `barrier{.cta}.sync{.aligned}`；`barrier{.cta}.arrive{.aligned}`；`barrier{.cta}.red.popc{.aligned}`；`barrier{.cta}.red.{and,or}{.aligned}`；`bar{.cta}.sync`；`bar{.cta}.arrive`；`bar{.cta}.red.{popc,and,or}` |
| 9.7.15.3 | 444/432 | `barrier.cluster.arrive{.release\|.relaxed}{.aligned}`；`barrier.cluster.wait{.acquire}{.aligned}` |
| 9.7.15.4 | 446/434 | `fence{.sc\|.acq_rel\|.acquire\|.release}.scope`；`fence.acquire.sync_restrict::shared::cluster.cluster`；`fence.release.sync_restrict::shared::cta.cluster`；`fence.mbarrier_init.release.cluster`；`fence.proxy.*`；`membar.{cta,gl,sys}`；`membar.proxy.*` |
| 9.7.15.14 | 471/459 | `griddepcontrol.launch_dependents`；`griddepcontrol.wait` |
| 9.7.15.16.16 | 485/473 | `mbarrier.arrive`；`mbarrier.arrive.expect_tx`；`mbarrier.arrive.noComplete` |
| 9.7.15.16.17 | 487/475 | `mbarrier.arrive_drop`；`mbarrier.arrive_drop.expect_tx`；`mbarrier.arrive_drop.noComplete` |
| 9.7.15.16.19 | 492/480 | `mbarrier.test_wait`；`mbarrier.test_wait.parity`；`mbarrier.try_wait`；`mbarrier.try_wait.parity`；`{test_wait,try_wait}.phase_type::{primary,conditional}`；`primary wait with optional reportPredicate/reportValue` |
| 9.7.15.19 | 504/492 | `clusterlaunchcontrol.query_cancel.is_canceled`；`clusterlaunchcontrol.query_cancel.get_first_ctaid.v4`；`clusterlaunchcontrol.query_cancel.get_first_ctaid{::x,::y,::z}` |
| 9.7.16.4.3 | 518/506 | `wmma.load.a`；`wmma.load.b`；`wmma.load.c` |
| 9.7.16.4.4 | 521/509 | `wmma.store.d` |
| 9.7.16.4.5 | 523/511 | `wmma.mma`；`wmma.mma.xor.popc`；`wmma.mma.and.popc` |
| 9.7.16.5.14 | 586/574 | `mma.sync.aligned (floating/integer/binary/alternate/block_scaled forms, see full Syntax)` |
| 9.7.18.7.1 | 738/726 | `tcgen05.alloc{.exclusive}`；`tcgen05.dealloc{.exclusive}`；`tcgen05.relinquish_alloc_permit` |
| 9.7.18.8.3 | 742/730 | `tcgen05.ld`；`tcgen05.ld.red`；`tcgen05.ld.spcompress`；`tcgen05.ld.red.spcompress` |
| 9.7.18.8.5 | 748/736 | `tcgen05.wait::ld`；`tcgen05.wait::st` |
| 9.7.18.9.2 | 751/739 | `tcgen05.cp (optional FP4/FP6 container decompression)` |
| 9.7.18.10.10.1 | 823/811 | `tcgen05.mma`；`tcgen05.mma.*.block_scale`；`tcgen05.mma.*.collector::{a,b}::*`；`tcgen05.mma.*.ashift`；`tcgen05.mma.*.decompress::lut::b` |
| 9.7.18.10.10.2 | 830/818 | `tcgen05.mma.sp (plain/block_scale/collector/ashift forms; see full Syntax)` |
| 9.7.18.11.1 | 843/831 | `tcgen05.fence::before_thread_sync`；`tcgen05.fence::after_thread_sync` |
| 9.7.18.12.1 | 844/832 | `tcgen05.commit.*.mbarrier::arrive::one`；`tcgen05.commit.*.sync_restrict::shared::read::mma::a` |
| 9.7.21.5 | 872/860 | `setmaxnreg.inc`；`setmaxnreg.dec` |

### 4.1 Tensor 与异步族关键语义

- `wmma`、`mma`、`wgmma`、`tcgen05` 为不同家族，不能互借参与者、operand layout、target 或 completion 规则。warp `mma` 也不代表所有标量/打包 `fma` 和 `dp4a` 应路由到 Tensor。
- 非 bulk `cp.async`：全局到 shared 拷贝、每线程 async-group；`wait_all` 还提交当前未提交组（PDF 351–352/印 339–340）。bulk/TMA 则按具体方向采用 `mbarrier::complete_tx::bytes` 或 bulk-group，不能用一个 wait 泛化全部异步服务。
- `cp.async.bulk.tensor` 的 tensor-map 对象、`tensormap.replace`、`tensormap.cp_fenceproxy`，与 tcgen05 的 SMEM matrix descriptor 不同。修改 tensor-map、生产 SMEM、观察 TMA 完成、SMEM-A read 完成和 MMA full completion 是不同事件。
- `fabric.try_{get,put,red,pullred}`、`fabric.submit`、`fabric.wait` 六条已完整收录（PDF 399–409/印 387–397）。Fabric 在 PTX 9.3 引入，本清单“9.4 包含”不等于全部“9.4 新增”。CFT handle 是fabric命名/访问对象，不是SMEM/TMEM地址或普通global指针。
- `fabric.submit` 必须在跟踪这些操作的 mbarrier phase 推进前提交。`fabric.wait.sync_restrict::reads` 仅等待 submitted 操作的本地 shared 读取，允许重用源缓冲，不承诺远端访问/完整操作完成；get 本来不读本地shared。
- CTA `barrier`、warp barrier、cluster arrive/wait、SMEM mbarrier、griddepcontrol、clusterlaunchcontrol 是不同作用域/对象与生命周期。mbarrier 对象是 shared 中 opaque `.b64`、8B 对齐；不能只放抽象完成token。remote cluster 支持的 mbarrier 操作集合有限，不能把 local wait 自动扩为remote wait。
- `tcgen05.ld` 同节包含 `ld.red`、`ld.spcompress`、`ld.red.spcompress`（PDF 743–745/印 731–733）；后两条 PTX9.4 compression 形式仅 `sm_107a`，不继承全部 tcgen05 target。`ld.red` 早于9.4。
- `tcgen05.wait::ld/st` 只等待同线程先前相应传输；MMA/cp/shift 的完整完成按 commit+mbarrier；`tcgen05.commit...sync_restrict::shared::read::mma::a` 仅 MMA 的SMEM-A读取，不能释放 B/D/full 责任。commit 不是 blocking drain。
- collector `use` 允许机会式复用；未保证命中，源仍需满足潜在重读生命周期。稀疏metadata与microscale的逻辑K/压缩K不能按统一ceil公式猜测。详见已有 [tcgen05 architecture audit](../../tcgen05/research/ptx94_architecture_audit.md)。
- 原文编辑一致性待核项：PDF832–833/印820–821中，`tcgen05.mma.sp.kind::ti16` 的collector形式Syntax未列 `[sp-meta-tmem]`，而同节普通integer形式列出该operand，sparse章节也定义metadata；已视觉核对PDF832。清单保留原文，不能据此删除Ti16 sparse metadata，也不擅自补写可汇编语法。
- 运行时 `setmaxnreg` 与编译directive `.maxnreg` 分开；`alloca/stacksave/stackrestore` 属函数local stack，非共享内存/TMEM分配；video寄存器指令也不能因为现代CUDA少见而从ISA覆盖表中删掉。

### 4.2 别名、弃用形式与目标差异

- `bar` 对应 `barrier.aligned` 的相应形式，`.cta` 可选拼写不构成额外物理barrier资源（PDF 442/印 430）。
- `membar` 在 `sm_70+` 为 `fence.sc` 同义形式，`gl` 对应 `gpu`；该结论不能扩展成所有 proxy fence 互换（PDF 447/印 435）。
- `shfl` 与 `vote` 的 deprecated 形式仍是本版文档内容，清单保留其 target 与成员/收敛约束，不能默认与 `.sync` 形式相同。
- `.s8x4/.u8x4` 等打包整数形式、混合/alternate打包浮点形式必须按各自Syntax与Target Notes检查。尤其 alternate `mul` 的部分 x4 形式在 PDF254/印242 的target范围为 `sm_100a/sm_103a`，不能因文档包含107系列就宣称默认支持。
- `sm_XXa` 和 `sm_XXf` 的architecture/family范围不可按数字大小直接取并集；同一标题下新增类型、block size、swizzle、report、multicast位数等可有不同target条件。每项JSON保留原始Target Notes用于二次筛选。

### 4.3 PTX ISA Notes 明确提到 9.4 的说明节

这是原文版本注记索引，既包含新增指令，也包含既有指令新增类型/限定符；不会把该列表全部称为9.4新增opcode。具体新增内容与target条件见JSON同节原始Notes。

| 节号 | PDF/印刷页 | 指令标题 |
|---|---:|---|
| 9.7.5.1 | 241/229 | `add` |
| 9.7.5.2 | 242/230 | `sub` |
| 9.7.5.3 | 244/232 | `fma` |
| 9.7.5.4 | 246/234 | `mul` |
| 9.7.6.1 | 247/235 | `add` |
| 9.7.6.2 | 250/238 | `sub` |
| 9.7.6.3 | 252/240 | `mul` |
| 9.7.6.4 | 254/242 | `fma` |
| 9.7.7.1 | 258/246 | `set` |
| 9.7.10.8 | 294/282 | `ld` |
| 9.7.10.16 | 316/304 | `prefetch`, `prefetchu` |
| 9.7.10.18 | 319/307 | `applypriority.async.bulk` |
| 9.7.10.19 | 320/308 | `applypriority.async.bulk.tensor` |
| 9.7.10.24 | 327/315 | `cvt` |
| 9.7.10.28.4.1 | 352/340 | `cp.async.bulk` |
| 9.7.10.28.4.2 | 358/346 | `cp.reduce.async.bulk` |
| 9.7.10.28.4.3 | 362/350 | `cp.async.bulk.prefetch` |
| 9.7.10.28.4.5 | 365/353 | `multimem.cp.reduce.async.bulk` |
| 9.7.10.28.5.5 | 372/360 | `cp.async.bulk.tensor` |
| 9.7.10.28.5.6 | 379/367 | `cp.reduce.async.bulk.tensor` |
| 9.7.10.28.5.7 | 382/370 | `cp.async.bulk.prefetch.tensor` |
| 9.7.10.30 | 391/379 | `spcompress` |
| 9.7.10.31 | 394/382 | `spdecompress` |
| 9.7.15.5 | 449/437 | `atom` |
| 9.7.15.6 | 455/443 | `red` |
| 9.7.15.16.14 | 482/470 | `mbarrier.expect_tx` |
| 9.7.15.16.15 | 483/471 | `mbarrier.complete_tx` |
| 9.7.15.16.16 | 485/473 | `mbarrier.arrive` |
| 9.7.15.16.17 | 487/475 | `mbarrier.arrive_drop` |
| 9.7.16.5.15 | 597/585 | `ldmatrix` |
| 9.7.18.7.1 | 738/726 | `tcgen05.alloc`, `tcgen05.dealloc`, `tcgen05.relinquish_alloc_permit` |
| 9.7.18.8.3 | 742/730 | `tcgen05.ld` |
| 9.7.18.10.10.1 | 823/811 | `tcgen05.mma` |
| 9.7.18.10.10.2 | 830/818 | `tcgen05.mma.sp` |
| 9.7.18.10.10.3 | 837/825 | `tcgen05.mma.ws` |
| 9.7.18.10.10.4 | 840/828 | `tcgen05.mma.ws.sp` |
| 9.7.18.12.1 | 844/832 | `tcgen05.commit` |

## 5. 第11章 directive 附表（不计入指令）

这些是汇编/模块/入口/链接/调试/资源约束声明。它们可影响实现配置，但不是发射到执行管线的独立opcode；`.alias`尤其不能和运行时复制/跳转操作混淆。

| 节号 | PDF/印刷页 | directive标题 |
|---|---:|---|
| 11.1.1 | 909/897 | PTX Module Directives: .version |
| 11.1.2 | 910/898 | PTX Module Directives: .target |
| 11.1.3 | 916/904 | PTX Module Directives: .address_size |
| 11.2.1 | 917/905 | Kernel and Function Directives: .entry |
| 11.2.2 | 919/907 | Kernel and Function Directives: .func |
| 11.2.3 | 922/910 | Kernel and Function Directives: .alias |
| 11.3.1 | 923/911 | Control Flow Directives: .branchtargets |
| 11.3.2 | 924/912 | Control Flow Directives: .calltargets |
| 11.3.3 | 925/913 | Control Flow Directives: .callprototype |
| 11.4.1 | 928/916 | Performance-Tuning Directives: .maxnreg |
| 11.4.2 | 928/916 | Performance-Tuning Directives: .maxntid |
| 11.4.3 | 929/917 | Performance-Tuning Directives: .reqntid |
| 11.4.4 | 930/918 | Performance-Tuning Directives: .minnctapersm |
| 11.4.5 | 931/919 | Performance-Tuning Directives: .maxnctapersm (deprecated) |
| 11.4.6 | 932/920 | Performance-Tuning Directives: .noreturn |
| 11.4.7 | 933/921 | Performance-Tuning Directives: .pragma |
| 11.4.8 | 934/922 | Performance-Tuning Directives: .abi_preserve |
| 11.4.9 | 935/923 | Performance-Tuning Directives: .abi_preserve_control |
| 11.4.10 | 937/925 | Performance-Tuning Directives: .minperctamemory |
| 11.5.1 | 938/926 | Debugging Directives: @@dwarf |
| 11.5.2 | 939/927 | Debugging Directives: .section |
| 11.5.3 | 941/929 | Debugging Directives: .file |
| 11.5.4 | 942/930 | Debugging Directives: .loc |
| 11.5.5 | 944/932 | Debugging Directives: .loc_intermediate |
| 11.5.6 | 945/933 | Debugging Directives: .nv_intermediate_source_section |
| 11.6.1 | 947/935 | Linking Directives: .extern |
| 11.6.2 | 947/935 | Linking Directives: .visible |
| 11.6.3 | 948/936 | Linking Directives: .weak |
| 11.6.4 | 949/937 | Linking Directives: .common |
| 11.7.1 | 950/938 | Cluster Dimension Directives: .reqnctapercluster |
| 11.7.2 | 951/939 | Cluster Dimension Directives: .explicitcluster |
| 11.7.3 | 952/940 | Cluster Dimension Directives: .maxclusterrank |
| 11.8.1 | 953/941 | Miscellaneous Directives: .blocksareclusters |
| 11.8.2 | 954/942 | Miscellaneous Directives: .language |

## 6. 覆盖结论与限制

已完成“全章目录—PDF书签—正文节号—Syntax块”的结构性全量交叉核对。215个实际指令说明节均保留原始Syntax与PTX/target说明；所有21个§9.7类别均有记录，stack/control/video/fabric/texture/surface及深层async/Tensor族均未排除。

这是规范目录与架构职责审查，不是每个合法tuple的可执行验证，不等于本项目已有全部指令RTL，也不代表一种SM应同时实现所有历史与future/family-specific target。后续SM主文应给出选定target/profile的实现、软件展开、外部服务与显式不支持矩阵，再从本清单逐节链接回证据。

## 7. 可复现核验与正文覆盖

[核验脚本](../check_instruction_inventory.py) 依赖 PyMuPDF，默认从 JSON 中读取上传 PDF 路径；也可显式指定：

```bash
python docs/sm/check_instruction_inventory.py --pdf /path/to/ptx_isa_9.4.pdf --require-document
```

脚本重建 PDF 书签编号、核对正文标题、217 个 Syntax 块与全部 651 份 Syntax/ISA Notes/Target Notes 摘录，并检查 215 个指令说明、2 个控制语法、21 个类别。报告写入 [instruction_coverage_check.json](instruction_coverage_check.json)。`--document` 可指定正文路径；默认是 `docs/sm/SM_ARCHITECTURE.md`。

正文逐节映射需要 Markdown 表格中独立的节号单元格，以及至少两个非空内容单元格，例如 `| 9.7.1.1 | add | 整数执行服务/所需合法化 |`。散文引用、节号范围和 TODO 占位不算覆盖。源码与目录核验通过、正文尚不存在时，状态为 `pending_document`；使用 `--require-document` 后正文缺失或覆盖不完整都会失败。

第10章另外35节特殊寄存器说明索引见 [特殊寄存器目录](ptx94_special_register_inventory.md)，它们不加入 opcode 计数。脚本独立核对该索引；增加 `--require-special-registers` 可要求正文同样逐节映射这些状态。

## 8. SM主文独立内容复核（2026-11-07）

复核对象：`docs/sm/SM_ARCHITECTURE.md` 第1、3、15、16、20、25、26章；本次读取快照 SHA-256 为 `b28eaee5bf381c7dbcc8387687c62bc8030eb722935e11774cf3eaecb20fb0ba`。这是规范与架构文本审查，不是新增SM RTL仿真。

- 第26章217个指令说明/控制语法映射和35个特殊寄存器映射，已独立逐行核对节号、名称及PDF/印刷页码，与两份机器索引一致；无遗漏、重复或元数据错配。217/215/2、21类别、240名称出现与210唯一标题标签的统计口径保持一致，不宣称全部合法tuple已实现。
- 第3章将 `sm_*a/sm_*f`、各形式target、项目SM-ARCH-S0和实现状态分开。旧矩阵家族不自动视为新产品原生能力，alternate packed算术不误作dot，Ti16 raw与未闭合服务保持capability关闭。
- 第3.3章已保留别名成立的条件：bar对应barrier.aligned；sm70+ membar对应fence.sc及scope名称映射；经典wait_all包含commit；.alias属于编译/链接符号机制。第20章把directives、pragma、特殊寄存器与执行opcode分别处理。
- 第15章区分经典cp.async group、bulk-group、TMA/mbarrier及局部读取完成；st.bulk为shared置零，st.async/multimem异步写按具体空间/顺序形式处理。matrix descriptor、tensor map、报送layout与目标限制未混用。
- 本次发现的C seed映射问题已复核关闭：enable-input-d=false时不读旧D、提供零seed；true时传未缩放D_old/C和独立c_scale_shift，规定形式的scale-input-d只作用于C。第16.2章明定在解码/指数/累加路径处理C shift，防止先打包引入额外舍入/下溢，并防止重复缩放。只读检查现有MALU配置字段、合法性判断及指数减法与该描述相符。
- normal/full、restricted SMEM-A read、TMEM ld/st等待仍是独立完成域；PROJECT_EXACT与原生Tensor/标量精度契约保持区分。第25章列出的本地证据链接均存在，未把历史网页快照称为本轮联网成功。

结论：**指定范围内无残留阻断项，可冻结架构文本。** 最终发布应在最后一次主文修改后运行核验脚本，使coverage报告中的document SHA与交付文本一致。本结论不扩大既有MALU验证范围，不声称全SM实现或全部tuple兼容性已经通过。
