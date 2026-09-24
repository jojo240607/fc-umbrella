# H 场 / M 场验证流程（新会话快速上手）

> 目的：任何新会话读完这一页 + 跑一次脚本，即可知道 **H 场是什么、怎么验证、当前什么状态**。

## 30 秒上手

```bash
git log --oneline -5 && git submodule status    # 当前版本快照
./scripts/h_verify.sh --fast                    # 快速档（秒级：flyctrl-core + sensor_fault）
./scripts/h_verify.sh                           # 完整档（~8min，含 fly-sim-core 慢测）
```

- 全绿 ⇒ H 场健康；`WARN 计数≠基线` ⇒ 有人加/删了测试（非失败，需同步基线）
- 工作日志（最新进展在末尾，倒序读）：`docs/c1-migration-plan.md` 末尾 §5.121–5.128

## 定义与纪律

|  | H 场（**解问题**） | M 场（**回归验收**） |
|---|---|---|
| 是什么 | 纯 PC 模拟：算法 crate 原生跑 PC，无 MCU 参与 | 真实固件 `.bin/.elf` 跑进虚拟 MCU（Unicorn Cortex-M4F 指令级） |
| 载体 | flyctrl-core + fly-sim-core 测试族 | mcu_simulater `tests/x_*.rs`（integrate.sh 各步骤） |
| 职责 | 姿态估计/控制等算法调试，快迭代、可打桩 | 验证真实驱动/总线/RTOS 全链路 |

**纪律（§5.38，用户定规，不要轻易更改）**：所有源码改动先过 H 场 → 全绿 → 才进 M 场回归。
依据：H 场曾当场抓到 `PosSample` 结构体契约破坏（两个测试文件编译失败）；若直接进 M 场，
会以"固件构建失败/测旧货"形式出现，定位成本高数倍。

## H 场构成与基线（2026-09-24 实测，出处 c1-migration-plan §5.127 终验）

| 族 | 命令（在壳工程根） | 基线 | 耗时 | 内容 |
|---|---|---|---|---|
| flyctrl-core | `cd flyctrl && cargo test -p flyctrl-core` | **117/0**（4 ignored） | ~1s | lib 93（EKF/ESKF/控制器/invariants/mission/swarm/hil 对拍…）+ 集成 24（comm_roundtrip / eskf_estimator_paths / no_alloc / props_*） |
| fly-sim-core | `cd fly-simulater && cargo test -p fly-sim-core` | **176/0**（2 ignored） | ~7min | plant/sensor/SIL 全家：att_est 64（271s）、pos_ctrl 17（103s）、powertrain 21、guidance_track 17、att_ctrl 13、mag_hover、sil 6… |
| sensor_fault（外围） | `cd fly-simulater && cargo test --test sensor_fault` | **6/0** | ~1s | 传感器故障注入回归（verify.sh SIL 项同源） |

**口径警告（历史踩坑）**：
- `--lib` 只有 93/19 个 —— **117/176 = lib + 集成测试之和**，别用 `--lib` 口径冒充 H 场。
- `--test sil` 已含在 fly-sim-core 的 176 内，单独跑是重复。
- ignored（4/2）为长期忽略用例，仅作信息展示，不参与判定。

## 判定规则（脚本自动执行）

- `failed=0` 且 `passed=基线` ⇒ **PASS**
- `failed=0` 但 `passed≠基线` ⇒ **WARN**（新增/删除了测试 → 更新本表与脚本基线并附原因）
- `failed>0` 或编译失败 ⇒ **FAIL** → 先修 H 场，禁止进 M 场

## M 场（H 场全绿后才允许）

```bash
./scripts/integrate.sh firmware   # joc-base ELF + 3 个固件（首次/子模块变更后必须）
./scripts/integrate.sh            # 全部步骤；单步：firmware|sensors|unlock|app|sil|hil|shmem|fault|env
```

详见 `docs/integration.md`（每项 60–100s 级 MCU 仿真测试）。
★全部测试用例的分类总账（M 场五类：飞控 real/默认/HIL/平台层/驱动）见 `docs/test-inventory.md`。

### M 场基线（2026-09-24 实测，出处 §5.130；带基线步骤用 `step_bl` 判定）

判定语义：`failed > 基线F` ⇒ FAIL（新退化）；`failed == 基线F 但 passed ≠ 基线P` ⇒ WARN（测试增删）；否则 PASS（在案失败标注）。

| 步骤 | 基线 P/F | 在案失败（先存，非新退化） | 出处 |
|---|---|---|
| x_bus_trace | 3/2 | i2c sniff ×2 | §5.125/5.126 |
| x_env_smoke | 2/0 | — | §5.130 |
| x_env_rc | 2/0 | — | §5.130 |
| x_sensor_rate | 1/0 | — | §5.130 |
| x_flyctrl_modes | 0/1 | LOITER uplink 未处理（§5.12 时代即 ✗） | §5.130 |
| x_env_faults | 7/1 | baro_step_bounded_by_gps（早于 B 案即 ✗） | §5.130 |
| x_env_noise_perturb | 7/0 | — | §5.130 |
| x_env_motion | 3/1 | climb_height_tracks | §5.130 |
| x_env_longrun | 2/0 | — | §5.130 |

★基线为【真固件】口径（real bin + 同 feature ELF）。§5.128 批次的 env 家族数字系
HIL 产物污染（bin/ELF 跨 feature 错配），不可作基线（详见 migration-plan §5.130）。
其它 M 场步骤（sensors/unlock/app/sil/hil/shmem/fault_injection）基线 = 全绿 0F。

## 基线维护

新增/删除测试 → 同步更新 `scripts/h_verify.sh` 顶部基线变量 + 本文档基线表，
各附一句原因与日期。基线漂移没有记录 ⇒ 下个会话无法判断是"正常演进"还是"静默退化"。

## 当前状态快照

- **2026-09-24（傍晚，§5.130）**：M 场盲区补齐——env 家族 8 目标 + modes/sensor_rate 首次纳入例行回归（`integrate.sh env` / `all`，step_bl 带基线）。揪出并修复**同一错配根因**：`build_app.py` 把所有 feature 的 ELF 覆写到 `app.elf`（last-build-wins），而 elfsym 从 `app.elf` 解析符号；.app_globals 段内偏移随 feature 漂移（实测 hil vs real 的 SENSOR_SEQ 差 +0xE1C）⇒ 加载 real.bin 的测试探针全部错位。修复后 ELF 按 feature 命名（app.elf/app_real.elf/app_hil.elf）+ bin/ELF 成对同步 + `elfsym::use_app_elf` 显式指定。真固件家族基线：smoke 2/0、rc 2/0、rate 1/0、noise 7/0、longrun 2/0、faults 7/1、motion 3/1、modes 0/1（在案 3 项）。★§5.128 env 家族数字（faults 5/3、noise 3/4、motion 1/3）系 HIL 固件行为，不可作真固件基线；其 A/B 单变量结论（B 案零退化）不受影响（两臂同 bin）。
- **2026-09-24（下午，§5.129）**：M 场例行回归 **PASS=13/FAIL=1**（唯一失败 = x_bus_trace i2c 两项，在案先存）；揪出并修复两处：
  ① 终验批覆盖盲区（54/80 目标，§5.129 详查）② `build_app.py` sync 污染 real.bin + unlock 测试 `m=[`→`m_permille=[` 期望过期；终验盲区目标（real_sensors/unlock/fault_injection/app/hil/shmem）首次拿到 B案后全绿记录 ✓。
- **2026-09-24**：H 场实测全绿 **117/0 + 176/0**（外围 6/0）；HEAD `86dd918`
  （c1 迁移终验 §5.128 结案：B 案零退化，H 场 117/0+176/0，M 场 341/12 逐项归因为先存/环境）。
  ★注意（§5.129 更正）：该 M 场结论仅覆盖前 54 个目标（字母序至 x_env_smoke），后 26 项目标盲区。
- 主线上一步：姿态估计与控制调试（H 场调通）+ M 场构建链修复；下一步候选：盲区目标纳入例行整批跑（校验 result 行数 = 目标数）。
