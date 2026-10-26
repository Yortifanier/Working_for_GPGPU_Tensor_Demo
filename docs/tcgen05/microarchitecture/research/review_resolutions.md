# 微架构 v1.0 审查合并记录

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
