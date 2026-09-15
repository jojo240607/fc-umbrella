# 联调方式

联调主线：**固件（真实二进制）跑在 MCU 指令级仿真上，传感器来自虚拟外设，
物理真值来自仿真平台**。以下按验证目标给出方式与命令。

> 环境提示：机器内存紧张时（3GB + swap），debug 测试会慢 10 倍，
> 建议 `cargo test --release`（约 60-100s/测试）。

## 0. 前置：构建固件与底座

产物路径**不硬编码**：mcu_simulater 测试经 `mcu_simulater::artifact` 解析
（环境变量 `JOC_BASE_ELF` / `JOC_APP_FLYCTRL` / `JOC_APP_DRVTEST` / `JOC_APP_SDK`
→ 壳工程规范布局 → 历史开发机路径兜底）。一键联调 `./scripts/integrate.sh firmware`
即完成以下构建并导出变量：

```bash
# RTOS 底座 ELF（joc-base 内，一次性；产物落壳工程规范布局 build_hil/）
cd joc-base && cmake -S . -B build_hil -DMCU_SIM=ON -DRTOS_SELFTEST=OFF && cmake --build build_hil

# 固件（flyctrl 内；两种 feature 产物）
cd flyctrl
python3 build_app.py --features real-sensors --out /tmp/flyctrl_real.bin
python3 build_app.py --features hil            --out /tmp/flyctrl_hil.bin
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

## 3. SIL（纯算法回归，无 MCU）

```bash
cd fly-simulater
cargo test -p fly-sim-core                 # 8 项（含磁力计几何/decl）
cargo test -p fly-sim-core --test mag_hover # 磁锚定闭环悬停（ToyWorld）
cargo test --test sensor_fault              # 故障注入 6 项
```

## 4. HIL 双机闭环（MCU 控制 + PC 物理）

固件 hil feature + USB CDC 链路：PC 注入 HIL_SENSOR/设定点，MCU 回传执行器。

```bash
cd mcu_simulater
cargo test --release --test x_hil_mcusim    # ~53s，roll/pitch/位置不发散
```

## 5. 故障注入与调试平台

```bash
cd mcu_simulater
cargo test --release --test x_fault_injection   # 时间轴故障剧本（NACK/丢帧/Halt）
cargo test --release --test x_bus_trace         # I2C/UART 事务嗅探
cd fly-simulater
cargo test --test sensor_fault                  # GPS 偏置/卡死、IMU 冻结 → FDIR
```

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
| 测试报产物缺失（ELF / app.bin） | 产物路径经 `mcu_simulater::artifact` 解析：先跑 `./scripts/integrate.sh firmware` 构建到规范布局，或用 `JOC_BASE_ELF` / `JOC_APP_*` 环境变量指向已有产物 |
| debug 测试极慢 | 机器内存压力/swap：用 `--release` |
