# 测试用例总账（单一真值源，防混淆）

> 2026-09-24 盘点（§5.130 后）。**判别一个测试属于哪类，唯一标准是它加载哪个固件、
> 测的是什么**——文件名前缀（x_/m_/zz_）只是历史习惯，不代表分类。
> 产物路径约定见 `mcu_simulater/src/artifact.rs`；构建流见 `flyctrl/build_app.py`。

## 目录布局（2026-09-24 起，mcu_simulater/tests/）

```mermaid
mcu_simulater/tests/
├── common/mod.rs      # EnvHarness 等共享脚手架（A 类经 #[path] 引用）
├── flight_real/       # A 类：飞控业务（real-sensors 固件，17 目标）
├── flight_default/    # B 类：飞控业务（默认固件，2 目标）
├── hil/               # C 类：HIL 双机闭环（hil 固件，2 目标）
├── platform/          # D 类：MCU 模型 / jOS / SDK / 总线（53 目标）
├── drvtest/           # D 类：驱动测试（joc-drvtest-app，4 目标）
└── bench/             # E 类：bench / 杂项（3 目标）
```

★Cargo 集成测试不自动发现子目录 ⇒ `Cargo.toml` 尾部显式 `[[test]]`（autotests = false），
**目标名全部保持不变** ⇒ integrate.sh / h_verify.sh / 文档的 `--test <名>` 无需改动。
新增测试时：文件放入对应子目录 + Cargo.toml 加一条 `[[test]]`。

## 一、三大场总览

| 场 | 环境 | 判定 | 入口 | 规模 |
|---|---|---|---|---|
| **H 场** | 纯 PC（无 MCU），Rust 单测 | 全绿才能进 M（§5.38） | `scripts/h_verify.sh` | flyctrl-core 117 + fly-sim-core 176 + sensor_fault 6 |
| **M 场** | MCU 仿真环境（Cortex-M4F 虚拟机 + 虚拟外设） | 基线判定（step_bl） | `scripts/integrate.sh [all\|单步]` | 22 步 ≈ 60 用例（见下） |
| 非例行/专项 | 各处 | 手动 | 各测试文件 | 见 §四 |

## 二、M 场测试分类（按被测对象，共 82 目标）

### A. 飞控业务测试 —— real-sensors 固件（★"飞控测试"主体）
> 固件：`/tmp/flyctrl_real.bin` + 同 feature ELF（真实传感器通路 I2C/SPI/UART，
> hb 心跳、ESKF、控制任务全跑）。系统侧 jOS.elf。符号探针必须 `use_app_elf(real)`（§5.130）。

| 测试 | 用例 | 测什么 | 例行 |
|---|---|---|---|
| x_flyctrl_real_sensors | 1 | 虚拟外设全链路（传感器挂载/心跳/总线 I/O） | ✓ sensors |
| x_flyctrl_unlock_flight | 1 | 解锁→起飞全链路（armed/EKF 收敛/电机千分比） | ✓ unlock |
| x_fault_injection | 2 | 故障注入（单独 panic 注入路径） | ✓ fault |
| x_env_smoke / rc | 2+2 | EnvHarness 冒烟 / 遥控链路 | ✓ env |
| x_env_faults / noise_perturb / motion / longrun | 8+7+4+2 | 传感器故障 / 噪声鲁棒 / 机动跟踪 / 长跑稳定 | ✓ env |
| x_sensor_rate | 1 | 采样率口径（500Hz/拍 1.9973） | ✓ env |
| x_hover_env / hover_noise / hover_demo | 1+1+1 | 悬停闭环（直通/抗噪/60s 演示） | hover(可选) |
| x_vperiph_mcusim | 3 | 虚拟外设直通闭环 | hover(可选) |
| x_toml_topology | 1 | 场景拓扑 TOML 配置 | ✗ |
| x_task_stall | 1 | 任务停滞检测（CTRL_TICKS/SENSOR_SEQ 推进） | ✗ |
| zz_ctlprof | 13 | 控制通路画像（性能剖析专用，非回归） | ✗ |

### B. 飞控业务测试 —— 默认固件（正式飞控 app.bin，无传感器 feature）
> 固件：`flyctrl/app.bin` + `app.elf`。正式版（传感器走真驱动声明路径，无虚拟传感器注入）。

| 测试 | 用例 | 测什么 | 例行 |
|---|---|---|---|
| x_flyctrl_app | 1 | 双分区整机启动 | ✓ app |
| x_flyctrl_modes | 1 | MAVLink DO_SET_MODE 切换（STABILIZE→LOITER→RTL） | ✓ env（0/1 在案 ✗） |

### C. HIL 模式测试 —— hil 固件（★不是遗留例程，在役）
> 固件：`/tmp/flyctrl_hil.bin`（经 `JOC_APP_FLYCTRL`）。**用途**：PC 物理世界
> （fly_sim_core SimLoop）↔ MCU 双机闭环，MAVLink 编解码/注入节奏与**真板 HIL
> 完全同一份代码**（fly_sim_hil::hil_link）——是真板 HIL 调试的仿真预演。

| 测试 | 用例 | 测什么 | 例行 |
|---|---|---|---|
| x_hil_mcusim | 1 | 虚拟 USB-CDC 双机闭环（HIL_SENSOR 下行/ACTUATOR_CONTROLS 上行） | ✓ hil |
| x_shmem_mcusim | 1 | 同上，链路换 SRAM3 共享内存直连 | ✓ shmem |

### D. 平台层测试（非飞控业务：MCU 模型 / jOS / SDK / 驱动）

**MCU 模型与外设模型（m\* 家族 39 目标 ≈79 用例）**：m0 验收、m1-mmio、m2-irq/mpu、
m3 外设、m4 dma/exti/rcc/wdog/mpu、m5 adc/i2c/spi/uart/tim(含 dma/irq 变体)、
m6 tim、m7 dac、m8 crc、m9 rng、m10 pwr、m11 rtc、m12 dcmi、m13 fsmc、m14 sdio、
m15 can、m16 usb、m17 gpio、m18 malloc。专项：m_fpca_probe、m_unicorn_bn_bug（bug 复现）、
m_vfp_clamp_repro。**均不在例行回归**（模型层，改动 MCU 模型时手动跑）。

**jOS 平台**：x_jos_plain / x_jos_p2（jOS 裸启）、x_jos_app / x_jos_hb / x_jos_storm_diag
（joc-rtos-app-sdk 固件）、x_jos_acceptance(6) / x_jos_diag、x_telemetry(2)、x_checkpoint(3)、
x_monitor_repl(3)、x_gdb_server(2)、x_digital_defect(3)、x_fault_script(3)、debug_unmapped。

**模型级总线/工具**：x_bus_trace(5)（纯总线嗅探，不加载飞控固件；i2c×2 在案先存 §5.125/5.126）。

**驱动测试（joc-drvtest-app 固件）**：x_drvtest(1)、x_bench_mips(2)、x_sys_retire_calib(1)、
x_sched_assert_ctx(1)。**均不在例行回归**。

### E. bench/杂项（非测试）：bench_mips / bench_probe / bench_tb。

## 三、固件产物 × 测试矩阵（防混核心）

| 产物 | feature | 构建落点 | bin 消费者 | ELF 消费者 |
|---|---|---|---|---|
| app.bin / app.elf | 默认 | flyctrl/app.{bin,elf} | x_flyctrl_app、x_flyctrl_modes | 同左（默认 elfsym） |
| app_real.bin + /tmp/flyctrl_real.bin | real-sensors | build.sh real-sensors → 成对同步 bin+ELF（§5.130） | A 类全部 12 目标 | A 类（use_app_elf 强制同 feature） |
| /tmp/flyctrl_hil.bin | hil | build.sh hil → JOC_APP_FLYCTRL | x_hil_mcusim、x_shmem_mcusim | flyctrl_hil_app_elf()（暂无消费者，预置） |
| jOS.elf | joc-base minimal | integrate.sh firmware（cmake build_hil） | 几乎全部 M 场测试的系统侧 | joc_base_elf() |
| drvtest app.bin | joc-drvtest-app | 该仓自建 | D 类驱动 4 目标 | — |
| sdk app.bin | joc-rtos-app-sdk | 该仓自建 | x_jos_app/hb/storm_diag | — |

★纪律（§5.129/5.130）：产物**命名与同步必须按 feature 区分**；bin 与 ELF 必须同 feature；
"同名文件 last-build-wins"是跨 feature 污染的通用形态（两次事故同根）。

## 四、H 场构成（防混：fly-simulater 有两棵测试树）

- `fly-sim-core/tests/`（14 目标 176 用例，**例行**）：att_est/pos_ctrl/att_ctrl/powertrain/
  guidance_track/mag_hover/sil/pos_est/hil_replay/hil_mix_sign/torque_sign/wind_spatial/
  render_orient/mag_attitude_ref —— 纯算法 SIL。
- `fly-simulater/tests/`（17 目标，**非例行**）：avoidance/degraded/mission/monte_carlo/
  multi_drone/rc_modes/sensor_noise/vio_rtk/wind_scan/… 场景级集成（状态未盘点，另账）。
- `flyctrl`：flyctrl-core（lib 93 + 集成 24 = 117，**例行**）。

## 五、在案失败清单（2026-09-24 傍晚全量 80 目标首跑后更新）

| 项 | 类 | 状态 | 分析方向 |
|---|---|---|---|
| x_flyctrl_modes 0/1 | B(默认固件) | ✗ 在案 | LOITER 注入后 uplink 未处理（任务已起）。嫌疑：默认固件的 MAVLink 模式处理实现（docs/integration.md §6"后续优先项"）——**测试可能超前于固件功能**，需先判定缺功能 vs 测试错 |
| x_env_faults::baro_step_bounded_by_gps 1 项 | A(real) | ✗ 在案（早于 B 案） | ESKF 对 baro 阶跃的水平位置 GPS 约束（§5.9x 已立案分析） |
| x_env_motion::climb_height_tracks 1 项 | A(real) | ✗ 在案 | 高度通道跟踪；同族 cruise/turn 均绿，H 场 vertical_channel/tecs 全绿 ⇒ M 环境特异性（baro 积分/爬升模型） |
| x_bus_trace i2c×2 | D(模型级) | ✗ 在案 §5.125/5.126 | I2C 外设模型 sniff 签名 |
| x_hover_demo 0/1 | A(real) | ✗ 在案（§5.131 新曝光） | est 四元数 w≈-0.997（180° 翻转）而真值位置仍稳定悬停 ⇒ 疑似 ESKF 姿态发散或四元数读数约定问题；同场电机混控深度饱和（两电机贴 0/满） |
| x_drvtest（宿主 SD 校验） | D(驱动) | ✗ 在案（§5.131 新曝光） | ABI 已同步 v2 后：应用内自检 54/54 全过 ✓，但宿主侧 SD 扇区 0 读到填充值 0xA5（应用写扇区与宿主校验错位或 SD 模型通路问题） |

★2026-09-24 傍晚已修（§5.131）：x_hover_env / x_hover_noise 帧约定+判据窗口（✓ 绿）；
x_drvtest ABI 同步（挂载+自检 ✓，余宿主 SD 校验一项）。

维护规则：增/删测试 ⇒ 同步 `scripts/integrate.sh` 基线 + `docs/h-field.md` 基线表 + 本文档，
各附一句原因与日期；新测试文件放对应分类子目录并在 `mcu_simulater/Cargo.toml` 声明 `[[test]]`。
