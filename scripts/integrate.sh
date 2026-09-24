#!/usr/bin/env bash
# 一键联调：构建固件 + 全部联调测试（虚拟外设 / 解锁飞行 / SIL / HIL / 共享内存 / 故障注入）。
#
# 用法：
#   ./scripts/integrate.sh             # 跑全部（all：firmware+sensors+unlock+app+sil+hil+shmem+fault）
#   ./scripts/integrate.sh firmware    # 构建底座 ELF + 固件（joc-base / 正式飞控 / real-sensors / hil）
#   ./scripts/integrate.sh sensors     # 虚拟外设全链路
#   ./scripts/integrate.sh unlock      # 解锁飞行（控制律闭环）
#   ./scripts/integrate.sh app         # 双分区整机验收（系统 + 正式飞控 app）
#   ./scripts/integrate.sh sil         # SIL 回归（fly-sim-core + sensor_fault）
#   ./scripts/integrate.sh hil         # HIL 双机闭环（USB CDC）
#   ./scripts/integrate.sh shmem       # 共享内存直连闭环（SRAM3，hil 固件）
#   ./scripts/integrate.sh fault       # 故障注入 / 总线嗅探
#   ./scripts/integrate.sh hover       # （可选，慢）虚拟外设直通悬停闭环（60s 仿真）
#
# 产物路径约定（与 mcu_simulater::artifact 同源）：
#   - joc-base minimal ELF 构建到 $ROOT/joc-base/build_hil/（壳工程规范布局），
#     并导出 JOC_BASE_ELF 供测试使用；历史开发机路径仅作兜底。
#   - flyctrl 固件输出 /tmp/flyctrl_real.bin（real-sensors）与
#     /tmp/flyctrl_hil.bin（hil）；HIL 测试经 JOC_APP_FLYCTRL 指向 hil 产物。
#
# 机器慢（内存压力/swap）时默认 --release 跑 MCU 仿真测试（~60-100s/测试）。
#
# 用法：./scripts/integrate.sh [all|firmware|sensors|unlock|app|sil|hil|shmem|fault|env|hover]
#   all  ≈ 35-40 分钟（含 env 家族）；env ≈ 24 分钟（环境家族，带基线）。
# 带基线的步骤（step_bl）语义仿 h_verify.sh：failed>基线→FAIL；passed≠基线→WARN；
# 否则 PASS（在案失败标注）。基线变更须同步 docs/h-field.md + migration-plan 并附原因日期。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="--release"

PASS=0; FAIL=0; FAILED_STEPS=()

# step <名称> <超时秒> <命令...>
step() {
    local name="$1" secs="$2"; shift 2
    echo ""
    echo "==================== [STEP] $name ===================="
    if timeout "$secs" "$@" > /tmp/fc_intg_$$.log 2>&1; then
        echo "[PASS] $name"
        PASS=$((PASS+1))
    else
        echo "[FAIL] $name (exit=$?，日志尾部见下)"
        tail -8 /tmp/fc_intg_$$.log
        FAIL=$((FAIL+1)); FAILED_STEPS+=("$name")
    fi
    rm -f /tmp/fc_intg_$$.log
}

# step_bl <名称> <超时秒> <基线passed> <基线failed> <命令...>
# 带基线的测试步骤（仿 h_verify.sh run_family 纪律，2026-09-24 §5.130 引入）：
#   failed >  基线F                     → FAIL（新退化，必须处理）
#   failed == 基线F 且 passed == 基线P  → PASS（基线F>0 时标注在案失败）
#   failed == 基线F 但 passed ≠ 基线P   → WARN（测试增删 ⇒ 同步基线+docs）
#   无 test result（编译错/超时/崩溃）  → FAIL
step_bl() {
    local name="$1" secs="$2" bp="$3" bf="$4"; shift 4
    echo ""
    echo "==================== [STEP] $name（基线 ${bp}P/${bf}F）===================="
    local log rc p f
    log="$(mktemp /tmp/fc_intg_XXXXXX.log)"
    timeout "$secs" "$@" >"$log" 2>&1
    rc=$?
    read -r p f <<< "$(sed -nE 's/^test result: \w+\. +([0-9]+) passed; +([0-9]+) failed;.*/\1 \2/p' "$log" \
        | awk '{p+=$1; f+=$2} END {print p+0, f+0}')"
    if [ "$p" -eq 0 ] && [ "$f" -eq 0 ]; then
        echo "[FAIL] $name：无测试结果（exit=$rc，编译错误/超时？日志尾部：）"
        tail -12 "$log"
        FAIL=$((FAIL+1)); FAILED_STEPS+=("$name")
    elif [ "$f" -gt "$bf" ]; then
        echo "[FAIL] $name: ${p}P/${f}F > 基线 ${bp}P/${bf}F ⇒ 新退化（exit=$rc）"
        grep -E "^test .* FAILED" "$log" | head -8
        FAIL=$((FAIL+1)); FAILED_STEPS+=("$name")
    elif [ "$p" -ne "$bp" ]; then
        echo "[WARN] $name: ${p}P/${f}F（failed=基线但 passed≠基线 ${bp} ⇒ 测试增删了？更新基线+docs）"
        PASS=$((PASS+1))
    else
        local note=""
        [ "$bf" -gt 0 ] && note="（含 $bf 项在案失败，见 docs 基线表）"
        echo "[PASS] $name: ${p}P/${f}F ${note}✔"
        PASS=$((PASS+1))
    fi
    rm -f "$log"
}

# joc-base minimal ELF 的查找与导出（mcu_simulater::artifact 解析顺序同源）：
#   1) 壳工程规范布局 build_hil（firmware 步骤构建到锁定源码产物 jOS.elf）；
#   2) 历史开发机路径兜底（build_rel 优先，避开旧的 build_hil 固件）。
CANON_ELF="$ROOT/joc-base/build_hil/jOS.elf"
LEGACY_ELF=/home/ubuntu/work/joc-base/build_rel/stm32f407_minimal.elf
need_elf() {
    for c in "$CANON_ELF" "$ROOT/joc-base/build_hil/stm32f407_minimal.elf" "$LEGACY_ELF"; do
        if [ -f "$c" ]; then
            export JOC_BASE_ELF="$c"
            return 0
        fi
    done
    echo "[SKIP] joc-base 固件 ELF 缺失——先执行：./scripts/integrate.sh firmware"
    echo "  （即 cd $ROOT/joc-base && cmake -S . -B build_hil -DMCU_SIM=ON -DRTOS_SELFTEST=OFF && cmake --build build_hil，产物为 build_hil/jOS.elf）"
    return 1
}

do_firmware() {
    step "构建 joc-base ELF（build_hil 规范布局 → jOS.elf）" 600 \
        bash -c "cd $ROOT/joc-base && cmake -S . -B build_hil -DMCU_SIM=ON -DRTOS_SELFTEST=OFF && cmake --build build_hil"
    step "构建固件 正式飞控 app.bin（默认 feature → $ROOT/flyctrl/app.bin）" 400 \
        bash -c "cd $ROOT/flyctrl && python3 build_app.py --out $ROOT/flyctrl/app.bin"
    step "构建固件 real-sensors" 400 bash "$ROOT/scripts/build.sh" real-sensors
    step "构建固件 hil" 400 bash "$ROOT/scripts/build.sh" hil
}
do_sensors()  { need_elf || return 0
    step "虚拟外设全链路 x_flyctrl_real_sensors" 900 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_flyctrl_real_sensors"; }
do_unlock()   { need_elf || return 0
    step "解锁飞行 x_flyctrl_unlock_flight" 900 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_flyctrl_unlock_flight"; }
do_app()      { need_elf || return 0
    step "双分区整机 x_flyctrl_app（正式飞控 app.bin）" 600 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_flyctrl_app"; }
do_sil()      {
    step "SIL fly-sim-core lib" 400 \
        bash -c "cd $ROOT/fly-simulater && cargo test -p fly-sim-core --lib";
    step "SIL 磁锚定闭环 mag_hover" 300 \
        bash -c "cd $ROOT/fly-simulater && cargo test -p fly-sim-core --test mag_hover";
    step "SIL 故障注入 sensor_fault" 300 \
        bash -c "cd $ROOT/fly-simulater && cargo test --test sensor_fault"; }
do_hil()      { need_elf || return 0
    step "HIL 双机闭环 x_hil_mcusim" 900 \
        bash -c "export JOC_APP_FLYCTRL=/tmp/flyctrl_hil.bin; cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_hil_mcusim"; }
do_shmem()    { need_elf || return 0
    step "共享内存直连闭环 x_shmem_mcusim（SRAM3，hil 固件）" 900 \
        bash -c "export JOC_APP_FLYCTRL=/tmp/flyctrl_hil.bin; cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_shmem_mcusim"; }
do_fault()    { need_elf || return 0
    step "MCU 故障注入 x_fault_injection" 600 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_fault_injection";
    step_bl "总线嗅探 x_bus_trace（i2c×2 在案先存 §5.125/5.126）" 600 3 2 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_bus_trace"; }

# 环境家族（EnvHarness：real-sensors 固件 + jOS + flysim 虚拟外设）。
# 基线（2026-09-24 实测，【真固件】口径 = real bin + 同 feature ELF，出处 §5.130；
# §5.128 批次 env 家族数字系 HIL 产物污染 bin/ELF 错配，不可作基线）：
#   x_env_smoke 2/0 · x_env_rc 2/0 · x_sensor_rate 1/0
#   x_flyctrl_modes 0/1（在案：LOITER uplink 未处理，§5.12 时代即 ✗）
#   x_env_faults 7/1（在案先存：baro_step_bounded_by_gps）
#   x_env_noise_perturb 7/0 · x_env_motion 3/1（在案：climb_height_tracks）
#   x_env_longrun 2/0
# 增/删测试后：更新此基线 + docs/h-field.md 基线表，并附一句原因与日期。
do_env()      { need_elf || return 0
    step_bl "环境冒烟 x_env_smoke" 300 2 0 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_env_smoke";
    step_bl "遥控链路 x_env_rc" 600 2 0 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_env_rc";
    step_bl "传感器采样率 x_sensor_rate" 300 1 0 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_sensor_rate";
    step_bl "飞行模式 MAVLink x_flyctrl_modes" 300 0 1 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_flyctrl_modes";
    step_bl "环境故障注入 x_env_faults" 300 7 1 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_env_faults";
    step_bl "噪声扰动 x_env_noise_perturb" 900 7 0 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_env_noise_perturb";
    step_bl "机动跟踪 x_env_motion" 300 3 1 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_env_motion";
    step_bl "长跑稳定 x_env_longrun" 600 2 0 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_env_longrun"; }
do_hover()    { need_elf || return 0
    step "虚拟外设直通闭环 x_vperiph_mcusim" 900 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_vperiph_mcusim";
    step "持续悬停演示 x_hover_demo（60s 仿真，慢）" 1500 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_hover_demo"; }

WHAT="${1:-all}"
case "$WHAT" in
    all)       do_firmware; do_sensors; do_unlock; do_app; do_sil; do_hil; do_shmem; do_fault; do_env ;;
    firmware)  do_firmware ;;
    sensors)   do_sensors ;;
    unlock)    do_unlock ;;
    app)       do_app ;;
    sil)       do_sil ;;
    hil)       do_hil ;;
    shmem)     do_shmem ;;
    fault)     do_fault ;;
    env)       do_env ;;
    hover)     do_hover ;;
    *) echo "未知步骤: $WHAT（可选 all/firmware/sensors/unlock/app/sil/hil/shmem/fault/env/hover）"; exit 2 ;;
esac

echo ""
echo "==================== 汇总 ===================="
echo "PASS=$PASS FAIL=$FAIL"
if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    printf '失败步骤: %s\n' "${FAILED_STEPS[@]}"
    exit 1
fi
echo "一键联调全部通过 ✔"
