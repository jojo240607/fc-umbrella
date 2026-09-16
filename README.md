# FC-Stack 壳工程（Umbrella）

飞控全栈多仓库的统一壳工程：以 **git submodule** 纳入 9 个独立仓库，集中管理
**整体架构、工程说明、联调方式**。各子仓库独立演进，壳工程只记录**版本快照**与**文档**。

## 工程组成

| 子模块 | 仓库 | 职责 |
|---|---|---|
| `flyctrl/` | jojo240607/flyctrl | 飞控固件（Rust no_std：EKF / PID / 飞行模式 / FDIR / MAVLink 上行） |
| `fly-simulater/` | jojo240607/fly-simulater | 物理仿真平台（fly-sim-core：plant / controller / sensor / wind / SIL） |
| `mcu_simulater/` | jojo240607/mcu_simulater | MCU 指令级仿真器（Unicorn STM32F407 + 虚拟外设 I2C/UART/USB） |
| `joc-base/` | jojo240607/joc-base（**dev 分支**） | RTOS 内核 + 板级（STM32F407 minimal，固件 ELF 底座） |
| `joc-rtos-app-sdk/` | jojo240607/joc-rtos-app-sdk | 应用 SDK（Rust no_std：日志 / 设备 / 任务，180B 日志缓冲） |
| `mavlink-core/` | jojo240607/mavlink-core | MAVLink 编解码（帧 / 枚举 / COMMAND_LONG） |
| `physics/` | jojo240607/physics | 物理引擎 phy-sdk（fly-sim-core 可选依赖，SIL 真实物理） |
| `groundctrl/` | jojo240607/groundctrl | 地面站（Rust） |
| `joc-drvtest-app/` | jojo240607/joc-drvtest-app | 驱动测试应用（外设驱动调试） |

## 快速开始

```bash
# 1) 初始化子模块（含递归；本地路径子模块需放行 file transport，见下）
git submodule update --init --recursive

# 2) 构建固件（real-sensors 全链路 / hil 闭环 两种 feature）
./scripts/build.sh real-sensors   # 产出 /tmp/flyctrl_real.bin
./scripts/build.sh hil            # 产出 /tmp/flyctrl_hil.bin

# 3) 一键回归（各仓库测试）
./scripts/verify.sh

# 4) 一键联调（构建固件 + 全部联调测试：虚拟外设/解锁飞行/SIL/HIL/共享内存/故障注入）
./scripts/integrate.sh            # 全部
./scripts/integrate.sh unlock     # 单步骤：firmware|sensors|unlock|app|sil|hil|shmem|fault|hover
```

### 子模块 URL

全部 9 个子模块均为 `git@github.com:jojo240607/*.git`（SSH），跨机器
`git submodule update --init --recursive` 可直接拉取（SSH key 需有相应权限）。
若 git 报 `transport 'file' not allowed`（仅历史本地路径源时）：

```bash
git -c protocol.file.allow=always submodule update --init --recursive
```

### 联调产物路径约定（跨机器可复现的关键）

联调测试（mcu_simulater `tests/x_*.rs`、fly-sim-server）不再硬编码机器路径，
统一经 `mcu_simulater::artifact` 解析，优先级：

1. **环境变量**：`JOC_BASE_ELF`（joc-base minimal ELF）、`JOC_APP_FLYCTRL` /
   `JOC_APP_DRVTEST` / `JOC_APP_SDK`（各 app.bin）——`./scripts/integrate.sh`
   一键联调即构建产物并导出；
2. **壳工程规范布局**：`joc-base/build_hil/stm32f407_minimal.elf`、
   `flyctrl/app.bin` 等（本仓库上一级目录即壳工程根）；
3. **历史开发机路径** `/home/ubuntu/work/...`（仅当存在时兜底）。

新机器流程：`git submodule update --init --recursive` →
`./scripts/integrate.sh firmware`（构建底座 ELF + 两种固件）→
`./scripts/integrate.sh all`。

## 版本快照

子模块 commit 由壳工程锁定（`git submodule status` 查看）。推进子模块后
（在子仓库内 commit），回到壳工程 `git add <submodule>` 即可记录新快照；
他人 `git submodule update` 后得到**一致版本**。这保证"壳工程快照 = 可复现联调状态"。
全部子仓库均已推 GitHub（含各仓库本地领先提交、joc-base 跟踪 dev 分支），
壳工程快照可跨机器完整拉取。

## 文档导航

- [`docs/architecture.md`](docs/architecture.md) — 整体架构（三层仿真栈 / 数据流 / 各层职责）
- [`docs/engineering.md`](docs/engineering.md) — 各工程功能详解
- [`docs/integration.md`](docs/integration.md) — 联调方式（虚拟外设 / SIL / HIL / 故障注入 / 解锁飞行）
- [`scripts/integrate.sh`](scripts/integrate.sh) — 一键联调（构建固件 + 全部联调测试）
- [`scripts/verify.sh`](scripts/verify.sh) — 一键回归（各仓库核心测试）
