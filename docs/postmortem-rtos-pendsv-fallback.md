# 复盘：PendSV 空队列回退破坏睡眠链表 → 系统冻结（x_fault_injection::midrun_nack_isolates_slave）

> 结论先行：这是 **jOS 调度器（joc-base）的一个真实缺陷**，由 mcu_simulater 指令级
> 仿真在 `midrun_nack_isolates_slave` 中确定性复现；已修复（`bdc4f9d`），全量联调
> 14/14 通过。该竞态与本次联调改动无关（二进制字节级证明 pre-existing），且**真机无
> USB host 时同样会触发**——是本轮仿真调试最重要的收获之一。

---

## 1. 背景

- **测试**：`mcu_simulater/tests/x_fault_injection.rs::midrun_nack_isolates_slave`
  —— 真实传感器版固件（与正式构建字节级一致）跑在 Unicorn 指令级仿真上，运行中途
  注入 I2C NACK 故障，断言 FDIR 降级隔离后控制环心跳（`hb seq=… crit=false`）持续。
- **失败现象**：~1.44s 后 control/sensors 任务真停滞（内存计数冻结），随后 PendSV
  风暴 + 无主机 USB `TX_PUMP busy` 日志洪泛，hb 永不出现 → 测试挂死。
- **排查手段**（mcu_simulater 的能力，全部在测试进程内完成）：
  - 直接读符号内存（`rd_u32/rd_u8`）：g_tick、SENSOR_SEQ、任务表、睡眠链表、g_ready_bmp；
  - Unicorn 代码钩子（`add_code_hook`）钉住**唯一指令地址**做执行计数 / 事件捕获；
  - `sym_addr` 从 jOS ELF 动态解析符号，不硬编码（除诊断脚本内的临时地址）。

---

## 2. 症状（逐级观测）

| 时刻 | 证据 |
|---|---|
| tick ~1329 | control 最后一次 `dbg est`（seq=200） |
| tick ~1443（step 331） | `SENSOR_SEQ` 冻结 846；`ctl_msleep`（control 的 `msleep(4)` 调用点计数）冻结 216；`sen_msleep` 冻结 423 —— **control/sensors 同时停止完成循环迭代** |
| 同刻 | PendSV 计数从 ~10-20/step 暴涨到 ~357/step（风暴起点） |
| step 345 | 任务表：全部应用任务 SLEEPING、main RUNNING、`g_ready_bmp=0`（就绪队列空） |
| 同刻 | 睡眠链表 = `[main:1/1]`（main 状态 RUNNING 却残留在睡眠链表）；其余睡眠任务全部丢失 |
| 全程 | `g_sched_invariant_fail=0`（无调度器断言触发） |

---

## 3. 排除的假设（每条都做了针对性实验）

| 假设 | 结论 | 证据 |
|---|---|---|
| SysTick 被 PendSV 饿死 | ❌ | `g_tick` 持续推进（~4/step），SysTick ENABLE=1；同优先级平局仲裁保留低异常号（PendSV 14 胜 SysTick 15）是真实 ARM 行为，但 tick 一直在跑 |
| 日志环被 Warn 洪泛、control 的 Info 被丢弃 | ❌ | ① `ring_fill` 恒 0（log_task 及时 drain）；② **决定性实验**：把 hb 临时改成 `warn!`（日志环永不丢弃 Warn）→ hb 仍不出现 → 不是日志问题 |
| I2C 驱动无限自旋 | ❌ | joc-base I2C C 驱动所有等待均超时保护 |
| 任务互锁死锁（mutex/信号量） | ❌ | 任务表无互锁：control RUNNING/sensors READY/uplink READY/… 全部在正常流转 |
| 从任务栈读保存 PC 定位卡点 | ❌（放弃） | 机器异常模型与真实 ARM 帧布局不同，读到垃圾值 |

---

## 4. 根因分析

### 4.1 前置：idle 任务的就绪队列成员资格失步

追踪 `rh31`（就绪链表 31 号头）与 `g_ready_bmp` 位 31（idle）：

```
step 330 (tick 1440): idle_st=0  rh31=0x100063BC  rbmp=0x90010420   ← idle 在队列（bit31 置位）
t1441              : cur=idle:st0  bmp=0x00010400  rh31=0x00000000  ← idle 失步：state=READY 但不在队列
t1442              : first_risk: cur=main:st3  bmp=0x00000000  rh31=0
```

**idle 的 TCB 状态是 READY（st0）、sched_next/sched_prev 全 0（干净摘除态），但不在
就绪队列、bmp 无 bit31**。这违反「idle 恒在就绪队列」的设计前提（`rtos_pendsv_switch`
注释即依赖此假设）。失步的确切触发点未能在本次排查中 100% 定位（syscall 状态写入与
链表挂接在同一 BASEPRI 临界区，PendSV 理论上插不进中间态；不排除异常/钩子时序边界的
极端竞态），但**失步本身已被实证**，且修复不依赖其精确机制（见 §5 的失步补回）。

### 4.2 触发：睡眠时就绪队列为空

tick 1442，main 调用 `msleep(1)`（console 循环）：
- main 入睡眠链表（delay=1，**恰好是睡眠链表头**）；
- 此刻其他任务全在睡眠、idle 又失步 → `g_ready_bmp=0`。

### 4.3 破坏：`if (!nxt) nxt = cur` 回退 + 无条件 `ready_remove(nxt)`

```c
task_t *nxt = ready_pick();          /* NULL：就绪队列空 */
if (!nxt) nxt = cur;                 /* 回退到睡眠中的 main */
if (nxt) {
    ready_remove(nxt);               /* ← 对睡眠中的 main 执行就绪摘除！ */
    ...
}
```

`ready_remove(t)` 直接操作 `t->sched_next/sched_prev`——对睡眠任务来说那是**睡眠链表
指针**。main 是睡眠链表头（`sched_prev==0`），于是：

```
g_ready_head[16] = main->sched_next;   /* 把一个睡眠任务写进就绪链表头！ */
g_ready_bmp     |= (1u << 16);         /* bit16 假置位 */
main 被摘出睡眠链表，标记 RUNNING，msleep 立即返回
```

### 4.4 级联：链表交叉损坏 → 睡眠任务全部丢失

- 下一次 PendSV 从 `g_ready_head[16]` 选到「睡眠链表节点」（一个正在睡眠的任务）→
  `ready_remove` 按它的睡眠指针把它从睡眠链表摘除 → 该任务被"恢复运行"（msleep 提前
  返回）→ 重睡时 `sleep_add` 挂回尾部。
- 观测到睡眠链表节点数反复波动（`7→2→7→3→1`…）就是这一 churn；最终损坏为
  `[main:1/1]`（main 以 RUNNING 状态残留在睡眠链表），其余睡眠任务**全部丢失**。
- tick ISR 的唤醒遍历只从 `g_sleep_head` 走，丢失的任务永远等不到 `delay_ticks` 归零
  → control（seq~219）、sensors（SENSOR_SEQ=846）真停滞。
- main 则进入「msleep(1) → 回退恢复 → console_run → 再 msleep」死循环，每个迭代一次
  PendSV（风暴 ~356/step），期间无主机 USB `TX_PUMP busy` 洪泛（日志洪水只是**下游
  症状**，不是原因）。

### 4.5 因果链总览

```
无主机 USB NAK 风暴（main 长时间占 CPU，PendSV 高密度）
        │
        ▼
idle 就绪队列成员资格失步（state=READY 但不在队列）
        │
        ▼
某次 main 睡眠时 g_ready_bmp==0（idle 不在 + 其余任务全睡）
        │
        ▼
rtos_pendsv_switch 回退 nxt=cur=main（睡眠中）→ ready_remove(main)
        │  按睡眠链表指针操作
        ▼
睡眠链表与就绪链表交叉损坏 → 睡眠任务丢失 → tick 唤醒失效
        │
        ▼
control/sensors 冻结 + main 死循环（PendSV 风暴 + USB 洪泛）→ 测试挂死
```

---

## 5. 修复（joc-base bdc4f9d，`src/rtos/core/sched.c`）

双保险：

1. **失步补回**：`ready_pick()` 返回 NULL 时，先扫描任务池，把 `state==TASK_READY`
   且 `sched_next/sched_prev` 全 0（不在任何链表）的任务——即失步的 idle——补回
   就绪队列，再重新 pick；
2. **安全回退**：仍空才回退 cur，且**绝不 `ready_remove` 睡眠/阻塞中的 cur**：
   - cur `TASK_READY`（yield/时间片竞态残留，确在队列）→ `ready_remove`；
   - cur `TASK_SLEEPING` → `sleep_remove`（正规摘除再续跑）；
   - cur `TASK_BLOCKED && wait_obj` → `rtos_waitq_remove`（同上）。

安全性论证：syscall 的状态写入与链表挂接在同一 BASEPRI 临界区内完成（BASEPRI 屏蔽
优先级 ≥ 阈值的中断，PendSV/SysTick 均在屏蔽带），因此 PendSV 不可能插到「状态已写、
链表未挂」的中间态——`state==SLEEPING` 必已挂睡眠链表，可安全摘除。

---

## 6. 验证

| 测试 | 修复前 | 修复后 |
|---|---|---|
| `midrun_nack_isolates_slave` | FAILED（挂死） | **PASSED（13.1s）** |
| `nack_from_boot_fdir_critical` | PASSED | PASSED（无回归） |
| `x_shmem_mcusim`（SRAM3 共享内存闭环） | PASSED | PASSED |
| `integrate.sh all` 全量 | 13/14（1 FAIL） | **14/14 PASS** |

---

## 7. 真机影响与启示

- **真机同样会触发**：触发条件是「无 USB host 时 main 长时间运行（NAK 轮询）+ 全任务
  睡眠窗口 + idle 失步」，与模拟器无关；模拟器只是让这个 ~1.4s 才出现的竞态**确定性
  可复现、可逐指令取证**。修复对真机同样生效。
- **模拟器的价值再次验证**：`add_code_hook` 钉唯一指令（`msleep` 调用点）做执行计数，
  直接读符号内存（SENSOR_SEQ、任务表、睡眠链表、g_ready_bmp），把「日志不见了」这类
  模糊症状一步步收敛到「调度器链表被破坏」这一精确根因。
- **排查方法论沉淀**：遇到「任务不干活」先区分「真停滞 vs 日志被淹」——用**内存计数**
  （SENSOR_SEQ）和**代码钩子执行计数**（ctl_msleep/sen_msleep），不要只信日志。

---

## 附录 A：关键符号 / 地址（修复前 jOS ELF）

| 符号 | 地址 | 说明 |
|---|---|---|
| `g_tick` | 0x100063B4 | 系统节拍 |
| `g_running` | 0x100063B8 | 当前任务 TCB |
| `g_task_pool` | 0x100063BC | 任务池（TCB 步长 0x60） |
| `g_sleep_head` | 0x100062A0 | 睡眠链表头 |
| `g_ready_head` | 0x10006328 | 就绪链表头数组 |
| `g_ready_bmp` | 0x100062A4 | 就绪位图 |
| `g_sched_invariant_fail` | 0x10006298 | 调度器断言计数（修复前全程 0） |
| `rtos_pendsv_switch` | 0x08012234 | PendSV 切换入口（钩子位置） |

固件侧（real-sensors app.elf）：`SENSOR_SEQ`=0x2000B5DC、`SENSOR_FRAME`=0x20009018、
`EST_STATE`=0x20009084；control 的 `msleep(4)` 调用点 0x080645FE、sensors 的
`msleep(2)` 调用点 0x08060CD8（代码钩子锚点）。

## 附录 B：TCB 布局（cortex-m，sizeof=0x60）

`sp@0x00, name@0x04, prio@0x08, base_prio@0x09, priv@0x0A, state(u8)@0x0B,
stack_base@0x0C, stack_size@0x10, entry@0x14, arg@0x18, sched_next@0x1C,
sched_prev@0x20, wait_next@0x24, wait_prev@0x28, delay_ticks@0x2C, runtime@0x30,
wait_obj@0x34, wait_mask@0x38, wait_mode@0x3C, wait_armed@0x3D, timed_out@0x3E,
rt_class@0x3F, npls_hold@0x40, deadline_ticks@0x44, release_tick@0x48,
wcet_ticks@0x4C, budget_used@0x50, deadline_miss@0x54, wcet_miss@0x58, wake_cycle@0x5C`

`task_state_t`：READY=0 / RUNNING=1 / BLOCKED=2 / SLEEPING=3 / DEAD=4 / SUSPENDED=5
（u8，`-fshort-enums`）。
