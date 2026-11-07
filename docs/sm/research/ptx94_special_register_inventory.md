# PTX ISA 9.4 第10章特殊寄存器索引

35指原文说明节数，不代表展开所有向量分量/命名范围后的寄存器数；这些只读预定义变量不额外计为第9章opcode。第10章导言（PDF875/印863）说明通过 `mov` 或 `cvt` 读取。对应声明、语义、ISA/target注记保存在 [JSON](ptx94_special_register_inventory.json)。

状态提供方是本项目架构职责建议，不能反推NVIDIA物理CSR/RF组织。页码为物理PDF/正文印刷页。

| 节号 | PDF/印刷页 | 原文寄存器标签 | 建议状态提供方 | 审查要点 |
|---|---:|---|---|---|
| 10.1 | 876/864 | `%tid` | CTA/thread启动身份与线程坐标 | 以该节类型、分量与target限制为准。 |
| 10.2 | 877/865 | `%ntid` | CTA launch维度 | 以该节类型、分量与target限制为准。 |
| 10.3 | 878/866 | `%laneid` | warp内lane编号 | 以该节类型、分量与target限制为准。 |
| 10.4 | 879/867 | `%warpid` | 当前warp调度位置诊断状态 | %warpid可在preemption/reschedule后改变；不能当kernel逻辑warp的稳定身份。 |
| 10.5 | 880/868 | `%nwarpid` | warp编号上界/能力状态 | 返回maximum number of warp identifiers；不能直接等同于当前活跃warp数或ceil(ntid/32)。 |
| 10.6 | 880/868 | `%ctaid` | grid内CTA启动坐标 | 以该节类型、分量与target限制为准。 |
| 10.7 | 881/869 | `%nctaid` | grid CTA维度 | 以该节类型、分量与target限制为准。 |
| 10.8 | 882/870 | `%smid` | 当前SM调度位置诊断状态 | %smid为读时执行位置，可改变，且ID编号未保证连续。 |
| 10.9 | 883/871 | `%nsmid` | SM编号上界/能力状态 | %nsmid是SM identifier范围的上界，可能大于设备实际SM个数。 |
| 10.10 | 884/872 | `%gridid` | context内grid launch时序身份 | %gridid是temporal grid launch identifier，不是SM内部resident grid slot号。 |
| 10.11 | 885/873 | `%is_explicit_cluster` | 显式cluster launch标志 | 以该节类型、分量与target限制为准。 |
| 10.12 | 886/874 | `%clusterid` | grid内cluster坐标 | 以该节类型、分量与target限制为准。 |
| 10.13 | 887/875 | `%nclusterid` | grid cluster维度 | 以该节类型、分量与target限制为准。 |
| 10.14 | 888/876 | `%cluster_ctaid` | cluster内CTA坐标 | 以该节类型、分量与target限制为准。 |
| 10.15 | 889/877 | `%cluster_nctaid` | cluster CTA维度 | 以该节类型、分量与target限制为准。 |
| 10.16 | 890/878 | `%cluster_ctarank` | cluster内线性CTA rank | 以该节类型、分量与target限制为准。 |
| 10.17 | 891/879 | `%cluster_nctarank` | cluster CTA总rank数 | 以该节类型、分量与target限制为准。 |
| 10.18 | 892/880 | `%lanemask_eq` | 由lane编号生成的mask | lane比较mask是静态lane编号关系，不是当前active mask；后者由activemask指令获取。 |
| 10.19 | 892/880 | `%lanemask_le` | 由lane编号生成的mask | lane比较mask是静态lane编号关系，不是当前active mask。 |
| 10.20 | 893/881 | `%lanemask_lt` | 由lane编号生成的mask | lane比较mask是静态lane编号关系，不是当前active mask。 |
| 10.21 | 894/882 | `%lanemask_ge` | 由lane编号生成的mask | lane比较mask是静态lane编号关系，不是当前active mask。 |
| 10.22 | 895/883 | `%lanemask_gt` | 由lane编号生成的mask | lane比较mask是静态lane编号关系，不是当前active mask。 |
| 10.23 | 895/883 | `%clock, %clock_hi` | 执行平台cycle counter读取 | 32bit计数器静默wrap；clock_hi对应clock64高32bit，分两次读取不能假设是同一瞬间快照。 |
| 10.24 | 896/884 | `%clock64` | 执行平台64bit cycle counter读取 | 64bit cycle counter静默wrap；低/高32bit与clock/clock_hi对应。 |
| 10.25 | 897/885 | `%pm0 … %pm7` | 性能计数器/工具接口 | 文档明确计数器行为currently undefined，不能虚构event含义/精确计数保证。 |
| 10.26 | 898/886 | `%pm0_64 … %pm7_64` | 64bit性能计数器/工具接口 | 文档明确行为currently undefined；低32bit对应pm0..7，不能假设独立自由编程CSR。 |
| 10.27 | 899/887 | `%envreg<32>` | driver初始化的执行环境ABI | 32个driver-defined只读register，精确语义由driver文档定义；SM文档不能编造用途。 |
| 10.28 | 900/888 | `%globaltimer, %globaltimer_lo, %globaltimer_hi` | NVIDIA工具/平台global timer接口 | globaltimer是工具导向、target-specific；JIT到其他target时值unspecified，不承诺跨设备统一精确时钟。 |
| 10.29 | 901/889 | `%reserved_smem_offset_begin, %reserved_smem_offset_end, %reserved_smem_offset_cap, %reserved_smem_offset_<2>` | launch/system ABI保留shared区域元数据 | system保留shared区不对用户开放，用户访问是undefined behavior；<2>表示offset_0/offset_1这两个命名实例。 |
| 10.30 | 902/890 | `%total_smem_size` | CTA launch用户shared分配大小 | 静态+动态用户shared，排除system reserved；返回按目标allocation unit取值，不能反推物理bank组织。 |
| 10.31 | 903/891 | `%aggr_smem_size` | CTA launch用户及system保留shared聚合大小 | 用户静态+动态shared加system reserved；不能和total_smem_size混用。 |
| 10.32 | 904/892 | `%dynamic_smem_size` | CTA launch动态shared大小 | 只报告kernel launch动态shared分配量，不是运行时TMEM allocation或当前shared剩余量。 |
| 10.33 | 905/893 | `%current_graph_exec` | CUDA device graph执行上下文 | 非CUDA device graph kernel时值0；不是任意SM本地graph scheduler状态。 |
| 10.34 | 906/894 | `%perctamemoryoffset` | driver per-CTA global memory slice地址 | PTX9.4新增，sm80+；只有声明.minperctamemory的entry内使用才有效。返回当前CTA global slice的64bit地址。 |
| 10.35 | 907/895 | `%perctamemorysize` | driver per-CTA global memory slice大小/stride | PTX9.4新增，sm80+；仅带.minperctamemory的entry可用。1024B倍数，driver不支持时为0；支持时至少为directive申请大小。 |

`%warpid/%smid` 可因preemption/reschedule变化；`%nwarpid/%nsmid` 不是瞬时活跃数；lane mask不是active mask。性能计数器行为undefined和globaltimer的target-specific性质应保留，不能由名称推导性能/时序保证。

`%perctamemoryoffset/%perctamemorysize` 是PTX9.4新增global memory slice接口，与local stack、SMEM、TMEM均不同，依赖entry的 `.minperctamemory` 和driver支持。

可复核：`python docs/sm/check_instruction_inventory.py --pdf /path/to/ptx_isa_9.4.pdf`。如需主文也逐节覆盖这些状态，可增加 `--require-special-registers`。
