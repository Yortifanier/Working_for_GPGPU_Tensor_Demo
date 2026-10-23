# Rubin 来源交叉核验与替代检索记录

核验日期：2026-10-23。原始数值与推导分开记录；搜索结果不等于文章全文。

## 已取得的直接证据

| 来源 | 实际读取位置 | 可以支持的结论 |
|---|---|---|
| [NVIDIA Vera Rubin NVL72 产品页](https://www.nvidia.com/en-us/data-center/vera-rubin-nvl72/) | 规格表的 NVIDIA Rubin GPU 单 GPU 列，以及脚注 2/3 | TF32 2、FP16/BF16 4、FP8/FP6 Training 17.5、NVFP4 Training 35 PFLOPS 为 dense；NVFP4 Inference 50 PFLOPS 为 sparse |
| [NVIDIA Technical Blog](https://developer.nvidia.com/blog/inside-the-nvidia-rubin-platform-six-new-chips-one-ai-supercomputer/) | Table 2 与 Table 3 | 50 的脚注为 Transformer Engine compute、35 的脚注为 Dense compute；FP32/FP64 vector 与 Tensor Core-based emulation 另列 |

以上两处是同一厂商的不同页面，不是两次独立硬件实测。归一化推导为：

`TF32 : FP16/BF16 : FP8/FP6 Training : NVFP4 Training = 2 : 4 : 17.5 : 35 = 0.5 : 1 : 4.375 : 8.75`。

不能将 sparse 推理 50 除二后替代已经单列的 dense 训练 35，也不能据此为 I8、Ti16 或每个 scale/BLOCK 组合补写吞吐。

## 已尝试的其他来源

本轮在官方访问恢复前后检查了 ServeTheHome、Tom's Hardware、TechPowerUp、TrendForce 与 SemiAnalysis。早期直接请求在代理 CONNECT 阶段返回 403；这些失败请求没有提供文章正文或可靠脚注，因此不作为性能数据来源。

Bing 搜索和 GitHub 公开页面可访问。部分定向查询没有遵守预期的站点/关键词范围，返回天文 Rubin 或其他无关内容；这些结果已排除，不能仅因为查询中写了 Rubin GPU 就引用其内容。

| 检索渠道 | 证据状态 | 使用方式 |
|---|---|---|
| 第三方媒体直接页面 | 本轮早期请求受网络策略限制，未取得可核验全文 | 不编造文章标题、日期、数字或作者观点 |
| 搜索摘要 | 查询相关性必须逐条检查；未找到足够支持完整比例的独立证据 | 不替代产品表脚注，不标为已读全文 |
| GitHub 公开技术资料 | 可访问性已确认，格式/架构支持不等同于产品吞吐规格 | 不用 README 的格式清单推出峰值比例 |
| 知乎 | 尚未取得可引用的相关全文 | 未将任何知乎观点写成已核验结论 |

官网在本轮已恢复 HTTP 200，所以当前配比可以直接采用完整一手规格。其他来源仍用于后续交叉核验，而非等待其可用才发布已经有依据的结果。

## 访问配置状态

已保留原有域名，并把第三方媒体的必要主机名保存到环境网络配置草案。配置工具返回 `saved` 和 `requires_publish=true`；保存草案本身不证明运行时放行，需要在环境设置审核、保存并发布后重新检查受限页面。

原始官方快照的 SHA-256 与原始/归一化数值保存在 [rubin_product_evidence.json](rubin_product_evidence.json)。网页可能更新，引用以本次实际获取的版本及访问日期为准。
