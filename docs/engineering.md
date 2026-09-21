# 各工程功能详解

## flyctrl/ — 飞控固件

Rust `no_std` 飞控，编译为真实 STM32F407 二进制，经 mcu_simulater 运行。

**Features（build_app.py --features）**：
- `real-sensors`：真实驱动（**BMI088**(SPI3 双片选) / BMP280 / QMC5883 / U-blox / SBUS）
  经 SPI/I2C/UART 总线读写。（历史：IMU 曾经是 MPU6050(I2C)，见 flyctrl 提交
  `e541b47 feat(sensors): IMU 从 MPU6050(I2C) 切换 BMI088(SPI)`。）
- `hil`：HIL 双机闭环——USB CDC（MAVLink HIL_SENSOR/SET_POSITION 上下行）+
  SRAM3 共享内存直连（`app/src/flyctrl/hil_shmem.rs`，无 USB/MAVLink 零协议通道），
  设定点来自 PC 仿真器
- `demo` / `usbtest` / `integration-test`：演示/调试

**核心**：
- `core/src/estimator/ekf.rs`：EKF（姿态四元数 + 位置/速度 + 加速度/陀螺零偏），
  重力锚定（幅值 + 方向双门控）、磁航向锚定（`set_mag_declination` 对齐地理北）、
  气压/GPS 融合
- `core/src/controller/`：PID / INDI / LQR / TECS / MPC / manual 多控制器
- `core/src/fdir.rs`：健康监控（IMU 冻结 / GPS/baro/mag dropout → Critical/Degraded）
- `core/src/flightmode.rs` + `mission.rs`：飞行模式治理（ModeGovernor）与航点任务
- `app/src/flyctrl/`：4 任务（control 4ms / sensors / telemetry / uplink），
  共享 `step_hil` 编排；非 HIL 模式按 `G_CMD_MODE` 分发（STABILIZE/ALT_HOLD/
  LOITER/GUIDED/RTL/LAND）；HIL 下 `hil_shmem.rs` 轮询 SRAM3 共享区注入真值、
  回写执行器（与 USB 注入并存，互不干扰）

**构建**：`./scripts/build.sh real-sensors` → `/tmp/flyctrl_real.bin`

## fly-simulater/ — 物理仿真平台

物理世界 + 共享控制编排（SIL）。

- `fly-sim-core/src/plant.rs`：四旋翼 plant（推力/力矩/气动/风/地面接触/自由落体）
- `fly-sim-core/src/sensor.rs`：SensorModel（IMU/baro/GPS/mag 误差建模：噪声/偏置/
  硬铁/软铁/磁偏角/安装误差）+ SensorFault（故障注入）
- `fly-sim-core/src/controller.rs`：FlyController（SIL 侧 EKF→PID→plant 闭环，
  ModeGovernor 全模式）
- `fly-sim-core/src/sim.rs`：SimLoop（悬停/自由落体/避障/风场景）
- 可选 `phy` feature：接 physics 真实刚体引擎

**测试**：`cargo test -p fly-sim-core`（8）、`tests/sil.rs`（phy）、
`tests/sensor_fault.rs`（6，故障注入回归）、`tests/mag_hover.rs`（磁锚定闭环）

## mcu_simulater/ — MCU 指令级仿真器

- Unicorn Cortex-M4F 执行固件 `.elf`；`Machine` 装配 STM32F407 布局 + 外设
- **虚拟外设**：
  - **SPI 从设备：BMI088**（双片选 accel+gyro，SPI3；`vperiph/spi/bmi088.rs`）——
    与固件 `ImuBmi088("bmi088")` 对应；陀螺量程 **±2000 dps**（16.4 LSB/dps），
    加速度 ±3g（10920 LSB/g）
  - I2C 从设备：bmp280（高度可配置，`StaticBaro::at_height`）/ qmc5883；
    `mpu6050` 仍在（旧路径，供 I2C IMU 回归）
  - UART 推流：GPS NMEA / SBUS 遥控（通道可配）
  - USB OTG：CDC 链路（HIL 上下行）
- `tests/x_*.rs` 联调验收：
  - `x_flyctrl_real_sensors`：真实驱动全链路（I2C 读 + GPS 定位 + hb 心跳）
  - `x_flyctrl_unlock_flight`：虚拟 RC 解锁 + 油门，控制律闭环电机输出
  - `x_hil_mcusim`：HIL 双机闭环（USB CDC，SIL 物理 + MCU 控制）
  - `x_shmem_mcusim`：HIL 共享内存直连闭环（SRAM3 @0x2002_0000，无 USB/MAVLink）
  - `x_fault_injection` / `x_bus_trace`：调试平台

**构建/测试**：`cargo test --test x_flyctrl_real_sensors`（机器慢时用 `--release`）

## joc-base/ — RTOS 内核与板级

STM32F407 最小系统（RTOS 调度/任务/设备/ioctl），产出固件 ELF 底座
`build_rel/stm32f407_minimal.elf`，mcu_simulater 加载运行。

## joc-rtos-app-sdk/ — 应用 SDK

Rust `no_std` 应用层（jOS 上）：任务/设备/ioctl/日志。**180B 日志缓冲**
（`emit` 越界写已修复——长日志行会破坏栈导致固件卡死）。

## mavlink-core/ — MAVLink 协议

编解码：帧 / 枚举（COPTER_MODE / MAV_CMD / MAV_RESULT）/ COMMAND_LONG /
SET_POSITION_TARGET_LOCAL_NED。固件 uplink 与地面站共用。

## physics/ — 物理引擎

phy-sdk：真实刚体引擎（`fly-sim-core` 默认 feature `phy`；SIL/mag_hover 均用
`PhySdkWorld`。历史 ToyWorld 替身已退场，文档旧提法失效）。

## groundctrl/ — 地面站

Rust 地面站（Windows 构建脚本 build.bat/ps1；MAVLink 下行/上行）。

## joc-drvtest-app/ — 驱动测试应用

外设驱动调试应用（app.bin/elf 构建产物）。
