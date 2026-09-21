# 联调方式

联调主线：**固件（真实二进制）跑在 MCU 指令级仿真上，传感器来自虚拟外设，
物理真值来自仿真平台**。以下按验证目标给出方式与命令。

> 环境提示：机器内存紧张时（3GB + swap），debug 测试会慢 10 倍，
> 建议 `cargo test --release`。耗时差别很大：`x_vperiph_mcusim` ~101s、
> `x_hover_env` ~422s、`x_hover_demo`（60s 演示）~770s。

## 0. 前置：构建固件与底座

产物路径**不硬编码**：mcu_simulater 测试经 `mcu_simulater::artifact` 解析
（环境变量 `JOC_BASE_ELF` / `JOC_APP_FLYCTRL_REAL`（real-sensors）/ `JOC_APP_FLYCTRL`（hil）/
`JOC_APP_DRVTEST` / `JOC_APP_SDK`
→ 壳工程规范布局 → 历史开发机路径兜底）。一键联调 `./scripts/integrate.sh firmware`
即完成以下构建并导出变量：

```bash
# RTOS 底座 ELF（joc-base 内，一次性；产物落壳工程规范布局 build_hil/）
cd joc-base && cmake -S . -B build_hil -DMCU_SIM=ON -DRTOS_SELFTEST=OFF && cmake --build build_hil

# 固件（两种 feature 产物）；产物名按联调约定固定，由壳脚本映射
# （real-sensors -> /tmp/flyctrl_real.bin，hil -> /tmp/flyctrl_hil.bin）
./scripts/build.sh real-sensors
./scripts/build.sh hil
```

单独跑某个测试时若产物不在规范布局（如独立仓库 clone），用环境变量覆盖：

```bash
export JOC_BASE_ELF=/path/to/stm32f407_minimal.elf
export JOC_APP_FLYCTRL=/path/to/flyctrl/app.bin
cd mcu_simulater && cargo test --release --test x_hil_mcusim
```

## 1. 虚拟外设全链路（真实驱动 × 虚拟总线）

验证固件**真实驱动**（I2C/UART）经虚拟从设备读到数据、GPS 定位、心跳正常。

```bash
cd mcu_simulater
cargo test --release --test x_flyctrl_real_sensors -- --nocapture
# 里程碑：mounted / task started / fix established / hb seq=250(imu/baro/gps/mag=true)
```

## 2. 解锁飞行（控制律闭环）

验证 RC 解锁 → 控制环输出电机指令 → EKF 闭环，无 panic。

```bash
cd mcu_simulater
cargo test --release --test x_flyctrl_unlock_flight -- --nocapture
# 断言：hb armed=true、m=[0.21×4]（电机非零）
```

要点：SBUS 通道编码 `raw = 992+(ch-1500)/500*819.5`，解锁阈值 ch>1700
→ 测试用 ch5=2000（raw=1811）。固件 SBUS 帧间锁存（armed 不随帧间隙归零）。

## 2.5 双分区整机验收（系统 + 正式飞控 app）

验证系统 ELF + flyctrl app（**默认 feature 正式飞控**，`$ROOT/flyctrl/app.bin`）
双镜像加载、App 分区自举挂载、业务任务拉起并跑出周期心跳。

```bash
cd mcu_simulater
cargo test --release --test x_flyctrl_app   # 里程碑：READY / RUST app mounted / task started / hb seq=
```

## 3. SIL（纯算法回归，无 MCU）

```bash
cd fly-simulater
cargo test -p fly-sim-core                 # 8 项（含磁力计几何/decl）
cargo test -p fly-sim-core --test mag_hover # 磁锚定闭环悬停（PhySdkWorld）
cargo test --test sensor_fault              # 故障注入 6 项
```

## 4. HIL 双机闭环（MCU 控制 + PC 物理）

固件 hil feature + 两种 PC↔MCU 链路（USB CDC / SRAM3 共享内存直连），
共享同一份 `step_hil` 事件驱动编排（control 阻塞 `HIL_EVT.wait()`，收到
一帧真值执行一拍）。

### 4.1 USB CDC 链路（x_hil_mcusim）

```bash
cd mcu_simulater
cargo test --release --test x_hil_mcusim      # USB CDC 链路 ~53s，roll/pitch/位置不发散
# 需 JOC_APP_FLYCTRL=/tmp/flyctrl_hil.bin（integrate.sh do_hil 已导出）
```

### 4.2 SRAM3 共享内存直连（x_shmem_mcusim）

无 USB / 无 MAVLink：PC 每 4ms 物理步把传感器真值/设定点/解锁写入 SRAM3
（0x2002_0000），固件 `uplink` 每 1ms 轮询 `pc_seq` 变化后全量注入
`SENSOR_FRAME` 并唤醒 control；`telemetry` 每 20ms 回写执行器/诊断，PC
读回驱动 plant。**共享区布局双方硬编码一致**（`flyctrl/app/src/flyctrl/
hil_shmem.rs` ↔ `mcu_simulater/tests/x_shmem_mcusim.rs`，改动任一侧必须
同步另一侧）。

```bash
./scripts/integrate.sh shmem    # 一键联调步骤（已导出 JOC_APP_FLYCTRL=hil 产物）
# 或手动：
cd flyctrl && python3 build_app.py --features hil --out /tmp/flyctrl_hil.bin
cd mcu_simulater && JOC_APP_FLYCTRL=/tmp/flyctrl_hil.bin cargo test --release --test x_shmem_mcusim
```

> 注意：共享内存契约仅在 **hil feature 固件**内编译。误加载默认/real-sensors
> 固件时测试会给出可操作的产物指引（启动后校验 `hil=1`），而非误导性断言失败。

## 4.5 悬停闭环（可选，慢）

虚拟外设直通闭环长仿真（60s 悬停演示），需 real-sensors 产物 `/tmp/flyctrl_real.bin`
（`./scripts/build.sh real-sensors`）：

> ⚠️ 当前快照 `x_hover_demo` / `x_hover_noise` **FAIL**：测试侧 PWM 读回漏改
> （joc-base eec5b58 改 TIM5 后只补了 `x_vperiph`）；修掉读回后 `x_hover_demo`
> 稳定悬停 44s 再发散。详见 `docs/verification-2026-09-17-hover.md`。

```bash
cd mcu_simulater
cargo test --release --test x_vperiph_mcusim   # 直通闭环（含长悬停）
cargo test --release --test x_hover_demo       # 60s 持续悬停（慢）
```


## 5. 故障注入与调试平台

```bash
cd mcu_simulater
cargo test --release --test x_fault_injection   # 时间轴故障剧本（NACK/丢帧/Halt）
cargo test --release --test x_bus_trace         # I2C/UART 事务嗅探
cd fly-simulater
cargo test --test sensor_fault                  # GPS 偏置/卡死、IMU 冻结 → FDIR
```

## 5.5 虚拟设备直接模拟：环境场景测试（EnvScenario）

面向**飞控软件稳定性**的环境压力测试：不经 SIL/HIL 物理闭环，直接在
MCU 指令级仿真上让 **real-sensors 固件真实二进制**读取**虚拟外设**
（**SPI BMI088→spi3**；I2C bmp280/qmc5883→i2c1；UART GPS NMEA→uart1、SBUS→uart2），
传感器数据来自 **EnvScenario 运动学真值 + 扰动 + 故障** 逐拍写入的
`FlySimState`。测试断言走共享内存（EST_STATE / SENSOR_SEQ），不依赖日志。

```bash
cd mcu_simulater
cargo test --release --test x_env_smoke          # 布局探针 + 悬停基线（2）
cargo test --release --test x_env_motion         # 爬升/巡航/姿态摆动/协调转弯（4）
cargo test --release --test x_env_faults         # IMU冻结/饱和、GPS掉链、baro阶跃/跳变/冻结、磁力计干扰/冻结（8）
cargo test --release --test x_env_noise_perturb  # 传感器噪声/偏置/漂移鲁棒性（5）
cargo test --release --test x_env_longrun        # 长时悬停/巡航有界性（2）
cargo test --release --test x_env_rc             # RC 解锁 / 掉链失联（2）
```

### 环境约定（重要）

- **高度基准**：场景 GPS 高度 `alt_ref = 4.0`（固件拒绝 `alt<=0` 的 NED 原点锁）；
  固件 GPS 首次 fix 时锁定 `baro_ref`，此后 EKF 用 `alt - baro_ref`（避免
  baro 海平面 0m 与 GPS 4m 的基线差被当真实高度差）。
- **步进**：`STEP_INSNS = 2_300_000`（≈13.3ms 场景/步 = 固件时间，见下方
  时钟校准）；`SENSOR_SEQ` 冻结判据用"连续 >20 步未推进"窗口（悬停冻结时
  IMU 读数 norm≈9.81 不误报）。
- **虚拟时钟保真度（2026-09 校准）**：`retired_count()` 实为 TB 字节数
  （block hook `fetch_add(size)`，Thumb ≈2×指令数）。旧 `VIRTUAL_INSNS_PER_SEC
  =30e6` 是"指令数"口径残留 → 场景/推流时间比 CPU 侧虚拟时钟（SysTick）
  慢 5.7 倍（实测校准：sensor msleep(2ms) ↔ 344K 字节/拍 → **172M 字节/虚拟秒**
  ≈86M 指令/秒，与真实 MCU ~100-150MIPS 同量级）。校准后**场景时间 = 固件
  时间**：控制拍速 46.7→178Hz（场景口径），yaw 速率与场景真值匹配（±15%），
  动态断言可按场景时间做相位对齐（turn 断 yaw 累计旋转 ≈ ω×t）。剩余 ~1.4 倍
  错配为**固件固有**（EKF 每拍执行超 4ms 预算，真实 MCU 同量级），非模拟器
  时钟失真。校准副作用与修复见下方"本轮修复"表（GPS 观测链路、FDIR 误判）。
- **2026-09-17 复验补充**：上述 172M 只描述**推流时钟**（虚拟从设备节拍）。固件
  **自身**时钟（SysTick）与场景对齐由 c62ec21 的 `run_ms` 负责，按固件 SysTick 计数
  收敛，步进粒度 `RETIRED_BYTES_PER_MS=95_600` 字节/ms；闭环不再用裸 `run(count)`
  口径对齐。详见 `docs/verification-2026-09-17-hover.md` §5。
- **EstState 内存布局（实测）**：`VehicleState(72B) + health(1B@72) +
  armed(1B@73)`——repr(C) enum 未标判别值时 ARM 编译为 1B（非 C int 4B），
  `read_est` 按实测偏移读取（hb 行 armed=true 时 EST+73=1、EST+76=0 实证）。

### 本轮修复（虚拟直接模拟暴露并验证）

| 修复 | 文件 | 现象 → 修法 |
|---|---|---|
| **EKF 机动锚定门控** | `flyctrl/core/src/estimator/ekf.rs` | 协调转弯稳态 roll 2.2° vs 真值 27°：比力幅值/方向门控无法区分"水平加速 vs 重力"，机动时锚定把 roll 拉向 0 → **gyro 幅值门控**（\|ω\|<0.25→1.0，<0.6 线性衰减，否则 0，乘进锚定增益） |
| **磁力计模型（模拟器）** | `mcu_simulater/.../data_source.rs` | StaticMag 固定机体系磁场是错误模型（yaw 观测恒定 → 锚定拉回）→ **世界系恒定地磁场 [0.2,0,0.4] 经姿态旋转到机体**（`rotate_by_quat_conj`） |
| **GPS RMC 状态随 fix** | `mcu_simulater/.../nmea_gps.rs` | RMC status 硬编码 'A' → GpsDrop 后 gps 恒有效、FDIR 不降级 → status 随 fix（'A'/'V'） |
| **RC 掉链优先于卡滞** | `mcu_simulater/.../scenario.rs` | RcDrop（全通道 1500）被 RcStuck（ch4=2000）覆盖 → 掉链后解锁位不恢复 → 失联窗口内 RcStuck 不生效 |
| **EstState 布局读取** | `mcu_simulater/tests/common/mod.rs` | read_est 读 health@72(4B)/armed@76 得到 0/256 假象 → 按实测 1B 布局读 health@72、armed@73 |
| **虚拟时钟校准** | `mcu_simulater/src/sim/timing.rs` | `VIRTUAL_INSNS_PER_SEC` 30M(指令口径) → 172M(字节口径，SysTick 实测折算)，`EnvHarness::STEP_DT` 跟随全局 → 场景时间=固件时间（原慢 5.7 倍），yaw 速率匹配真值 |
| **UART 推流粒度** | `mcu_simulater/tests/common/mod.rs` | 校准后每 run 推流 33B < GPS 帧 131B → 帧碎、NMEA 解析抖动、GPS 观测稀疏 → `STEP_INSNS` 400K→2.3M（13.3ms/步，191B/run 帧完整） |
| **GPS 解析跨批卡死** | `flyctrl/app/src/sensors/gps/ublox.rs` | drain 缓冲 128B < 帧批 130B(GGA+RMC) → 跨批错位 NmeaLine 卡死、GPS 间歇失效 → 256B 一次收整帧 |
| **GPS 样本保持** | `flyctrl/app/src/flyctrl/sensors_task.rs` | 无新帧每拍清 f.gps → control 4ms 拍错过 2ms Some 窗口、pos_available 大面积 false → FDIR 误判 GPS lost(health=1) → 保持样本 500ms（超时才清） |

### 已知设计局限（文档记录，非本轮引入）

- EKF 垂向速度**位置观测增益 k[5] 刻意清零**（恢复实验使 climb 恶化 2.12→3.06），
  垂向速度纯 IMU 积分；x[9] 垂向加计零偏仅由速度观测驱动。
- 协调转弯场景从 t=0 即恒定 bank（无建立过程）→ 陀螺无法建立 roll，测试不断言
  roll 精确值。
- GPS Doppler（r_vel=0.3）长时间约束下 EKF 水平速度有界但偏高（实测 4~5 vs 真值 3）。
  ⚠️ 旧文档把原因归为“固件时间慢 8 倍放大位置观测交叉协方差”——**归因已失效**
  （2026-09-21 实测场景时间 = 固件时间 1:1）。现象仍在，**真实根因待重定**
  （候选：`r_vel=0.3` 偏松 / GPS 20Hz 帧间样本保持），故 longrun 仍只断言“有界”。

### 已知基线问题（回归时确认，非本轮引入）

- **`x_hover_demo` / `x_hover_noise`（SIL 闭环）roll 漂移 ~40°**：SimLoop 物理
  注入真值 IMU 下 35s 闭环中 roll 发散（30M/172M 均复现，30M 下 40.6°）。
  **已定位并修复主因**：每循环 m.run(300K)=1.74ms@172M（校准后）≪ 物理步 4ms
  → 控制率仅 ~108Hz → 闭环发散；改 688K 字节（=4ms@172M）使 control 拍与
  物理 1:1 对齐。**该结论基于已被 c62ec21 `run_ms` 取代的 688K 口径，勿再引用。**
  **2026-09-17 复验：当前快照 `x_hover_demo` FAIL**（max|roll|=179.7°）——主因是
  测试侧 PWM 读回漏改（joc-base eec5b58 改 TIM5 后只补了 `x_vperiph`，漏了
  x_hover_demo/noise/env）；修掉读回后稳定悬停 **44s 再发散**（max|roll|=37.4°），
  44s 发散未定位。详见 `docs/verification-2026-09-17-hover.md`。
  **x_hover_noise 残余**（realistic IMU 噪声）：max|roll| 43°→30° 仍超断言
  15°。**2026-09 诊断**（6 组二分实验：accel_bias/gyro_bias/att_kd/vib_amp/
  att_kp 单独归零或增强均无效）确认是 **SIL 闭环（ToyWorld 简化物理 + 固件
  PID att_kp=3.0）在任意 IMU 白噪声下的姿态极限环**（roll/pitch ±30°，EKF
  估计本身稳定 ±2°、与物理脱节，GPS/高度控制耦合）——非垂向漂移、非单一
  根因。ToyWorld 无螺旋桨/机体空气阻尼，固件 PID 增益在其上噪声裕度不足；
  **2026-09 追加**：加 ToyWorld 螺旋桨角阻尼（物理正确）无效（±40°）；att_kd
  0.3→1.0（3.3 倍）部分改善（±30°→±15° 慢发散趋势保留）——阻尼增强可降幅但
  非根因（过度阻尼非真机方案），机制=控制环在无阻尼简化物理下的增益/相位裕度
  系统性不足 + 白噪声持续激励。真机有真实螺旋桨气动阻尼（时间常数 ~0.3s），
  稳定裕度预计远好于 ToyWorld；**真机前调优项**（控制环噪声鲁棒性：输入滤波/
  增益裕度/阻尼整定），SIL 侧不再追（物理模型无代表性增益）。
  **2026-09-17 复验：ToyWorld 已从源码退场，SIL/mag_hover 现用 `PhySdkWorld`——
  以上「无阻尼简化物理」诊断失去物理依据，需在 PhySdkWorld 上重做。**
  **2026-09-21 结案 ✅：已在 PhySdkWorld 上重做并定位。** 上述「极限环 / 增益裕度
  不足」的判断**不成立**——真因是**仿真双时基相位自由漂移**（控制拍周期均值
  4.0000ms 但真抖，而物理按固定 4ms 步进 ⇒ PWM 回读落在控制周期内的相位随机），
  属**测量假象**；`mcu_simulater::clock::run_one_control_tick` 锁相修复后，
  **`x_hover_noise` 60s 带噪持续悬停通过 ✓**（max|roll| 10.26°、max|pitch| 13.02°，
  闸 15°）。详见 `docs/test-roadmap.md`「解除阻塞的过程」与
  `docs/stage4-outer-loop-findings.md` P18 顶部更正块。
- **`x_fault_injection::midrun_nack_isolates_slave`（bmp280 读计数冻结）**：
  mpu6050 NACK 注入后固件 bmp280(0x76) I2C 读停（30M/pristine 固件均复现，
  模拟器 START 清错误位无效）。疑似 RTOS I2C 驱动（rtos_app_sdk）NACK 后错误
  恢复缺失，待专项排查。

## 6. 模式与航向（新增能力）

- **磁航向锚定**：EKF `set_mag_declination(decl)`（flyctrl core 单测：
  decl=15° 收敛 15°）；SIL `mag_hover` 验证 yaw 锚定地理北、全程漂移 <0.2°。
- **飞行模式分发**（非 HIL）：G_CMD_MODE → STABILIZE/ALT_HOLD/LOITER/GUIDED/
  RTL/LAND。默认分支（ALT_HOLD 解锁飞行）已实测；RTL/LOITER 动态验证需
  USB uplink 链路（注入 MAVLink DO_SET_MODE），尚未接入测试——后续优先项。

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `transport 'file' not allowed` | git 禁用 file 协议：`git -c protocol.file.allow=always submodule update --init` |
| 固件 hb 行尾被截断 | SDK 日志 180B 缓冲：日志行须 <180B（hb 已精简 ~147B） |
| 解锁后电机仍零 | SBUS 帧间锁存缺失（旧固件）；确认 ch5>1700（raw 编码） |
| EKF 高度收敛到 ~0 | 虚拟 baro 海平面 vs GPS 高度不一致：`attach_default_sensors_with_baro_height(4.0)` 对齐 |
| EKF 磁锚定发散 | 非零场磁力计须与 EKF 初值自洽（绕 Z 纯 yaw 修正 + 门控） |
| 测试报产物缺失（ELF / app.bin） | 产物路径经 `mcu_simulater::artifact` 解析：先跑 `./scripts/build.sh real-sensors`（默认落点 `/tmp/flyctrl_real.bin`）或 `./scripts/integrate.sh firmware`，或用 `JOC_BASE_ELF` / `JOC_APP_FLYCTRL_REAL`（real-sensors）/ `JOC_APP_FLYCTRL`（hil）环境变量指向已有产物 |
| debug 测试极慢 | 机器内存压力/swap：用 `--release` |
