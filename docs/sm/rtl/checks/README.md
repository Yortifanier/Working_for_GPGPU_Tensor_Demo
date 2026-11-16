# SM控制主干实际回归证据

[`results_all.json`](results_all.json)保存实际central runner结果：8种配置，12次正常仿真通过；3次 `a_take_requires_candidate` 预期断言失败单列，不混入正常PASS数量。每项有参数、seed（随机化TB使用）、源码签名、运行日志hash和`archived_log`仓库路径；各配置另保留lint、编译日志和构建签名。

复现命令：

```bash
python3 verif/core/flow/rtl/sp/sm/run_sm_control.py --suite all --jobs 2
```

Verilator5.032，严格Wall、SM_ASSERTIONS；不豁免WIDTH、LATCH、UNOPTFLAT或SELRANGE。正常测试中的错误返回、旧token及reset是checker明确预期的刺激，不是忽略了DUT错误。每个reset中止的dispatch单列，不伪造completion。

该证据只验证Sched、scoreboard和统一控制流IR控制器。15域后端为协议BFM，未实现RF、FMA、SFU、LSU、TMA或完整Tensor bridge；没有执行既有SM发生器106项testplan，也不是全PTX tuple、ITS、PPA或Rubin性能证明。
