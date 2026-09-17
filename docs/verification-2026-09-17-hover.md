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

## 5. 文档漂移清单（本次一并处理）

| 位置 | 旧断言 | 现状 |
|---|---|---|
| `engineering.md` §physics、`integration.md` §3 | 「physics 缺失时 SIL 用 ToyWorld 替身物理」/「mag_hover（ToyWorld）」 | 源码中 **ToyWorld 已删**，`mag_hover` 用 `PhySdkWorld` |
| `integration.md` §5.5 虚拟时钟 | 「30M→172M 校准使**场景时间 = 固件时间**」 | 已被 c62ec21 取代：`VIRTUAL_INSNS_PER_SEC=172M` 只是**推流时钟**；**固件自身时钟**按 `RETIRED_BYTES_PER_MS=95_600` 字节/ms，`run_ms` 按固件 SysTick 收敛 |
| `integration.md` 环境提示 | 「约 60-100s/测试」 | 实测 `x_vperiph` 101s、`x_hover_demo` ~770s、`x_hover_env` ~422s |
| `integration.md` §已知基线问题 | 「x_hover_demo 全绿」 | 当前快照 FAIL（见 §2/§3）；x_hover_noise 的 ToyWorld 诊断失去物理依据，需在 PhySdkWorld 上重做 |
| `README.md` / `docs` / `scripts/integrate.sh` 产物名 | `./scripts/build.sh real-sensors` 应产出 `/tmp/flyctrl_real.bin` | `build.sh` 旧写法拼成 `/tmp/flyctrl_real-sensors.bin`，无人引用 → **本次修复 `scripts/build.sh`**；11 个测试统一走 `artifact` 解析（**本次**） |

## 6. 待办

- [ ] **44s 发散定位**（本项复验的核心残留）。在「已修测试侧读回」的工作区基线上做；
      12s 与 44s 之间无覆盖，先补中间尺度的观测点。
- [ ] `x_hover_noise` 在 `PhySdkWorld` 上重做诊断（旧结论建立在已删除的 ToyWorld 上）。
- [x] (b) 产物路径纪律收口：`build.sh` 对齐 `/tmp/flyctrl_real.bin`；mcu_simulater
      的 10 个测试与 `fly-sim-server` 的 `VP_APP` 统一走
      `mcu_simulater::artifact::flyctrl_real_app_bin()`（新增 env
      `JOC_APP_FLYCTRL_REAL`）。代码中暂无遗留硬编码（仅 artifact 默认候选与文档引用该名）。
- [ ] 长测试不要再以阻塞式单次工具调用跑（会被外部中断）；改 `nohup` 后台 + 短调用轮询。

## 7. 复验方法备注

- 长测试（60s 悬停演示单次约 7-13 分钟）**本次不再跑**，结论均基于已有证据与既有运行输出。
- 测试耗时受内存压力影响明显；跑时用 `--release`。
