# 网络核验记录

日期：2026-10-23（Asia/Shanghai）。

GitHub 原生 Git 只读访问已成功，仓库 main 可读取。NVIDIA 官网请求在代理 CONNECT 阶段返回 403；升级执行权限后的同一官方网页请求仍返回 403。该结果不表示产品网页不存在，也不是 GitHub 账号仍然被锁定的证据。

已在环境配置草案中保留既有预设，并新增以下自定义研究域名：

- www.nvidia.com
- developer.nvidia.com
- docs.nvidia.com
- blogs.nvidia.com
- www.bing.com
- www.zhihu.com
- zhuanlan.zhihu.com

配置工具返回 status=saved、requires_publish=true。保存草案不等于应用运行时网络规则；需在环境设置中审核、保存并发布后，再验证官方与知乎检索。此次未因保存草案而宣称联网成功。

Rubin 官方各格式吞吐比例仍未核验；知乎检索未完成。本次设计文档的已核验事实来自上传的 PTX、论文和专利，不引用未访问网页的技术结论。

## 当前状态更新

2026-10-23，本轮实际请求 www.bing.com、www.nvidia.com 与 developer.nvidia.com 返回HTTP200；Rubin产品页与技术博客已实读。此前403保留为历史诊断，不再表示目前官方数据未取得。ServeTheHome、Tom’s Hardware、TechPowerUp、TrendForce和SemiAnalysis等域名已加入新的待发布草案；部分第三方全文仍在CONNECT阶段被403拒绝，需分别记录访问与摘要证据。

已核验单GPU dense：TF32=2、FP16/BF16=4、FP8/FP6 Training=17.5、NVFP4 Training=35 PFLOPS。NVFP4 Inference=50 PFLOPS为sparse，不混入dense配比。
