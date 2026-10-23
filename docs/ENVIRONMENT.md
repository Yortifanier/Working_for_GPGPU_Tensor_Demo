# MALU 工程环境初始化

当前仅提供文档与工程目录骨架，没有 MALU RTL，也没有可执行的 RTL 编译或仿真目标。`setup.csh` 不安装 EDA 工具，不声称仿真通过。

在 **tcsh** 中从项目根目录运行：

```csh
source ./setup.csh
echo $MALU_SETUP_STATUS
```

从任意目录运行时，显式传入项目根目录；包含空格的路径需加引号：

```csh
source /abs/project/setup.csh /abs/project
```

csh/tcsh 的 `$_` 是上一条命令信息，不是可移植的 `BASH_SOURCE`。脚本只把它作为提示，不假定 `$0` 是被 source 的脚本。可靠定位顺序为显式根目录参数、有效 source 提示、当前目录、已有 `PROJECT_ROOT`；定位不到时返回错误，不退出用户 shell。不要在携带无关 `$argv` 参数的外层脚本里省略显式项目根目录。

`PROJECT_ROOT` 保存规范化的绝对目录。`MALU_BUILD_DIR` 默认为 `$PROJECT_ROOT/build`，允许覆盖；文件列表、日志和生成物以后应放入 build，不放入 design/src。setup 只创建 build 目录，不生成 RTL。主工程应忽略 `build/` 和 `setup.local.csh`。

本地可选配置从 `$PROJECT_ROOT/setup.local.csh` 读取。可复制 `setup.local.csh.example` 后修改；配置 `MALU_SIMULATOR`、`MALU_EDA_BIN`、`EDA_VERSION` 和 `MALU_BUILD_DIR`。默认 simulator=`none`，只初始化环境。`EDA_VERSION` 是所需版本字符串（匹配工具首行中的固定版本文本）；它不会选择或安装软件，选择实际版本需通过 `MALU_EDA_BIN` 或站点已配置的 PATH。

选择工具后仅探测版本：Verilator `--version`、Icarus `-V`、VCS `-ID`、Xcelium `-version`、Questa `vsim -version`。工具未安装、探测失败或版本不符时，`MALU_SETUP_STATUS=1`；未探测的版本不编造。`MALU_EDA_VERSION_STATUS` 为 `unchecked/missing/detected/mismatch`，`MALU_EDA_VERSION_DETECTED` 保存已探测首行或 `not detected`。

重复 source 会先移除本脚本上次添加的 EDA bin，再按当前配置添加；已有 PATH 项不会重复添加。脚本不覆盖整个 PATH，不清除用户原有目录。`MALU_BUILD_DIR` 等已设变量保留，改变项目或 build 位置时应显式设置所需值。

已有 `LM_LICENSE_FILE`、`SNPSLMD_LICENSE_FILE`、`CDS_LIC_FILE`、`MGLS_LICENSE_FILE` 仅检查是否存在，不输出值，不修改许可证。不把许可服务地址或密钥提交到 Git，也不在聊天中填写秘密。

加载结束时可通过 `$status` 或 `MALU_SETUP_STATUS` 检查初始化结果。版本探测成功仅证明程序可执行，不证明许可证可用或仿真可运行。当前尚无 RTL，功能验证、时序与综合均未执行。

## 初始化脚本检查

```sh
python3 tools/verify_setup.py --tcsh /path/to/tcsh
```

发布前使用经 Debian 签名与 SHA256 校验的临时 tcsh 6.24.13 执行了7项检查：含空格路径、重复source、局部配置和版本匹配、PATH幂等、许可证值隐藏、版本不匹配/工具缺失错误以及调用shell存活。模拟工具版本明确是测试夹具，未安装商业EDA、未运行RTL仿真。检查报告写入被忽略的build目录。
