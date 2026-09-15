# 整体架构

飞控全栈围绕 **三层仿真模型** 构建：`固件 → MCU 指令级仿真 → 物理世界`。
目标是让真实飞控固件（编译出的 `.bin/.elf`）在**指令级精确**的 MCU 仿真上运行，
并挂接**可建模的虚拟世界**，从而在无硬件的环境下完成固件调试、算法验证与联调。

```
┌─────────────────────────────────────────────────────────────┐
│ 层 1  飞控固件 (flyctrl)                                       │
│   Rust no_std，跑真实 STM32F407 二进制                          │
│   EKF(姿态/位置/磁航向) → 飞行模式 → PID → 执行器 PWM            │
│   FDIR(健康监控/失控保护) + MAVLink 上行(地面站命令)              │
└──────────────┬──────────────────────────────────────────────┘
               │ 经真实总线驱动（I2C / UART / USB）
┌──────────────▼──────────────────────────────────────────────┐
│ 层 2  MCU 指令级仿真 (mcu_simulater)                           │
│   Unicorn Cortex-M4F：固件逐指令执行                            │
│   虚拟外设：I2C(mpu6050/bmp280/qmc5883) UART(GPS/SBUS) USB(CDC) │
│   虚拟从设备把"物理世界传感器真值"伪装成真实寄存器/字节流          │
└──────────────┬──────────────────────────────────────────────┘
               │ 传感器真值 / 执行器命令（两种挂接方式）
┌──────────────▼──────────────────────────────────────────────┐
│ 层 3  物理世界 (fly-simulater / fly-sim-core)                  │
│   plant：四旋翼动力学(推力/力矩/气动/风)  +  SensorModel(误差)   │
│   controller：共享 step_hil 编排（SIL 侧 EKF→PID→plant 闭环）    │
│   可选 phy-sdk（physics）真实刚体引擎                           │
└─────────────────────────────────────────────────────────────┘
```

## 联调挂接方式（层 2 ↔ 层 3）

- **虚拟外设直通（real-sensors）**：层 3 把传感器真值写入 `FlySimState`
  （Arc<Mutex>），虚拟从设备动态寄存器实时读到 → 固件**真实驱动**经 I2C/UART
  读到数据。验证"真实驱动 + 真实总线协议"。
- **HIL（hil feature）**：层 3 把真值经 **USB CDC** 注入固件
  （HIL_SENSOR / SET_POSITION_TARGET 帧），固件回传执行器（HIL_ACTUATOR_CONTROLS）。
  验证双机（PC 物理 / MCU 控制）时钟匹配下的闭环。
- **SIL（纯 fly-sim-core）**：同一套 `step_hil` 编排在 PC 内运行
  （EKF→PID→plant），无 MCU 参与，用于算法回归（快）。

## 数据流（单控制拍，4ms）

```
sensors_task(采样 IMU/baro/GPS/mag/RC)
      │  SENSOR_FRAME(seqlock)
      ▼
control_task ──► step_hil ──► EKF(姿态积分+重力/磁/气压/GPS融合)
      │              │             │
      │              ├─ FDIR(健康→Critical/Degraded/Nominal)
      │              ▼
      │        飞行模式分发(设定点) ─► PID(位置外环/速度中环/姿态内环)
      │              │
      │              ▼
      │        执行器限幅 + 失控保护闸 ─► PWM(4 路)
      ▼
telemetry_task(MAVLink 下行) / uplink_task(地面站命令上行)
```

## 关键设计决策

1. **共享 `step_hil` 编排**（`flyctrl_core::hil`）：SIL 与 MCU 用同一份
   单步逻辑，保证"PC 上验证的 = 固件上跑的"。
2. **seqlock 传感器帧**：control(prio=4) 高于所有写者，单次读即原子一致；
   IMU 单次消费（HIL 注入饥饿时回退 SimImu，不重复积分）。
3. **SDK 日志 180B 缓冲**：长日志行会越界写破坏栈（已修复）；日志行设计
   须在 180B 内（hb 行已精简到 ~147B）。
4. **EKF 姿态锚定**：重力锚定(roll/pitch，幅值+方向双门控) + 磁航向锚定(yaw，
   decl 可配置) 互补，抑制纯陀螺积分漂移。
5. **传感器零场陷阱**：非零场磁力计必须与 EKF 初值约定自洽，否则正反馈发散
   （历史修复：绕 Z 纯 yaw 修正 + 门控）。

## 目录速查（壳工程内）

| 路径 | 内容 |
|---|---|
| `flyctrl/core/` | 飞控算法库（estimator/controller/fdir/vehicle/hil） |
| `flyctrl/app/` | 固件应用层（control/sensors/telemetry/uplink 任务） |
| `fly-simulater/fly-sim-core/` | 物理/控制/传感器仿真核心 + SIL 测试 |
| `mcu_simulater/src/machine.rs` | MCU 仿真机 + 虚拟外设装配 |
| `mcu_simulater/tests/x_*.rs` | 联调验收测试（全链路/SIL/解锁飞行等） |
| `joc-base/build_hil/` | 固件 ELF 底座（stm32f407_minimal.elf） |
