# FC-Stack 壳工程（Umbrella）

飞控全栈多仓库的统一壳工程：以 **git submodule** 纳入 9 个独立仓库，集中管理
**整体架构、工程说明、联调方式**。各子仓库独立演进，壳工程只记录**版本快照**与**文档**。

## 工程组成

| 子模块 | 仓库 | 职责 |
|---|---|---|
| `flyctrl/` | jojo240607/flyctrl | 飞控固件（Rust no_std：EKF / PID / 飞行模式 / FDIR / MAVLink 上行） |
| `fly-simulater/` | jojo240607/fly-simulater | 物理仿真平台（fly-sim-core：plant / controller / sensor / wind / SIL） |
| `mcu_simulater/` | jojo240607/mcu_simulater | MCU 指令级仿真器（Unicorn STM32F407 + 虚拟外设 I2C/UART/USB） |
| `joc-base/` | jojo240607/joc-base | RTOS 内核 + 板级（STM32F407 minimal，固件 ELF 底座） |
| `joc-rtos-app-sdk/` | （本地，未推 GitHub） | 应用 SDK（Rust no_std：日志 / 设备 / 任务，180B 日志缓冲） |
| `mavlink-core/` | jojo240607/mavlink-core | MAVLink 编解码（帧 / 枚举 / COMMAND_LONG） |
| `physics/` | jojo240607/physics | 物理引擎 phy-sdk（fly-sim-core 可选依赖，SIL 真实物理） |
| `groundctrl/` | jojo240607/groundctrl | 地面站（Rust） |
| `joc-drvtest-app/` | （本地，未推 GitHub） | 驱动测试应用（外设驱动调试） |

## 快速开始

```bash
# 1) 初始化子模块（含递归；本地路径子模块需放行 file transport，见下）
git submodule update --init --recursive

# 2) 构建固件（real-sensors 全链路 / hil 闭环 两种 feature）
./scripts/build.sh real-sensors   # 产出 /tmp/flyctrl_real.bin
./scripts/build.sh hil            # 产出 /tmp/flyctrl_hil.bin

# 3) 一键回归（各仓库测试）
./scripts/verify.sh
```

### 本地路径子模块说明

`joc-rtos-app-sdk/` 与 `joc-drvtest-app/` 尚未推 GitHub，`.gitmodules` 记录的是
本机绝对路径。新机器 clone 壳工程时，请先推送这两个仓库到 GitHub，再执行：

```bash
git config -f .gitmodules submodule.joc-rtos-app-sdk.url <新URL>
git config -f .gitmodules submodule.joc-drvtest-app.url <新URL>
git submodule sync
git submodule update --init --recursive
```

若 git 报 `transport 'file' not allowed`（file 协议被禁用）：

```bash
git -c protocol.file.allow=always submodule update --init --recursive
```

## 版本快照

子模块 commit 由壳工程锁定（`git submodule status` 查看）。推进子模块后
（在子仓库内 commit），回到壳工程 `git add <submodule>` 即可记录新快照；
他人 `git submodule update` 后得到**一致版本**。这保证"壳工程快照 = 可复现联调状态"。

## 文档导航

- [`docs/architecture.md`](docs/architecture.md) — 整体架构（三层仿真栈 / 数据流 / 各层职责）
- [`docs/engineering.md`](docs/engineering.md) — 各工程功能详解
- [`docs/integration.md`](docs/integration.md) — 联调方式（虚拟外设 / SIL / HIL / 故障注入 / 解锁飞行）
