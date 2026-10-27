# 微架构审查合并记录（v1.0–v1.1）

日期：2026-10-26。范围为拟议微架构的规范映射、数值位宽、容量和进度合同。下表记录已经合并到主文的修正；不表示新增 Tensor/PERF RTL、形式证明或 PPA 已完成。

| 审查点 | 最终合同 |
|---|---|
| CTA1 exclusive 跨 pair 串行可能阻塞 cluster barrier | CTA1 仅锁本 endpoint；CTA2 原子锁两端 |
| TMEM-A MMA 在 A-read stream 留孔 | 仅为 SMEM-A MMA 分配该 stream 序号，空集合 commit 可通知 |
| 超过八个不同 allocation 无法靠 hull 合并 | coarse endpoint lease 与每端 18-bit allocation pin mask |
| sparse 跳零遗漏 0×Inf/NaN | PROJECT_EXACT 展开 +0 仍做对应 B 分类及 signed-zero 统计 |
| CQ 重排改变 commit 截止点 | 同 issuer 依动态 ticket 在有序 S0 分序号并捕获 watermark |
| 窗口满阻塞解除等待所需控制 | escape 使用独立资源，不要求空 MCS/异步 OpTable |
| full token 等未来 commit 造成资源耗尽 | 历史写入 prefix 后按引用退休，已接收通知的 metadata 独立保存 |
| prefix 回绕与完成孔洞 | 每 stream 八项模窗口；watermark 到达后 ready 锁存 |
| soft drain 停剩余 tiles/结果 load/dealloc | 继续当前 kernel 所需工作；abort/cancel 另立协议 |
| 16B Event Q 装不下完整通知 | 仅存 generation-checked 指针；完整 metadata 留稳定来源 |
| 六 boosters 同时关闭覆盖局部 scale 状态 | 8×32B scale-job FIFO、每组 hold、P3 捕获前不覆盖 |
| FP4 q-product 位宽/scale signedness | signed9 raw、signed14 blocksum、unsigned8 scale-product、22b magnitude、指数 −2 |
| 砖被高精度与 scale 同拍重复使用 | per-stage reservation，切模式先 drain |
| P5/P6 旧累加状态重复加入 | P5 只压当前 packet，P6 才合并旧 S/C 与一次 seed |
| raw rate 与 dot rate混用 | 140 仅 MX/NV FP4；44 contexts、三个 II1 finalizer 为预算，端到端另验 |
| 供数端口与缓存容量混淆 | A/B 各128B/cycle预算，32在途tags与8返回slots分开，长延迟按rL预算 |

原始审查及复核：

- [ISA/所有权/完成域](isa_to_microarchitecture_review.md)：最终修正复核在第12节。
- [控制与TMEM](control_memory_review.md)：主文复核在第11、12节。
- [算术与资源](arithmetic_resource_review.md)：选中S1与备选时分方案分别记录；备选quota不作为产品峰值实现。

实际参数重算由 `check_design_budget.py` 执行，结果在 [design_budget.json](design_budget.json)。文档结构和抽页目检另存 `document_qa.json`；数值/结构检查不代替硬件验证。

## v1.1：补齐 SMEM 本体（2026-10-27）

v1.0 将 SMEM 当外部服务，仅给 Tensor 端口和缓存预算。v1.1 新增 §7.2–7.9 与 SMEM 图，细化 core 共享服务端，保留 v1.0 DOCX/PDF 和原始 QA。

| 核查点 | v1.1 已合并的合同 |
|---|---|
| 所有权与分配 | static+dynamic(+reserved) 在 CTA launch 分配；SMEM 不使用 TMEM alloc；base 转译先于 physical bank |
| 实体与峰值 | 256 KiB、64×1024×32-bit 1R1W 是项目选择；256 B/cycle 是所有客户端共享、无冲突条件下的单方向峰值 |
| 队列与返回 | client ReqQs + 64×256 B assembly/64×32 B metadata，32/8/8/8/8 credits 保留；宽 LSU 拆包 |
| 地址与数据 | generic/TMA/Tensor 访问同字节对象；swizzle 仅按相应 AGU/descriptor 施加一次 |
| mbarrier | 真实 8B opaque SMEM 对象，原子更新落地后 ack；64b 双bank、128b CAS 需四bank且暂不开放 |
| proxy 与缓存 | bank commit、collector lookup 可见失效、proxy publish 分开；通知 FIFO 接收不冒充已生效 |
| scrub | 取得锁后重新读当前 word 再纠正，防迟到 correction ticket 覆盖新 store |
| 退出 | LSU/TMA/Tensor/peer/barrier/RMW/assembly/失效全部 drain 后才回收 owner generation |

三项独立复核见 [ISA](smem_isa_review.md)、[资源](smem_resource_review.md)、[控制](smem_control_review.md)。重算覆盖 65536 个 SMEM word 的无别名映射、平衡/冲突读示例、312/320 KiB ECC 阵列及服务端容量；这些不是 SMEM RTL 测试。
