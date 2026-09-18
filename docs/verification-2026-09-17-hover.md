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

### 4.1 定位（2026-09-18 复现，结论经两轮修正）

先修掉了阻挡复现的测试自死锁（`x_hover_demo` 诊断块持 `Machine` 锁时再调
`dump_est_state`）——修后测试能跑完（墙钟 ~333s）。

**假设一（已证伪）**：曾怀疑「固件读到的 BMI088 陀螺为 0」。用隔离测试
（临时 `x_imu_gyro_path`）注入恒定角速度直接验证：固件 EKF 的 `est.omega`
逐档准确——1.5/0.5/0.3/0.1 rad/s → 1.499/0.499/0.299/0.099，且 `qx` 随幅值单调
积分。**陀螺注入路径正常，该假设不成立。**

**实测机制**：在发散区做 20ms 对照（临时诊断，已撤）：

```
t=45.00  plant_wx=-0.430  est_wx=-0.431  est_roll≈-0.01°  motor_diff≈-0.001
```

- `est_wx` 与 `plant_wx` 逐点相等 → **估计角速度正确**；
- `est_roll` 恒 ≈0 → **姿态估计被钉在水平**；
- 电机差动只有 0.001~0.015 → **控制器几乎不纠**。

**姿态估计为什么钉在水平**：四旋翼有推力时，加速度计测的是**推力方向（机体 Z）**，
不是重力方向。隔离测试实证：同一四元数下 `R^T·g` 有 y 分量（-2.686），但带悬停
推力的实际样本是 `ay≈0、az≈-9.8`——比力恒沿机体 Z。EKF 的重力锚定以「比力反方向」
为重力参考，于是恒把姿态锚到「机体 Z 朝上」= 水平。陀螺仍在积分，但被锚定大幅
衰减（隔离测试：0.5 rad/s 持续 1s 只积到 3.8°，而非 28.6°）。

**结论（修正）**：44s 发散是**闭环边缘稳定**，与固件陀螺读取无关：

1. 姿态估计被锚定钉在水平 → 姿态环 P 项（`att_kp·err`）失效；
2. 只剩角速率阻尼 `-att_kd·omega`，实测电机差动 0.00x 量级，阻尼很弱；
3. 滚转模态近乎无阻尼 → 从数值噪声慢速自激（~38s 可见、46s 翻机）。

同一机制解释 `x_hover_noise`（噪声激励加快）与 `x_vperiph` 12s 通过（12s < 38s）。

**待办方向（未做，需对照实验定夺）**：
(a) 估计器：重力锚定不应在「比力＝推力方向、持续缓变转动」时把姿态钉平
（例如引入机动/观测一致性检测或降权）；
(b) 控制：提高角速率阻尼（`att_kd`）或补机体角阻尼。

**候选 (a) 实测（2026-09-18）—— 反而更糟，已 revert**：把重力锚定的陀螺门控阈值
下调到噪声量级（0.25~0.6 → 0.05~0.15 rad/s），让真实转动时关闭锚定。结果
`x_hover_demo` 从「44s 慢速发散」变成 **「t≈37s 起 3 秒内飞出 8m、max|roll|=180°」**
（290s 失败，比修复前更早更猛）。即**打开姿态 P 项后发散更快** ⇒ 姿态反馈是
**正反馈**；原来的强锚定把姿态估计钉平、变相关掉了 P 项，才把它掩盖成「慢速自激」。

这与 `fly-sim-core/src/plant.rs`（`read_sensors` 上方注释）警告的
「sensor/actuator 反射不一致 → 对应轴阻尼项符号反掉 → 倾斜后 p 速率指数增长炸机」
完全吻合。

**结论再次更新**：真正待修的是**姿态控制环的符号/坐标系一致性**——
估计器侧姿态+角速度反射（`plant.rs::read_sensors` 的 `omega_fc=[-x,-y,+z]`）
↔ 固件控制器（`attitude_rates` 四元数误差 + `x4_mix` 混控）
↔ 被控对象侧力矩反射（`plant.rs::step` 的 `tau_body[0] = -tau_body[0]`）。
三者必须同一约定，否则姿态 P/速率 D 反馈符号可能与真实转动同向（正反馈）。
下一步应逐轴核对这条链，找出反号的那一轴。锚定阈值不是根因（已还原）。

**符号链离线验证（2026-09-18，回归测试 `fly-sim-core/tests/torque_sign.rs`）**：
「正反馈＝符号/坐标系反号」也被证伪。离线测得 控制器→混控→被控对象 三段一致：

- `x4_mix(hover, +p/+q/+r)` 经臂力矩+反射后产生**同向**飞控系角速度
  （+p→+ωx、+q→+ωy、+r→+ωz）；
- 机体 +roll 时 `attitude_rates(des=level)` 输出**反号** p_cmd（正确纠正）。

结论：44s 发散**不在** 控制器/混控/被控对象 的符号上；剩余嫌疑集中在
**估计器姿态与位置环的耦合**（锚定把姿态钉平 → EKF 的 `a_world=R(att)·a_body`
用了错误姿态 → 速度/位置估计漂移 → 外环指令发散；把锚定关掉又让嵌套环整体
失稳，故更快炸机）。这一段需要嵌套环稳定性分析，不是单点符号问题。

**候选 (c) 实测（2026-09-18）—— 成立（已落地）**：给被控对象补**转动气动阻尼**
（原 plant 只有平动 `drag_coeff`、无转动项）。新增 `VehicleConfig.angular_drag`
默认 `[0.2,0.2,0.4]` N·m·s/rad（= I/0.1，角速度时间常数 τ≈0.1s），在 `plant.step`
以 `τ=-c·ω_body` 施加。

- `x_hover_demo` 60s：**PASS**——`max|roll|` 37°→**3.26°**，44s 发散消失；
- 系数阈值对照：τ=0.3s(`0.067`)→54s 发散 FAIL；τ=0.15s(`0.133`)→19.85° FAIL；
  τ=0.1s(`0.2`)→PASS ⇒ 该模式需要 τ≲0.12s 的转动阻尼；
- 回归：`fly-sim-core` 单测 8+1 通过、`x_vperiph` 12s 3/3 通过；`x_hover_noise`
  由 180°→73°（改善但未过）、`x_hover_env`/`sensor_fault::gps_bias_step` 为**既有
  失败**（阻尼=0 时同样失败，已做 A/B 确认非本次引入）。

**结论**：44s 发散的**主因是被控对象缺转动气动阻尼**——SIL 姿态模态原先只有控制器
D 项阻尼，近乎无阻尼 → 慢速自激。补上物理角阻尼即稳定。注意同一改动**修不了**
带噪/带扰的 `x_hover_noise` / `x_hover_env`（它们另有问题），仍需 (A) 嵌套环/估计器
分析——这也是下一步。

### 4.2 带噪场景（A：`x_hover_noise` / `x_hover_env`）

补阻尼后 `x_hover_noise` 由 180°→73°，仍超 15° 断言，且**发散很快**（t≈5s 起、
t≈12s 落地），与 44s 慢模态不同。每秒 EKF 全状态 dump 显示：**水平速度估计剧烈摆动**
（`|v_h|` 0.36→1.22→2.43→3.65→4.60 m/s），控制器据此让电机差动从 0.02 涨到 0.5，
被控对象速度随之 ±5 m/s 振荡 → 失控。姿态估计本身基本正常（quat≈单位）。

即带噪场景是**噪声驱动的控制摆动**：估计器输出的速度噪声直接进了位置外环。
现有 `CtrlParams.vel_lpf_tau`（PLAN 11-A）**只滤波垂向速度**（防 IMU 噪声直驱油门），
水平通道没有等效处理。`x_hover_env`（72°）大概率同源（扰动 → 估计摆动 → 外环振荡）。

**候选修法（需设计决策）**：给水平速度（及必要时姿态）估计加同口径低通 / 降外环增益 /
调 EKF 观测-过程噪声权衡。降低带宽会牺牲机动响应，属权衡，不宜擅自定。

### 4.3 时钟对齐机制（L1~L3 已落地）

**病根**：测试把「时间」写成字节预算（`run(300_000)`、`STEP_INSNS=2_300_000`），
而字节预算只在固定仿真器+固定代码块混合比下才近似等于时间（实测同预算 100K~109K
bytes/ms 浮动）→ 换后端/固件即失效。

**机制（已实现）**：
- `mcu_simulater::clock::{McuClock, SimClock, HilStepper}`：时间只以毫秒表达，
  后端实现一次即可换（Unicorn 现在，QEMU/FPGA/真板未来）；
- `Machine::run` → `run_budget`（文档写明「非时间语义，闭环不得用」），`Machine::systick_ms()`；
- `EnvHarness`：`run(2_300_000)`(≈21.5ms 固件/13.37ms 场景) → 整数毫秒 `STEP_DT_MS=13.0`
  经 `McuClock` 推进；`x_hover_env`：`run(300_000)`(≈3.3ms) → `run_ms(4.0)`；
- `EnvHarness::step` 加**对齐断言**（固件时间 ≈ 步数×dt，≤1ms），改回字节预算立即红。

**实测（当前固件，SysTick 计数）**：`run(300_000)`=3.30ms、`run(2_300_000)`=21.55ms、
`run_ms(4.0)`=4.000ms。

**对齐暴露的既有测试问题**：`x_env_motion::turn_yaw_rate_tracks` 的
`yaw_total > 1.0` 断言**只在旧的失配步进下通过**（固件快 1.6× → yaw 多转）。
A/B：旧步进 PASS、对齐后 FAIL（`yaw_total=0.66`）。角速率断言（0.3~0.7 rad/s）两边
都过 ⇒ 该阈值按失配行为标定，需按对齐后的真实场景重标（另需核对 env 磁力计/yaw 锚定）。

### 4.4 EKF 时间基：控制/EKF 用实测周期（1a，已修）

时钟对齐（§4.3）只保证了 harness 的 run 预算不错；**固件内部**还有一处标称 vs 实际：
控制任务 `msleep(4)` + EKF/控制工作量常超 4ms 预算 → 实际拍率掉到 ~102Hz（周期 ~9.8ms），
而 `HilContext.dt` 是编译期常量 4ms → EKF 每 9.8ms 只积 4ms，**系统性少积 ~2.4×**。

实测（注入 1.0rad/s 陀螺、SysTick 走 1000ms）：姿态只积 **0.407rad**；`turn_yaw_rate_tracks`
的场景真值 1.293rad、EKF 只 0.662rad（比值 0.512）。已排除磁锚定/重力锚定（分别置 0 复测
仍 0.66）。

**修复（flyctrl eca97f2）**：控制循环用「本轮与上轮 `tick_count()` 差」作真实 dt
（clamp 1..50ms）喂 `hil.dt`——控制循环顶部本就有未用的 `let _dt` 占位，即原设计意图。
- `turn_yaw_rate_tracks` 的 `yaw_total`：**0.66(错) → 1.289（真值 1.293）**；
- 回归：`x_vperiph` 3/3、`x_hover_demo` PASS、`x_env_smoke/faults/noise_perturb/longrun/rc` 全过。

**遗留（既有、被 yaw 失败挡住未跑到）**：同测试 `pos_norm` 只 0.08~0.13（期望 >3m），
即 EKF 位置估计未跟随圆周（GPS 位置已注入）——另立待办。
**(b)** 压缩控制/EKF 工作量使其回到 4ms 预算，列为后续优化。

## 5. 文档漂移清单（本次一并处理）

| 位置 | 旧断言 | 现状 |
|---|---|---|
| `engineering.md` §physics、`integration.md` §3 | 「physics 缺失时 SIL 用 ToyWorld 替身物理」/「mag_hover（ToyWorld）」 | 源码中 **ToyWorld 已删**，`mag_hover` 用 `PhySdkWorld` |
| `integration.md` §5.5 虚拟时钟 | 「30M→172M 校准使**场景时间 = 固件时间**」 | 已被 c62ec21 取代：`VIRTUAL_INSNS_PER_SEC=172M` 只是**推流时钟**；**固件自身时钟**按 `RETIRED_BYTES_PER_MS=95_600` 字节/ms，`run_ms` 按固件 SysTick 收敛 |
| `integration.md` 环境提示 | 「约 60-100s/测试」 | 实测 `x_vperiph` 101s、`x_hover_demo` ~770s、`x_hover_env` ~422s |
| `integration.md` §已知基线问题 | 「x_hover_demo 全绿」 | 当前快照 FAIL（见 §2/§3）；x_hover_noise 的 ToyWorld 诊断失去物理依据，需在 PhySdkWorld 上重做 |
| `README.md` / `docs` / `scripts/integrate.sh` 产物名 | `./scripts/build.sh real-sensors` 应产出 `/tmp/flyctrl_real.bin` | `build.sh` 旧写法拼成 `/tmp/flyctrl_real-sensors.bin`，无人引用 → **本次修复 `scripts/build.sh`**；11 个测试统一走 `artifact` 解析（**本次**） |

## 6. 待办

- [ ] **44s 发散修复**：已排除陀螺路径、锚定阈值、控制器/混控/被控对象符号链
      （§4.1，均有回归测试/实测）。剩余嫌疑：估计器姿态（被锚定钉平）与位置外环的
      耦合——需嵌套环稳定性分析（`a_world=R(att)·a_body` 用错姿态 → 速度估计漂移）。
- [ ] `x_hover_noise` 重诊断：初步判定与 44s 发散同机制（姿态估计钉平 + 阻尼弱），
      非 ToyWorld 遗留；待 44s 修法确定后一并验证。
- [x] (b) 产物路径纪律收口：`build.sh` 对齐 `/tmp/flyctrl_real.bin`；mcu_simulater
      的 10 个测试与 `fly-sim-server` 的 `VP_APP` 统一走
      `mcu_simulater::artifact::flyctrl_real_app_bin()`（新增 env
      `JOC_APP_FLYCTRL_REAL`）。代码中暂无遗留硬编码（仅 artifact 默认候选与文档引用该名）。
- [ ] 长测试不要再以阻塞式单次工具调用跑（会被外部中断）；改 `nohup` 后台 + 短调用轮询。

## 7. 复验方法备注

- 长测试（60s 悬停演示单次约 7-13 分钟）**本次不再跑**，结论均基于已有证据与既有运行输出。
- 测试耗时受内存压力影响明显；跑时用 `--release`。
