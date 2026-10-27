# SMEM 服务端、顺序与共享仲裁审查建议

日期：2026-10-27。负责人：agent3。状态：项目拟议方案与反例审查，未实现或仿真。

本记录仅补 SMEM 服务端，不改主文、图、RTL 或 README。物理 bank、队列、端口、信用和缓存失效方案均为本项目选择，不是 NVIDIA 已公开实现。PTX 语义仍依 [架构文档](../../TCGEN05_TENSOR_ARCHITECTURE.md)及[PTX 核查](../../research/ptx94_architecture_audit.md)；尤其 tcgen05.mma/cp 的 SMEM 读取属于 async proxy，不能因为共享同一个 SRAM 就省略跨 proxy 顺序。

## 1. SMEM 是多 client 共享的执行资源

每 endpoint 建议一份 256 KiB 物理 SMEM，供 LSU、TMA、Tensor、peer DSM 与 barrier 服务共享；不是 Tensor 私有的 256 KiB operand SRAM，也不与 TMEM 容量相加后作为某个 CTA 的可用共享内存。

| 固定基线 | 值 | 含义 |
|---|---:|---|
| physical SMEM / endpoint | 256 KiB | 不自动等于 target 对软件承诺的最大 CTA shared size |
| bank 组织 | 64×1024×32 bit | 每 bank 1R1W；raw 合计 262,144 B |
| resident CTA owner slots | 最多 8 | 受 SMEM、寄存器、warp 等共同 admission 约束 |
| Tensor 请求接口 | 最多 2×128 B/cycle | 两个独立 packet；bank 无冲突时才可能同时服务 |
| Tensor outstanding tags | 32 | 已接受请求的身份和乱序返回跟踪 |
| Tensor return staging | 8×128 B | 1 KiB；不是 32 个请求各自都有免费返回空间 |

TMA tensor map 的 global/shared 多维搬运、普通 LSU 的 CTA-local load/store、Tensor SMEM descriptor 读取是不同客户协议。服务端将它们归一到 SMEM cell 请求，不把 TMA tensor map 当作 tcgen05 matrix descriptor。

## 2. 物理映射与 peak 的正确口径

对 endpoint 内物理 byte address p：

    byte_in_word = p[1:0]
    bank = p[7:2]
    bank_row = p[17:8]

word address 共 16 bit，bank 6 bit、row 10 bit；映射唯一。每周期最多读 64×4=256 B，另可写最多 256 B，但还受同地址冲突、原子操作、包重放与服务公平限制。

对齐 128 B 访问覆盖 32 banks；相邻、互补的两个 128 B 读包可覆盖全部 64 banks。两个包若落同一组 bank 的不同 row，则不能同周期都读完。因此“Tensor 2×128 B/cycle”只是共享 fabric 的接口和无冲突上界，不是每拍固定交付，更不是加上 LSU/TMA/peer 后仍免费拥有总和峰值。

同 bank 不同行可同时 1R+1W；同 cell 的 read/write 建议保守串行，或由明确 byte-forwarding 规则处理。普通 masked write 不能默认先全 word 读改写而占两个隐蔽端口；实现若没有原生 byte write mask，必须把额外 read/merge 记入 bank 占用。

atomic/barrier 多 word 更新应预留其参与 words，按有序 bank/row 组合执行。不能把 mbarrier 的读改写退化成普通两个无锁 store，也不能锁整个 SMEM 等其他 client 的软件动作。

## 3. CTA launch 分配、地址翻译与归属

SMEM 在 CTA launch 时按 static+dynamic shared size 分配，不仿照 TMEM 的 tcgen05.alloc 运行时接口。建议以 256 B 为物理分配粒度，1024-bit bitmap 共 128 B；owner table 8×64 B。

每个 owner 记录 physical base、实际字节长度、generation、kernel/cluster identity、capability 与 outstanding refs。软件可见 CTA-local address 经 owner translation 形成物理 p；matrix descriptor 中的地址片段仍表示对应 CTA 的 SMEM 对象，不直接暴露别的 CTA 的物理 base。

边界检查在完整 local range 上进行，再做截位／bank 计算。不能先用 descriptor mask 截到 18 bit 再检查，否则越界地址可能环绕到其他 owner。peer DSM 同样通过目的 CTA rank→endpoint/owner/generation 映射，而非“远端 base 加本端偏移”的猜测。

8 CTA 是 slot 上限，不保证能同时驻留 8 个最大 SMEM CTA。若一个 CTA 使用全部可暴露容量，其他 launch 必须等资源；不能每 CTA 固定切 32 KiB 后仍声称支持更大的合法 CTA shared size。

core admission 应一次检查 warp/register/SMEM 和 Tensor owner credit。CTA2/cluster 需要的 peer launch 信用也应按系统合同保留，避免已经 launch 的 CTA 永远等一个因资源被它自己占住而无法 launch 的 peer。

barrier 对象占用的 shared bytes 计入相应 owner 的合法地址空间；服务元数据可在外部 table，但不能把 barrier data 另算成不占软件 SMEM 的免费存储。

## 4. 可落地的服务接口

### 4.1 packet 身份

建议 normal request header 至少包含：

- client_id、READ/WRITE/ATOMIC/BARRIER 服务类型、client tag；
- owner slot/generation、kernel epoch、必要的 remote destination；
- packet 的逻辑子序号、最后片段标志、return route；
- 最多 32 个 32-bit cell 的 local 地址与 byte mask；
- ordering/proxy ticket 的引用，而不是把所有客户都放到一个全局顺序 FIFO。

128 B 是 data payload 上限，不包含所有地址元数据。32 个 gather cell 的 18-bit 地址约 72 B，另有 masks/header；写数据应走配对 payload 通道或独立 payload buffer，不能宣称一个 128 B 总线同时无损承载整包地址和 128 B 数据。

更大的合法 warp/TMA 操作拆成 packet，parent 在全部 packet ack 后才完成。普通 packet 不超过 128 B；LSU 宽 warp 可用至多 256 B 的紧凑地址形式，否则拆成两个以上 packet，不把合法操作简单判非法。Tensor 仍保留 32 tags，返回可乱序，tag 在最后对应 response 被接受前不得复用。

256 B LSU payload 不可能再免费附带任意 32-thread 地址向量：若地址不能以 base/stride/mask 等已定义 recipe 压缩，必须拆包，或把额外元数据预算列清。请求地址／replay recipe 保留至所有 bank 子请求已得到归属，不能过早释放 ReqQ 条目后失去重放地址。

### 4.2 接受与完成

request accepted 表示服务端已捕获完整 packet／payload 并取得有限记录，不表示 bank access 已结束。read completion 是全部 cell 数据进入保留 response slot；write completion 是全部 byte mask 真正提交 bank；atomic/barrier completion 由其专门服务合同定义。

response 携带原 client tag、owner generation、epoch、fragment identity、有效字节与项目诊断状态。valid 阻塞时全部 payload 稳定。软件可见异常不由此凭空增加；非法程序行为与内部诊断应在文档中分开。

## 5. 有界队列与 credit 建议

与主 agent 已统一为以下服务端配置，不替代 Tensor-side 32 tag/8 return：

| client | request queue | 服务端 RAS 保留 credits | 隔离目标 |
|---|---:|---:|---|
| Tensor | 16×128 B | 32 | 其余 tag 可处于 bank 在途／已组装返回阶段 |
| LSU | 8×256 B | 8 | 本地 load 不被大 TMA burst 占满 |
| TMA | 8×256 B | 8 | 超过窗口的 burst 分段并回压 |
| peer DSM | 8×256 B | 8 | 返回身份含远端 owner |
| barrier/control | 8×64 B | 8 | 保留 completion／allocation-return／barrier 进度 |

全局 RAS 为 64×256 B data 加 64×32 B metadata，合计 18 KiB；32+8+8+8+8=64 个保留 credits。RAS 是服务端 response assembly，Tensor-client 8×128 B return staging 是下游另一处存储，二者不能混称相同深度。

accept 前同时占 ReqQ、对应 RAS slot 和完整返回责任；write 也必须捕获已转移所有权的 payload。没有信用时不接受，不能接受后要求上游继续保留已经归属服务端的数据。

read 拿到 RAS 和下游 route identity 后才向 bank 发首个 cell。RAS partial-valid mask/replay cursor 与原 tag 绑定；服务端已有 32 个 Tensor assembly credits，并不说明客户端同时有 32 个 return slots。客户端反压时完成数据留在相应 RAS，不能覆盖尚未消费的响应。

一个 client 被反压时最多占本类 RAS slots，不持有 bank 端口，不借走 control 的最后保留信用。RAS 在整个 packet response 被相应 client 接受后归还；更大 parent 操作的完成另由全部 packet ack 决定。

额外 RMW 状态为 4×64 B，bank lock table 为 64×32 bit。64-bit atomic/mbarrier 的双 bank 预约为 all-or-none；PTX 9.4 的 atom 示例实际包含 atom.shared.b128.cas [P1，PDF455/印443]，若服务端宣称支持它，还需 4 个 32-bit banks 一次预约，不可将双 bank 当成全部 LSU 原子宽度。暂未支持的宽度明确 capability-gate。

## 6. 公平仲裁与 bank 调度

建议两级调度：client packet scheduler 选有出口信用的包；bank scheduler 对其未完成 cells 仲裁。避免要求一个 gather packet 的全部 banks 同拍空闲才能开始，允许已 grant 的 cell 前进，其余重放。

可采用每 bank 分读／写的 deficit round-robin，示例 weights 为 LSU:TMA:Tensor:peer:barrier = 4:2:4:1:1。weights 只是本项目共享策略，不给每 client 同时峰值。空闲份额可借用；出现高龄可执行请求时必须优先服务，不能让 Tensor 连续预取饿死 LSU。

barrier/control 有保留入队与返回信用，但不应无限严格优先。建议连续控制 grant 最多 2 次后，若存在可执行老数据请求，至少让出一次；已承诺 atomic 操作的不可分割段例外要有界。

writeback／TMA completion 所依赖的既有写包应有年龄提升；不能只优先新 read 而永远不提交完成需要的 store。fairness 的前提是目的端最终接受响应、peer 最终 ack；外部永久不响应不属于内部可以凭仲裁修复的情形。

相同 owner/generation、相同 cell 和兼容顺序的读可广播；不同 memory version 的读不得为了合并而丢掉 ordering ticket。写合并只在 byte masks 和顺序允许时进行，不能让后写覆盖尚未提交的先写后仍报告两个独立完成。

## 7. SMEM store → Tensor async proxy

### 7.1 至少区分三个时点

1. store 被 LSU/TMA 接受；
2. 对应 bytes 真正 bank-committed；
3. 程序要求的跨线程／proxy 顺序已经发布，Tensor 消费者可按该关系读取。

三者不能合成一个“SMEM ready”位。一个 packet committed 不等于整个 producer 的前序 stores 完成，更不等于其他线程也已经发布。

建议 core/LSU/TMA 向服务端提供不可变的 producer completion/order ticket；fence 捕获其应覆盖的既有写入 cutoff，而不是不断等待“当前所有 outstanding”。后来的 store 不能延长已经接受的 fence。

generic-proxy stores 经过规定 fence.proxy.async 及线程交接后，Tensor 才按该 published ticket 使用 async-proxy 源。若多个 warp 共同产生矩阵，一个 warp 的 fence 不能自动声称覆盖所有未同步的 producer；必须遵守各线程的同步／可见性合同。

TMA 写 SMEM 的路径先完成相应数据写入，再产生其规定的 completion；consumer 等待并建立适用线程／proxy 顺序。不要机械地给所有 TMA 情况都加同一 generic→async fence，也不要把 tcgen05.wait::ld 当成 TMA completion。

### 7.2 可执行反例

| 错误做法 | 反例 |
|---|---|
| LSU 入队就发布 SMEM version | Tensor 高优先读先于尚未仲裁到的 store，读到旧值 |
| fence 等“全 CTA 当前 outstanding” | 其他 warp 不断增加 store，早先 fence 永不结束 |
| 一个 producer fence 覆盖所有 warps | 另一 warp 的部分矩阵尚未写入，Tensor 读取半新半旧 |
| TMA barrier 在最后写包仅被接受时 arrive | consumer wait 成功但 bank 中仍有旧数据 |
| 只做 bank forwarding，无 proxy 合同 | 偶然新值被误当作合法跨 proxy 可见性保证 |

Tensor request 的 visibility ticket 是内部依赖，不是新增 PTX 寄存器。无法提供细粒度 ticket 时，可以保守串行／等待正确的 producer 发布，但不能省略架构 fence。

## 8. collector 失效、版本和不可变快照

服务端提交 SMEM write 时更新权威 owner/version，并产生 future-reuse invalidation。cache tag 至少包含 owner generation、source range／descriptor、格式/layout 和 published visibility epoch。

保守首版可按 owner 整体失效，正确但可能让 barrier object 等不相关写入也降低 reuse 命中。更高性能可按 source range／sector 精化，必须覆盖 masked store、TMA、peer 和 barrier 的实际 bytes。

正确性不应依赖一条可能长期堵在 Tensor normalCQ 的 invalidate 消息。建议权威 version 存在 SMEM owner metadata，reuse lookup 检查该 version；sideband invalidate 用来加速失效。写 ack／publish 必须保证后续正确排序的 lookup 看得到新 version。

主配置的 visibility notification 为 16×32 B，超出时对相关写入回压。通知信用必须在 write commit 或 RMW bank-lock 取得之前预留，不能先持原子锁再等通知队列空位。接收端只更新版本／future-reuse，不等消费者、Tensor normalCQ 或 active snapshot 释放，否则通知反压又会形成控制环。

首版每包可用 owner 级通知，避免用 32 B 假装保存任意 32-cell dirty 地址表。多写合并只能在各自 publish 责任仍被覆盖时进行；更精确 range 失效须另计地址／sector 元数据。

invalidation 只清未来 reuse_valid，不能销毁 active snapshot/refcount。A-read restricted event 后源 A 可以按合同被改写，但正在计算的 MMA 必须继续读自己的 immutable A。B cache chunk 也不能在仍有 active read 引用时被新 fill 覆盖。

version 回绕需要显式处理：flush future-reuse entries 并排空相关 lookup 或提升 generation；不能以“32 bit 不易回绕”代替正确性。active immutable snapshot 可继续持原私有版本，其身份不能与新 cache lookup 混用。

**反例：**write 提交后把 A snapshot_valid 清零，恰好先前 MMA 已发 A-read done、尚未写 D，后续计算丢失唯一合法源。另一个反例是 use miss 从已被违反源保持规则覆盖的 B 重读；collector 不能替软件修复这种非法程序。

## 9. barrier、peer 与完成路径隔离

mbarrier 服务操作 shared bytes，同时维护自己的 phase／arrival 语义；它是 fabric client，不是一条“绕过物理 SMEM 的免费成功消息”。但其控制／返回 credits 必须独立于 Tensor operand 读队列。

否则 Tensor 等 TMA barrier 完成，TMA barrier 又排在被 Tensor 长读占满的无界队列后，会出现不必要的进度环。有限 burst、独立槽和公平 bank 服务共同解决，单纯给 barrier 一个高优先级标签而没有存储信用不够。

peer DSM 包带目的 CTA generation、request identity 和幂等 retry ID；duplicate ack 不重复写或 arrive。peer 控制／释放 ack 不等待普通远端数据 credit。对一个操作涉及多目标的情况，parent 仅在所有指定目标完成后发布整体完成。

同一个 owner 的 barrier 所在 memory range 不能在有旧 notification 时被另一 CTA 重新分配；对象地址相同不表示 generation/phase 仍相同。

## 10. CTA exit、free 和 drain

正常 CTA exit 请求不立即 free SMEM。建议 owner 进入 EXIT_PENDING，停止新工作，但继续已有责任及释放控制；至少等待：

- LSU 本地 store、atomic 和 load 返回；
- TMA 写／读 packet 及其完成通知；
- Tensor 对 SMEM 的仍可能读取与返回归属；
- peer DSM 请求及远端已承诺访问；
- barrier/alloc-return／invalidation 等关联记录；
- 持有 owner/generation 的其他子系统引用。

随后失效未来 collector reuse，确认 invalidation/version 交接完成，归还物理区间并提升 owner generation，最后将 slot 交给新 CTA。Tensor 父操作若仍依赖 owner 的其他生命周期对象，不得只因 SMEM A-read 完成就把整个 owner 提前回收。

bank commit 前核对仍有效的 owner generation，防止旧写响应在同一物理地址复用后覆盖新 CTA；但正常协议仍应先 drain，不能用“丢弃旧写”冒充原 kernel 正常完成。

soft drain 保留当前 kernel 完成所需数据／barrier／exit 控制。kernel abort 则按系统协议取消未开始请求、确认已承诺 side effects 后回收；不能只清 request FIFO 指针。peer 丢失／外部不响应要升级异常处理，不无限等待后又伪造普通成功。

可选 scrub queue 为 8×16 B，scrub 也消费共享写带宽，不是免费端口。最简单安全策略是在 allocation 发布给新 owner 前完成 scrub；若采用后台 scrub，则 owner/generation 匹配以外还要处理同一 owner 的新 store 覆盖，例如 word write-version／写入取消，不能随后用零覆盖新数据。8 项 scrub queue 本身不等于已经拥有整片 SMEM dirty bitmap。

## 11. raw 资源核算与审查清单

| 建议项 / endpoint | 原始容量 |
|---|---:|
| SMEM cells | 64×1024×4 B = 256 KiB |
| launch bitmap＋owner records | 128 B＋8×64 B = 640 B |
| TensorReqQ | 16×128 B = 2 KiB |
| LSU/TMA/peer ReqQ | 3×8×256 B = 6 KiB |
| barrier/control ReqQ | 8×64 B = 0.5 KiB |
| RAS data | 64×256 B = 16 KiB |
| RAS metadata | 64×32 B = 2 KiB |
| RMW＋bank locks | 4×64 B＋64×32 bit = 0.5 KiB |
| visibility notifications | 16×32 B = 0.5 KiB |
| optional scrub queue | 8×16 B = 0.125 KiB |
| Tensor client return staging | 原方案 8×128 B = 1 KiB，不能重复算成服务端槽 |

以上 SMEM 之外的明确容量合计 29.25 KiB，其中 1 KiB 是原 Tensor-client staging；若在 Tensor 资源表已经计过，不在总预算重复加。队列之外尚有 bank arbitration、cell masks、version、atomic/barrier 状态及 ECC 等开销；上述不是面积或 PPA。Tensor request 地址元数据也不是 128 B 数据端口的免费附属物。

必须验证的不变量：

1. owner-relative range 验证先于物理截位与 bank 访问。
2. accepted read 有确定 assembly/route credit，accepted write 已捕获 payload。
3. 一个 client 反压不占其他 client 的保留槽，不锁 bank 等软件消费。
4. bank commit、producer completion 和 proxy publish 分别记账。
5. invalidate 不能销毁 active snapshot，future reuse 不命中旧 published version。
6. CTA free 前所有跨服务引用归零，旧 generation 不写新 owner。
7. 峰值按共享 bank 总预算核算，不把所有客户峰值相加。

建议反例回归：所有客户请求同一 bank；两个 Tensor 128 B 包落同半 banks；barrier 在 TMA 尾写后到达；8 个客户端 return slots 全反压而32个Tensor RAS被占用；RAS64 partition不被借空；多 warp producer fence；visibilityQ满时RMW；A-read 之后覆写 A；slot reuse 时旧 peer write；CTA2 peer exit；version 回绕与 soft/abort drain。

本轮没有实现 SMEM server 或运行新 RTL，以上是可实现的接口／信用方案与审查点，不是无死锁证明。

本轮仅作轻量算术复核：枚举 65,536 个 SMEM words 得到同数量互异 bank/row 坐标，确认 256 KiB 映射；各存储项独立重算得到上述 29.25 KiB 小计。这不是仲裁、proxy 顺序或完整系统的仿真结论。

## 12. 对 v1.1 主文 §7.2–7.9 的快速只读复核

审查对象为主微架构文档已落盘的 SMEM 服务端小节及其资源表。主文新增 64×32 B producer records，比本记录初稿预算增加 2 KiB；主文的最终服务端资源应以该新增项一起计数，不能继续把早期 29.25 KiB 当作完整 v1.1 开销。

### 12.1 已核对一致的合同

| 项目 | 主文实际内容 | 结论 |
|---|---|---|
| SMEM 归属 | core 共享 256 KiB、LSU/TMA/Tensor/DSM/barrier 多 client；独立于 TMEM | 没有把 SMEM 画成 Tensor 私有存储 |
| launch | 8 owner、static/dynamic/reserved 分开、visible bytes 与 allocation bytes 分开 | 不固定均分 32 KiB；不重复计算声明内 barrier |
| bank | 64×1024×32 bit，1R1W，physical 地址在 owner 翻译后计算 | 容量与共享峰值核算一致 |
| ReqQ | Tensor16×128 B，LSU/TMA/peer 各8×256 B，control8×64 B | 明确宽 LSU 拆≤128 B packet，不免费叠加地址 |
| RAS | 64×256 B data＋64×32 B meta | 接收前预约，不靠客户端8槽假装无限响应 |
| RAS partitions | Tensor32、其余4类各8 | 共64；write-only也保留terminal ack |
| producer | 64×32 B、bank-commit／visibility两prefix及8-bit windows | admission限制visibility距离；非只看bank写完 |
| cutoff | 有序点捕获不可延长cutoff，完成失效接受后发布 | 后发写不改变已经接受的fence集合 |
| RMW | 4 contexts、多bank全有全无、预留visibility与response | 不持一把bank锁等待另一把或通知空间 |
| collector sink | 不等Tensor CQ／消费者，future reuse与active snapshot分开 | 已关闭主要invalidate反馈环 |
| 原子宽度 | 64b双bank，128b CAS需四bank并独立capability | 不把双bank当作全部LSU atomics |
| CTA exit | LSU/TMA/Tensor/peer、RMW、RAS、barrier、失效均drain | 不只清owner valid，不让旧generation写新owner |

返回slot保存至客户端接受、parent等待全部packet完成、proxy可见性不被普通store ack替代、mbarrier真实shared对象更新后才ack，主文均已明确。本轮范围内未发现ReqQ/RAS深度相加、固定credit总数或256 KiB容量的计算错误。

### 12.2 唯一需要补明的 scrub 反例

定位：主文 §7.6 的 corrected-read 延迟 scrub。

如果只在新写提交时匹配“当前已经排入8项scrub队列”的地址，仍有如下间隙：

1. t0：读取旧word，得到可纠正的旧值；
2. t1：新store写入新值，但旧scrub尚未排队；
3. t2：旧read的scrub迟到入队，队列中没有记录曾发生t1；
4. t3：仅按owner/generation匹配，旧corrected value覆盖新值。

最简单的关闭方式是：scrub取得word/RMW锁后重新读取当前word，重新ECC检查／纠正，只写本次锁内读到的当前数据，不能直接写回旧read携带的缓存值。这可以复用现有RMW，不要求全SMEM逐word version RAM。

另一种正确方案是从旧read尚在途时就登记所有correction责任并对同址写snoop，直至其scrub结束；仅snoop已入队条目并不够。主文可择一明确，避免将“队列地址匹配即可”解释成存在上述间隙的实现。

除该scrub文字合同外，未发现本轮指定范围中的其他必须修正项。本记录不修改主文，已将该建议通知主agent；没有运行新SMEM RTL或宣称无死锁证明。

### 12.3 修订后的关闭复核

已再次只读核对主文 §7.6：scrub queue 只保存地址／owner 与重验责任，取得 RMW 锁后重读当前 word、重新检查 ECC，只写当前值的纠正结果；不写回早先缓存的 corrected value。队列同址取消仅是优化，旧 ticket 在新 store 之后迟到入队也不会覆盖新值。owner exit 可取消未开始的可选 scrub，已开始 RMW 仍须 drain。因此 §12.2 所提文字合同问题已关闭。

同时确认 §7.7 已明确：collector ack 只能在 future lookup 实际可观察失效／版本变化后产生，不能仅以 FIFO 接受代替；proxy publish 等待实际应用确认。此澄清与 immutable active snapshot、visibility prefix 和 producer cutoff 合同一致。

本轮指定 SMEM 控制审查范围内，已无仍需阻止文档成文的确定问题。结论限于文档审阅，不扩展为新 SMEM RTL 仿真、无死锁证明或工艺验证。
