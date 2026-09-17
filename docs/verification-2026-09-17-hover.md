# 悬停基线复验（2026-09-17）

对锁定快照复验伞层文档的悬停断言（原计划 (a)）。结论：**虚拟外设闭环在 12s 尺度上
稳定悬停成立；文档里「`x_hover_demo` 全绿」的断言不成立**——当前快照上两个 60s 测试
FAIL，主因是测试侧漏改，修掉后仍有 44s 发散未定位。

本文是这次复验的权威记录；`integration.md` / `engineering.md` 里与之冲突的旧断言
以本文为准，相关处已加指针。

## 1. 虚拟外设直通闭环：12s 悬停成立

`x_vperiph_mcusim`（该测试文件本次未改动）：

```
test result: ok. 3 passed; 0 failed; finished in 101.44s

vperiph_closed_loop      60 步   (0.24s)  max_thrust=2.145
vperiph_hover_long      300 步   (1.2s)   末段 |dz|=0.273m  姿态=(-0.00°,-0.01°)
vperiph_hover_sustained 3000 步 (12.0s)   末段 pos≈(0.00,0.00,-4.77)m  姿态=(-0.00°,0.02°)
                                          早段 -5.075 / 中段 -5.088 / 末段 -4.774
```

**结论：12s 尺度稳定悬停，通过、可复现。** 这正是「用虚拟外设跑飞控仿真能稳定悬停」
的正面证据。

## 2. 当前快照上两个 60s 测试 FAIL

| 测试 | 实测 |
|---|---|
| `x_hover_demo` | max\|roll\|=**179.7°**、pitch 89.8°，机体落在 `pos.z=4.90` 不动，EKF 高度跑到 **+454m**，最后崩在 `UC_ERR_READ_UNMAPPED` |
| `x_hover_noise` | max\|roll\|=**179.98°**、pitch 87.4°，机体同样落地不动，EKF 高度 **+427m** |

两者都远超文档断言（末态姿态 0.0° / max\|roll\|=0.01°，noise 残余 30°）。

## 3. 主因：测试侧 PWM 读回漏改（已定位、已修）

时间线：

```
09-17 01:17  mcu_simulater cc88278  x_hover_demo 最后一次修改（当时全绿）
09-17 09:48  joc-base      eec5b58  pwm2 从 TIM1_CH1_PA8 改挂 TIM5_CH2_PA1   ← 分水岭
09-17 10:41  mcu_simulater 7b3166d  x_vperiph 同步读回（TIM5 + CCR2=0x38）✓
09-17 17:31  mcu_simulater c62ec21  run_ms 取代退休字节预算
09-17 17:43  伞工程        72e46d6  更新五个子模块指针 ← 提交的快照
```

09:48 板级把 pwm2 挪到 TIM5，10:41 只补了 `x_vperiph`，**`x_hover_demo` /
`x_hover_noise` / `x_hover_env` 漏改**——它们仍读 TIM1，电机 2 恒读 0。所以这三个
测试从 09:48 起就是坏的，比 17:43 的快照指针更新更早；`x_vperiph` 一直好，所以
「跑 `x_vperiph` 通过」完全合理。

修复（**工作区未提交**，`mcu_simulater`）：

```
M tests/x_hover_demo.rs
M tests/x_hover_env.rs
M tests/x_hover_noise.rs
（3 files changed, 96 insertions(+), 39 deletions(-)）
```

## 4. 修掉读回后：稳定悬停 44s，然后发散

`x_hover_demo` 从「一释放就落地 + roll 180° 翻滚」变成：

```
t=0..44s   |dz| ≤ 0.41m，水平漂移 0.00m，roll/pitch ≈ 0，thrust≈2.03（悬停油门）
t=44s 起   下沉 → 落地 → 翻滚，max|roll|=37.4°
```

**残留：第 44s 起的发散未定位。** 覆盖盲区：现有 MCU 在环悬停最长验证是
`vperiph_hover_sustained` 的 **12s**，**12s→44s 之间没有任何测试覆盖**。

### 4.1 定位（2026-09-18 复现）

先修掉了阻挡复现的测试自死锁（`x_hover_demo` 诊断块持 `Machine` 锁时再调
`dump_est_state`）——修后测试能跑完（墙钟 ~333s）。每秒 `[demo]`（物理真值）与
`[demo-est]`（固件 EKF，`VehicleState@0x2000_9084`）显示：

- t=0..37s：物理与 EKF 均为零振荡（水平速度 <0.005、电机差动 0.000）。
- t≈38s 起：**物理滚转角速度 `plant_w` 指数增长**（0.02→0.06→0.13→0.26→0.43
  rad/s，每 ~1.4s 翻倍），到 t≈45.8s 物理滚转 ±17°，随后翻机落地。
- 同期**固件 EKF 的姿态估计几乎不动**（roll 估计 0.00→0.34°），电机差动也只有
  0.00x —— 控制器基本没在纠。

用 20ms 分辨率对照（临时 `[hr]` 诊断，已撤）拿到决定性一行：

```
t=45.00  plant_roll=-1.87°  plant_w=(-0.430,..)  inj_g=(-0.430,..)  est_roll=-0.00°
```

`plant_w`（物理机体系角速度）与 `inj_g`（注入固件的陀螺 `FlySimState.imu_gyr`）
**逐位相等** → 注入链路正确；而固件 EKF 的 `att` 仍是单位四元数。固件 EKF 预测步
（`flyctrl/core/src/estimator/ekf.rs:271`）`self.att = self.att.integrate(wx,wy,wz,dt)`
是无条件用陀螺积分的——陀螺 0.43 rad/s 必然推动 att。att 不动 ⇒ **固件实际读到的
BMI088 陀螺为 0**。

**结论**：44s 发散 = 姿态环没有有效角速率阻尼。固件拿不到陀螺 → `att_kd` 阻尼项
失效 → 退化为「纯 P 姿态环 + 一步延迟」→ 极点落在单位圆外 → 从数值噪声慢速自激
（~38s 可见、46s 翻机）。同一机制解释了 `x_hover_noise`（噪声激励使发散快得多）
与 `x_vperiph` 12s 通过（12s < 38s）。

根因在**固件读 BMI088 陀螺的路径**（real-sensors 用 `ImuBmi088`/SPI；
`joc-base/src/drv/bmi088.c` 的 GYR 块读 / `gyro_cs` 片选 / RTOS SPI DMA），
不在被控对象、也不在控制律增益。加速度通道正常（悬停成立），故是陀螺专属路径。

## 5. 文档漂移清单（本次一并处理）

| 位置 | 旧断言 | 现状 |
|---|---|---|
| `engineering.md` §physics、`integration.md` §3 | 「physics 缺失时 SIL 用 ToyWorld 替身物理」/「mag_hover（ToyWorld）」 | 源码中 **ToyWorld 已删**，`mag_hover` 用 `PhySdkWorld` |
| `integration.md` §5.5 虚拟时钟 | 「30M→172M 校准使**场景时间 = 固件时间**」 | 已被 c62ec21 取代：`VIRTUAL_INSNS_PER_SEC=172M` 只是**推流时钟**；**固件自身时钟**按 `RETIRED_BYTES_PER_MS=95_600` 字节/ms，`run_ms` 按固件 SysTick 收敛 |
| `integration.md` 环境提示 | 「约 60-100s/测试」 | 实测 `x_vperiph` 101s、`x_hover_demo` ~770s、`x_hover_env` ~422s |
| `integration.md` §已知基线问题 | 「x_hover_demo 全绿」 | 当前快照 FAIL（见 §2/§3）；x_hover_noise 的 ToyWorld 诊断失去物理依据，需在 PhySdkWorld 上重做 |
| `README.md` / `docs` / `scripts/integrate.sh` 产物名 | `./scripts/build.sh real-sensors` 应产出 `/tmp/flyctrl_real.bin` | `build.sh` 旧写法拼成 `/tmp/flyctrl_real-sensors.bin`，无人引用 → **本次修复 `scripts/build.sh`**；11 个测试统一走 `artifact` 解析（**本次**） |

## 6. 待办

- [x] **44s 发散定位**：已定位到「固件 BMI088 陀螺读取为 0 → 姿态环无阻尼 → 纯 P
      环慢速自激」（见 §4.1）。**待修**：固件/RTOS 的 BMI088 gyro 读取路径。修后
      重跑 `x_hover_demo` 应能过 60s；同时 `x_hover_noise` 大概率一并改善。
- [x] `x_hover_noise` 重诊断：与 44s 发散同机制（同一陀螺缺失），非 ToyWorld 遗留；
      待陀螺修复后重跑确认。
- [x] (b) 产物路径纪律收口：`build.sh` 对齐 `/tmp/flyctrl_real.bin`；mcu_simulater
      的 10 个测试与 `fly-sim-server` 的 `VP_APP` 统一走
      `mcu_simulater::artifact::flyctrl_real_app_bin()`（新增 env
      `JOC_APP_FLYCTRL_REAL`）。代码中暂无遗留硬编码（仅 artifact 默认候选与文档引用该名）。
- [ ] 长测试不要再以阻塞式单次工具调用跑（会被外部中断）；改 `nohup` 后台 + 短调用轮询。

## 7. 复验方法备注

- 长测试（60s 悬停演示单次约 7-13 分钟）**本次不再跑**，结论均基于已有证据与既有运行输出。
- 测试耗时受内存压力影响明显；跑时用 `--release`。
