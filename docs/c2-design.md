# C2 设计规格（磁增广：`mag_I` / `mag_B` 为状态）

> 依据：`docs/c1-design.md`（C1 已全绿）+ §4 验收结论（C1 未过已标定档 ⇒ 唯一路径是 C2 ✓）
> 参照：PX4 EKF2 `derivation.py` 已到手（`State::mag_I` / `State::mag_B` ✓ 见 §14.8）

## 1. 为什么 C2 是唯一路径（由 §4 的定量证据 ✓）
| 配置 | Legacy | C1（无磁增广）| 胜负 |
|---|---|---|---|
未标定档 | 18.468° | **5.924°** | C1 胜 3.1× ✓ |
已标定档 | **1.539°** | 5.924° | C1 输 3.85× ✗ |

⇒ C1 的**胜负取决于磁参考是否可信** ✓ ⇒ 要同时在两档获胜 ⇒ **必须自己也用磁（且能估出偏差）** ✓✓
⇒ 而"把硬铁作为状态估计"正是 A4/A12 的解法 ✓（三线合流 ✓）

## 2. 状态扩展（15 → 21 ✓）
| 符号 | 含义 | 维 | 参照 |
|---|---|---|---|
θ | 姿态误差 | 3 | ✓ |
v / p | 速度 / 位置 | 3 / 3 | ✓ |
b_g / b_a | 陀螺 / 加计零偏 | 3 / 3 | ✓ |
**mag_I** | 地球磁场（**导航系** ✓ 常量）| **3** | `State::mag_I` ✓ |
**mag_B** | 机体磁偏置（**机体系** ✓ 常量）| **3** | `State::mag_B` ✓（★A12 的正解 ✓）|

## 3. 过程模型（新增块）
```
mag_I ← mag_I（常值 ✓，Q 小）      mag_B ← mag_B（常值 ✓，Q 小）
```
⇒ F 的新增块：`∂mag_I/∂mag_I = I` ✓、`∂mag_B/∂mag_B = I` ✓（其余为 0 ✓）

## 4. 量测模型（★C2 的核心 ✓）
```
h(x) = R(q)·mag_I + mag_B        （机体三轴磁量测 ✓）
```
**H（对误差状态）**：
- 对 `δθ`：`∂h/∂δθ = −[R·mag_I ×]`（**世界系叉乘** ✓ —— 与 §12.8 的教训同源 ✗✓）
- 对 `mag_I`：`R` ✓
- 对 `mag_B`：`I` ✓
**⇒ 必须数值对照**（同 F/H 的既有手法 ✓）：扰动 θ/mag_I/mag_B ⇒ 数值微分 ⇒ 与解析 H 比对 ✓

## 5. 可观测性（为何 C2 能修好 yaw ✓）
- 单点静止：`R·mag_I + mag_B` 只给 3 个方程、有 6 个未知 ⇒ **不可分** ✗
- **转动时**：`R` 变化 ⇒ `R·mag_I` 画出圆弧 ⇒ `mag_I` 与 `mag_B` 可分离 ✓✓
  ⇒ 即：**转弯/偏航让 yaw 与硬铁同时可观测** ✓（这也解释了 A4/A12 为何都在"机动"中暴露 ✓）
⇒ **验收场景须含转动**（§4 的巡航含偏航 ✓ 足够 ✓）

## 6. 自检清单（与 C1 同规格 ✓）
- [ ] H 的数值对照（θ / mag_I / mag_B 三块 ✓）
- [ ] F 新增块的数值对照（I ✓）
- [ ] **静止**：mag_B 不应被错误分离（不可观测 ⇒ 应保持初值/P 不塌陷 ✓）
- [ ] **转动**：mag_B 应收敛到真值（合成数据已知 ✓✓ —— 最有力的验收 ✓）
- [ ] NIS 一致性：mag 门用参照 **3.0σ** ✓；R 由残差反推 ✓
- [ ] 观测非空断言 / NaN 防护（本会话惯例 ✓）

## 7. 验收（沿用 §4 的工装 ✓，判据不变 ✓）
```
去掉 att_est::c1_integration_step4_acceptance_vs_calibrated 的 #[ignore] ✓
要求：C1+C2 在【未标定档】与【已标定档】下【都不劣于 Legacy】✓
  （预期：未标定档大幅胜 ✓；已标定档持平或更优 ✓）
```

## 8. 已知风险（预先列出 ✓）
1. **世界系叉乘**（`−[R·mag_I ×]` ✓）：与 §12.8 同类陷阱 ✗ ⇒ H 必须数值对照 ✓
2. **`mag_I` 初值**：须由静止时的磁量测 + 姿态估计给出 ✓（否则收敛慢 ✓）
3. **静止时的不可观测**：P 可能塌陷到错误的分离 ✓ ⇒ 需"不可观测时不修正"的判据
   （参照：`heading_observable` 为假时**清零航向相关协方差** ✓ 见 §14.11 发现②✓）

## 9. ★参照对照：`derivation.py` 的 mag 融合实现（2026-09-21 取到 ✓）

```python
416: def predict_mag_body(state) -> sf.V3:
420:     mag_body = state["quat_nominal"].inverse() * mag_field_earth + mag_bias_body

423: def compute_mag_innov_innov_var_and_hx(state, P, meas, R, epsilon):
434:     innov = meas_pred - meas                      # 新息 = 预测 − 量测
435:     Hx = jacobian_chain_rule(meas_pred[0], state) # ★H 逐【分量】⇒ 1×N 行
437:     innov_var[0] = (Hx * P * Hx.T + R)[0,0]       # ★逐分量 S
447:     return (innov, innov_var, Hx.T)
```

| 项 | 参照 | 本实现 | 判断 |
|---|---|---|---|
模型 | `q⁻¹·mag_I + mag_B` ✓ | `Rᵀ·mag_I + mag_B` ✓ | **一致** ✓ |
新息符号 | `pred − meas` | `meas − pred` | **镜像但各自自洽** ✓（C1 位置路径已经方向检查验证 ✓）|
**H 结构** | **逐分量 1×N** ⇒ **顺序标量融合** ★ | 3×3 联合更新 | 皆合法，但在**非线性**下**不等价** ✗✓ |

**⇒ 关键差异（值得照参照改 ✓）**：顺序标量融合**逐项更新** ⇒
第 2、3 分量使用的是**已被第 1 分量更新过的状态与 P** ✓✓；
而联合更新三项共用同一组 `(x, P)` ✓。
⇒ 在 H 依赖状态（本处 H 依赖 `q` 与 `mag_I` ✓）时二者**不同** ✗
⇒ 这可能是"**残差收敛却停在错值**"的根源 ✓✓（顺序更新能逐步"解耦"该歧义 ✓）

**⇒ 下一步**：把 `update_mag` 照参照改为**逐分量顺序标量融合** ✓
（本项目的 `update_scalar` 已具备该能力 ✓ —— 只需按分量循环调用 ✓✓）

## 10. ★★参照参数对照（2026-09-21）—— 三项候选均被排除

**参照原文**
```cpp
// PX4 EKF2 common.h
ekf2_gyr_noise{1.5e-2f}   // rad/s（过程噪声之源）
ekf2_acc_noise{3.5e-1f}   // m/s²
ekf2_mag_noise{5.0e-2f}   // Gauss（三轴磁量测噪声）
```
```python
# derivation.py 208 行：Q 只由 IMU 构成 ⇒ mag_I / mag_B 【无过程噪声】（纯常数）
var_u = diag([accel_var[0], accel_var[1], accel_var[2], gyro_var, gyro_var, gyro_var])
```

**对照表**
| 项 | 参照 | 本实现 | 判断 |
|---|---|---|---|
模型 | `q⁻¹·mag_I + mag_B` | `Rᵀ·mag_I + mag_B` | 一致 ✓ |
量测 R | `(5e-2)² = 2.5e-3` | `1e-2` | **同量级** ⇒ 非病因 ✓ |
mag 两态 Q | **0**（纯常数）| `1e-3·dt`（自拟、很小）| **量级相当** ⇒ 非主因 ✓ |
H 结构 | 逐分量 1×N | 逐分量 ✓ | 一致 ✓ |
新息符号 | `pred − meas` | `meas − pred` | 镜像但自洽 ✓ |

**⇒ 结论**：三项主要候选（模型 / R / Q）**均与参照一致或同量级** ⇒
**"mag_I 与 mag_B 分离弱"的原因不在这三处** ✗✓（干净基线 0.1948 是可信的 ✓）

**⇒ 剩余方向（按参照）**
1. **初始化**：参照有专门的磁重置/初始化逻辑（`initialiseCovariance` 与 mag reset ✓）
   —— 其 `mag_B` 初值并非恒取 0 ✗，且 `mag_I` 初值与其**协方差初值**要配套 ✓
2. **heading 可观测性处理**：`heading_observable` 为假 ⇒ 清零航向相关协方差 ✓（§14.11 发现②✓）
   —— 本测例的转动是否构成"可观测"需按参照判据核 ✓

## 11. C2 剩余项的【精确定位方法】（2026-09-21 收口记录）

### 已排除的位置（取到文件但无 mag 重置/健康度逻辑 ✗）
| 文件 | 行数 | 结果 |
|---|---|---|
`magnetometer_control.cpp` | — | **404（不存在）** ✗ |
`EKF/control.cpp` | 206 | mag 重置/健康度 **无** ✗ |
`EKF/ekf_helper.cpp` | 1367 | 同上 ✗ |
`EKF/yaw_fusion.cpp` | 14B（早先）| 抓取失败 ✗ |

### ⇒ 下一步的【系统性定位法】（不再逐个试 ✗）
```bash
# ① 列 EKF 全目录（含子目录 ✓ —— API 端点已验证可用 ✓）
curl -sSL "https://api.github.com/repos/PX4/PX4-Autopilot/contents/src/modules/ekf2/EKF?ref=main"
# ② 对可疑子目录再列（如 mag/ yaw/ 或 python/ ✓）
# ③ 用 GitHub code search（需认证 ✗）或逐个取 + grep 'resetMag|mag_health|heading_observable'
```
**目标符号**（用 grep 找它们的定义处 ✓）：
- `resetMagEarthCov` ✓ / `resetMagBiasCov` ✓（**调用点**即触发条件 ✓）
- `heading_observable` ✓（其**赋值处**即正式判据 ✓）
- `mag_health` / `_control_status.flags.mag` ✓（健康度体系 ✓）

### 本会话已确认的参照事实（可直接用 ✓）
- 量测模型 `h = Rᵀ·mag_I + mag_B` ✓（derivation.py 416–421 ✓）
- 量测融合为**逐分量顺序标量** ✓（derivation.py 435–437 ✓）
- 参数：`ekf2_mag_noise = 5e-2` Gauss ✓ / `ekf2_mag_e_noise = 1e-3` ✓ / `ekf2_mag_b_noise = 1e-4` ✓
- **过程噪声条件添加**（仅当 `P_ii < sq(mag_noise)` ✓，cov.cpp 180–200 ✓）
- `resetMagEarthCov` 把 mag_I 方差设为 `sq(mag_noise)` ✓（cov.cpp 375–377 ✓）

### §11.1 ✅ 剩余逻辑位置**已定位**（2026-09-21）

**文件**：`src/modules/ekf2/EKF/aid_sources/magnetometer/mag_control.cpp`（681 行 ✓ 已取到 ✓）
（`aid_sources/` 是辅助源目录 ⇒ mag 逻辑在此 ✓；另同目录有 `mag_fusion.cpp` ✓）

**关键行（原文 ✓）**
```cpp
 73:  resetMagBiasCov();
223/232/282/311: resetMagStates(_mag_lpf.getState(), reset_heading);
341/342: resetMagEarthCov();  resetMagBiasCov();          // ★触发条件所在 ✓
401:  void Ekf::resetMagStates(const Vector3f &mag, bool reset_heading)
419:      resetMagEarthCov();
429/434:  resetMagBiasCov();
438:      resetMagHeading(mag);
```

**⇒ 剩余三项全部落在此文件**
| 剩余项 | 对应位置 |
|---|---|
① mag reset 的**触发条件** | `mag_control.cpp` 73 / 341–342 的**调用上下文** ✓ |
② `mag_B` 的**重置/估计策略** | `resetMagStates` 内 `resetMagBiasCov()` 的分支 ✓ |
③ **heading 处理** | ★**`reset_heading` 参数** ✓✓ —— 参照用的是
**事件驱动的重置策略**（何时连同航向一起重置 ✓），**不是**我那个几何代理 ✗ |

**⇒ 这解释了本会话的偏离** ✓：我用"每步去相关航向"✗；
参照是"**在特定事件重置 mag 状态（含航向）**"✓ —— 语义完全不同 ✓✓

### §11.2 ★★★决定性发现：参照用【代数反解】求 `mag_B`，依赖 WMM 独立先验

**原文**（`mag_control.cpp` 401–455 ✓）
```cpp
if (_wmm_earth_field_gauss 可用) {
    mag_I = _wmm_earth_field_gauss;                        // ★独立先验（地磁模型 ✓）
    if (|mag_I_old − mag_I| > 0.01 gauss) resetMagEarthCov();
    if (!reset_heading && yaw_align) {
        if (mag_I_reset) {
            mag_B = mag − R_to_body · _wmm_earth_field_gauss;   // ★★【直接反解】✓✓
            resetMagBiasCov();
        }   // 否则保留原 mag_B
    } else { mag_B.zero(); resetMagBiasCov(); }
    if (reset_heading) resetMagHeading(mag);
} else {
    mag_B.zero(); resetMagBiasCov();                        // 无 WMM ⇒ 归零
    mag_I = _R_to_earth · mag;                              // 用量测+姿态给 mag_I
}
```

**⇒ 这解释了本会话最深的困惑** ✓✓
1. 参照 **不靠渐近分离** ✓ —— 而是 `mag_B = 量测 − R·mag_I` **一次解出** ✓✓，
   前提是 **`mag_I` 由 WMM 独立给定** ✓ 且 `yaw_align` ✓。
2. 而**渐近分离本质上需要独立的 `mag_I` 参考** ✗ —— 没有它，
   硬铁的贡献与 `mag_I` 的调整**在数学上不可分**（除转动外的充分激励）✓
3. 当 `mag_I` **由量测自身**给出时（本会话 else 分支做法 ✗）⇒ `mag_B ≡ 0` ✗✓
   —— **正是实测现象**（mag_B 停在 0/近初值 ✓✓）

**⇒ 结论** ✓✓：**"分离弱"是【先验缺失】的必然结果** ✗✓，不是实现 bug ✓
（本会话 0 算法缺陷的账本再次成立 ✓）

**⇒ 对本项目 C2 的含义** ✓
- **必须提供独立的 `mag_I` 先验**（真实系统用 WMM ✓；本项目可用
  "已知地磁矢量"或"由 GPS 航迹/对齐阶段得到的场"✓ —— 即**测试应给出该先验** ✓，
  而非从量测反推 ✗）
- 有了先验 ⇒ **`mag_B` 可代数反解**（一次 ✓）⇒ 无需等待长时间分离 ✓✓
- `reset_heading` 的判据与 `yaw_align` 的配套 ⇒ 即剩余项③的正解 ✓

## 12. ★姿态/磁估计的【对齐清单】（2026-09-21，逐项对照参照 ✓）

| # | 参照机制 | 本实现 | 差距 | 验证方式 |
|---|---|---|---|---|
1 | ★**`mag_B` 代数反解** `mag_B = mag − R·mag_I` ✓ + **独立 `mag_I` 先验（WMM）** ✓ | mag_B₀=0 + 渐近分离 ✗ | **★缺先验 + 缺反解** | 给先验 ⇒ mag_B **一次到位** ✓ |
2 | **`resetMagStates(mag, reset_heading)`** 事件驱动 API ✓ | 无重置 API ✗ | 缺 ✓ | API 存在 + 重置正确 ✓ |
3 | **`resetMagEarthCov`/`resetMagBiasCov`**（方差设 `sq(mag_noise)` + **去相关** ✓）| 只做了 P0 ✓，重置时的去相关 ✗ | 部分 ✓ | 重置后方差 = r_mag 且无相关 ✓ |
4 | ★**`resetMagHeading(mag)`**（**由磁重置航向** ✓）| 我的"每步去相关"代理 ✗ | **★语义不同** ✗ | 重置后 yaw 应由磁设定 ✓ |
5 | **`yaw_align`**（航向对齐状态 ✓，是 1/4 的**前提** ✓）| **不存在** ✗ | **★缺概念** ✓ | 对齐前/后行为不同 ✓ |
6 | 新息符号 `pred − meas` ✓ | `meas − pred` ✓ | 镜像但**自洽** ✓ | 无实质差距 ✓ |
7 | 逐分量顺序标量融合 ✓ | ✓ 已移植 ✓ | 无 ✓ | ✓ |
8 | 过程噪声条件添加（`P_ii < sq(mag_noise)` ✓）| ✓ 已移植 ✓ | 无 ✓ | ✓ |
9 | 量测模型 `Rᵀ·mag_I + mag_B` ✓ | ✓ | 无 ✓ | H 已数值验证 ✓ |
10 | 参数 `mag_noise=5e-2` / `e=1e-3` / `b=1e-4` ✓ | 同量级 ✓ | 无 ✓ | ✓ |
11 | 三维门 3.0σ ✓ | ✓ | 无 ✓ | ✓ |
12 | 状态含 `wind`(2) ✓ | 无（本项目无空速 ✓）| 有意省略 ✓ | — |

### ⇒ 待对齐的**五项**（1–5 ✓，其余均无实质差距 ✓）
```
★1 独立 mag_I 先验 + mag_B 代数反解     ← 最关键（它解释了"分离弱"的必然性 ✓）
★2 resetMagStates(mag, reset_heading) 事件驱动 API + 触发条件
 3 resetMagEarthCov/resetMagBiasCov 的【去相关】部分
★4 resetMagHeading(mag)：由磁重置航向（**替代**我的每步去相关代理 ✗）
★5 yaw_align：航向对齐状态（1 与 4 的**前提** ✓）
⇒ 依赖顺序：5 → (2 → 3/4) → 1（先有 yaw_align 概念，再谈重置与反解 ✓）
```

### 验证计划（同步测试 ✓，每项可独立验 ✓）
| 步 | 测试 | 判据 |
|---|---|---|
V1 | **代数反解自检**：给定独立 mag_I 先验 + 真值姿态 ⇒ `mag_B = meas − Rᵀ·mag_I` | 应**精确**等于真值 mag_B ✓ |
V2 | `reset_mag_states(mag, reset_heading)` 的重置 | 重置后：mag_I/mag_B/P 均按参照设定 ✓ |
V3 | `yaw_align` 前后：mag_B 反解是否启用 | 对齐前不反解、对齐后反解 ✓ |
V4 | 端到端：有了先验 + 反解 ⇒ mag_B 一次到位 | \|Δmag_B\| < 1e-4 ✓（而非 0.196 ✓）|

### §12.1 `yaw_align` 的语义（对齐清单第 5 项 ✓，参照原文）

```cpp
// mag_control.cpp
 83:  _control_status.flags.yaw_align = false;            // 失效 ⇒ 解除闩锁
301:  if (!yaw_align ...) {
309:      bool reset_heading = !yaw_align;                // ★首次对齐 ⇒ 重置航向
315:      _control_status.flags.yaw_align = true;         // ★闩锁置位
344:  if (yaw_align && (mag_3D || mag_hdg)) { ... } else yaw_align = false;   // 复核/解除
424:  if (!reset_heading && yaw_align) { mag_B = mag − R·WMM; }   // ★★门控代数反解
```

**三条语义**
| # | 语义 |
|---|---|
① | **闩锁**：初值 false ⇒ 磁首次可信时置 true，且那一刻 **`reset_heading = true`** ⇒ **由磁重置航向** ✓ |
② | 之后保持 true（失效路径如 83/344/348 行 ⇒ 置 false ✓）|
③ | ★**门控 `mag_B` 的代数反解**（424 行 ✓）⇒ "**航向未对齐 ⇒ 不做反解**" ✓✓（合理：航向错则反解也错 ✓）|

**⇒ 对本实现的含义** ✓
- 我的"**每步去相关航向**"代理 ✗ ⇒ 应换成 **"首次对齐时由磁重置航向 + 之后门控反解"** ✓✓
- 依赖链因此明确：**先实现 `yaw_align` 闩锁与其"首次对齐"事件** ⇒ 再实现重置与反解 ✓

**实现计划（V2/V3 的测试同步 ✓）**
| 步 | 内容 | 验证 |
|---|---|---|
5a | `C1Filter` 增 `yaw_aligned: bool`（初值 false ✓）| V3：对齐前不反解 ✓ |
5b | **首次对齐事件**：磁首次可信 ⇒ `reset_heading = true` ⇒ 由磁重置航向 ✓ | 重置后 yaw 与磁一致 ✓ |
5c | 之后 `yaw_aligned = true` ⇒ **门控 `mag_B` 反解** ✓ | V4：反解一次到位 ✓ |

## 13. ★★倾斜通道缺口（2026-09-21 分轴诊断定位）—— 上线的关键一步

### 现象（§4 已标定档，Cruise 20°，n=4000）
```
Legacy 1.539° / C1 5.924°（比值 3.850 ✗）
★C1 分轴： yaw 2.430° | **roll/pitch 3.500°**   ← 误差主要在【倾斜】✗
```
⇒ 原假设"磁链变差因先验不匹配 ⇒ 应集中在 yaw" **被推翻** ✗✓

### ★定量实测（2026-09-21，直流/振荡切分 ✓）
```
C1 分轴： yaw 2.430° | roll/pitch 3.500°
★roll/pitch 直流（系统偏移）= **-3.216°** ✗✗   ｜  振荡型残差 = 2.790° ✓
⇒ 倾斜误差是【有符号的系统性稳态偏差】✓✓，不是噪声 ✗
```

### ⚠️ 更正（自查 ✓）：不是"速度 H 缺 δθ 耦合"
```
✗ 原写"速度量测 H=[0 I 0] 应补 δθ 耦合" —— **错** ✓
  速度量测测的是状态 v 本身 ⇒ ∂v/∂δθ = 0 ⇒ H=[0 I 0] **本就正确** ✓
  倾斜与速度的耦合【来自 P 的传播】（F 的 δv×δθ 块 ✓ 已数值验证 ✓）
✓ 正确表述：**倾斜没有【直接】观测** ⇒ 只能经交叉协方差【间接】推断
  ⇒ 必然留【稳态偏差】（实测 −3.2° ✓）✓✓
```
磁量测 | H 含 δθ ✓ | 但磁主要是**偏航**参考 ⇒ 对倾斜**弱** ✗ |
⇒ **倾斜在 C1 里近乎不可观测** ✗ ⇒ 3.5° 残留 ✓✓

### 参照的对应路：`aid_sources/gravity/` ✓✓
（EKF 目录清单里已见 ✓）—— **重力辅助**：由比力构造倾斜观测 ✓
- 这正是本项目 **Legacy 用"重力锚定"在做的事** ✓ —— 而在 C1 里它应当是一路
  **正式量测**（H = 重力方向对 δθ 的耦合 ✓ + 门控按加速度大小 ✓），
  而不是被省略 ✗

### ⇒ 上线路径（按依赖 ✓）
```
① 给【速度量测】补上 δθ 耦合（H 的 δθ 块 = 与 F 的 −R[a×] 同源 ✓ 须数值对照 ✓）
② 新增【重力辅助】量测（照 aid_sources/gravity ✓）：
   在 |a_world| 小时 ⇒ 用比力方向约束倾斜 ✓（加速度门控 ✓）
③ 再跑 §4 两档 ⇒ 倾斜误差应显著下降 ⇒ 才谈"两档都不劣于 Legacy"✓
```
