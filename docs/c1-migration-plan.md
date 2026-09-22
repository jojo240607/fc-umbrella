# C1 替代 Legacy 迁移计划（方案甲 ✓，2026-09-21 启动）

> 目标：让 **C1（误差状态 EKF，`estimator/eskf.rs`）成为产品路径的默认估计器** ✓
> 现状（已实测确认 ✓）：产品路径与 A 系列工装走的都是 **Legacy `EkfEstimator`** ✗；
> `eskf.rs` 在【任何非测试代码】里零引用 ✗；`EstMode::Ekf` 显式 panic ✗（拒绝静默回退 ✓）。

## 0. 接口面（已锁定 ✓）

`core/src/estimator/trait_def.rs` ✓ —— `pub trait Estimator`，共 **9 个方法** ✓：

| # | 方法 | 必需 | Legacy 现状 | C1 适配点 |
|---|---|---|---|---|
1 | `step(...)` | ✓ 必需 | 陀螺积分 + 门控锚定 + 平移补偿 | `predict_covariance` + IMU/气压/GPS 融合 ✓ |
2 | `update_vio(&mut self, Option<VioSample>)` | 默认 no-op | 融合 ✓ | 映射到 C1 的等价观测 ✓（**无等价则显式拒绝** ✗ 不得静默 no-op ✗）|
3 | `update_rtk(&mut self, Option<RtkSample>)` | 默认 no-op | 融合 ✓ | 同上 ✓ |
4 | `reset(&mut self)` | ✓ 必需 | 重置 | C1 重置（含 `align_static` ✓）|
5 | `set_initial_attitude(&mut self, Quaternion)` | 默认 no-op | — | 设 `st.q` ✓（含协方差重置 ✓）|
6 | `set_initial_position(&mut self, [f32;3])` | 默认 no-op | — | 设 `st.p` ✓ |
7 | `update_alt(&mut self, f32)` | 默认 no-op | 气压融合 ✓ | C1 气压标量融合 ✓ |
8 | `update_mag(&mut self, Option<[f32;3]>)` | 默认 no-op | 磁锚定 ✓ | C1 `update_mag` ✓（**含首次 `reset_mag_states` 触发 ✓**）|
9 | `state(&self) -> VehicleState` | ✓ 必需 | 组装 | 由 `st` 组装 ✓ |
10 | `accel_bias(&self) -> [f32;3]` | 默认 | `ba` ✓ | C1 `st.ba` ✓ |

## 1. 分步（每步独立可验、可回退 ✓）

### 步 1 ✓ 适配器骨架（`impl Estimator for C1Estimator`）
- 新建 `core/src/estimator/c1_adapter.rs` ✓（**不改 `eskf.rs` 的算法** ✗）
- 结构体 `C1Estimator { f: C1Filter, cfg… }` ✓
- 先实现**必需三件**：`step` / `reset` / `state` ✓
- `update_*` 先**显式拒绝**（`debug_assert!` + 计数 ✓）⇒ 逐个补齐 ✓，**绝不静默 no-op** ✗

### 步 2 ✓ 观测通路逐条接通（每条都要有"证明它在运行"的计数 ✓）
- 气压：`update_alt` ⇒ C1 标量融合 ✓ + 计数 ✓
- 磁：`update_mag` ⇒ C1 `update_mag` ✓ + 首次 `reset_mag_states` 触发 ✓ + 计数（含**拒绝**计数 ✓）
- GPS 位置/速度：`step` 内的 `GpsSample` ⇒ C1 `update_gps_pos` / `update_vel_r` ✓
- VIO / RTK：有等价观测则接 ✓；无则**panic/显式拒绝** ✗（登记为缺口 ✓）

### 步 3 ✓ 产品路径切换（可配置 + 默认 C1 ✓）
- `hil.rs` 的构造点（539/616/694/701/763/769 ✓）改为**按配置选择** ✓，默认 C1 ✓
- 保留 Legacy 回退（用于对照/故障定位 ✓）
- **回归守卫** ✓：切换后先跑全量，任何一档劣于 Legacy 则**回退** ✓（判据同 §4 ✓）

### 步 4 ✓ 双跑工装（A 系列在 C1 上也跑一遍 ✓）
- `select_est_mode`（att_est.rs:2882 ✓）接上真实实现，去掉 panic ✓
- `run_ab_table` 双跑：同一场景 **Legacy vs C1** ✓ ⇒ 输出对照表 ✓
- **A11 范式**（注入验证 → 机制计数 → 相对基线判据 ✓）在 C1 上重做 ✓
- C1 版 A11 的机制 = **重力辅助的加速度门** ✓（`update_gravity` 的 `dev > 0.25*gn` 分支 ✓）
  ⇒ 加计数 ✓（同 `G_ATT_GATE_CLOSED` 的做法 ✓）

### 步 5 ✓ 收口判据
- A1–A13 双跑：**两档（未标定/已标定）C1 均不劣于 Legacy** ✓
- NEES / 协方差一致性（C1 有 P ✓ ⇒ 可直接做 ✓）
- 全部场景的**机制计数**都非零 ✓（"每个门都要有证明它在动"✓）

## 2. 风险与纪律

| 风险 | 处置 |
|---|---|
静默 no-op（VIO/RTK 无等价观测 ✗）| **显式拒绝** ✓ 并登记缺口 ✓（本会话头号纪律 ✓）|
C1 在 A 系列场景下劣于 Legacy ✗ | **不放过** ✗ ⇒ 定位根因（照 §13 的做法 ✓）⇒ 若为物理必然则改判据 ✓ |
产品路径切换的回归 ✗ | 先双跑对照 ✓，切换后全量回归 ✓，不劣才切 ✓ |
步 1–2 的中间态不可用 ✗ | 每步都保持可编译 + 有计数自检 ✓ |
