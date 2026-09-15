#!/usr/bin/env bash
# 一键联调：构建固件 + 全部联调测试（虚拟外设 / 解锁飞行 / SIL / HIL / 故障注入）。
#
# 用法：
#   ./scripts/integrate.sh             # 跑全部（all）
#   ./scripts/integrate.sh firmware    # 仅构建固件（real-sensors + hil）
#   ./scripts/integrate.sh sensors     # 虚拟外设全链路
#   ./scripts/integrate.sh unlock      # 解锁飞行（控制律闭环）
#   ./scripts/integrate.sh sil         # SIL 回归（fly-sim-core + sensor_fault）
#   ./scripts/integrate.sh hil         # HIL 双机闭环
#   ./scripts/integrate.sh fault       # 故障注入 / 总线嗅探
#
# 机器慢（内存压力/swap）时默认 --release 跑 MCU 仿真测试（~60-100s/测试）。
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

# 测试硬编码的 ELF 路径（mcu_simulater tests/x_*.rs）：原工作区 joc-base 构建产物。
LEGACY_ELF=/home/ubuntu/work/joc-base/build_rel/stm32f407_minimal.elf
need_elf() {
    # 1) 原工作区已有构建产物（当前开发机）
    [ -f "$LEGACY_ELF" ] && return 0
    # 2) 壳工程 joc-base 子模块构建产物
    [ -f "$ROOT/joc-base/build_hil/stm32f407_minimal.elf" ] && return 0
    [ -f "$ROOT/joc-base/build_rel/stm32f407_minimal.elf" ] && return 0
    echo "[SKIP] joc-base 固件 ELF 缺失——先构建底座："
    echo "  cd $ROOT/joc-base && cmake -S . -B build_hil -DMCU_SIM=ON -DRTOS_SELFTEST=OFF && cmake --build build_hil"
    echo "  （注：mcu_simulater 测试当前硬编码 $LEGACY_ELF；新机器请在 joc-base 子模块内构建后同步路径）"
    return 1
}

do_firmware() {
    step "构建固件 real-sensors" 400 bash "$ROOT/scripts/build.sh" real-sensors
    step "构建固件 hil" 400 bash "$ROOT/scripts/build.sh" hil
}
do_sensors()  { need_elf || return 0
    step "虚拟外设全链路 x_flyctrl_real_sensors" 900 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_flyctrl_real_sensors"; }
do_unlock()   { need_elf || return 0
    step "解锁飞行 x_flyctrl_unlock_flight" 900 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_flyctrl_unlock_flight"; }
do_sil()      { need_elf || return 0
    step "SIL fly-sim-core lib" 400 \
        bash -c "cd $ROOT/fly-simulater && cargo test -p fly-sim-core --lib";
    step "SIL 磁锚定闭环 mag_hover" 300 \
        bash -c "cd $ROOT/fly-simulater && cargo test -p fly-sim-core --test mag_hover";
    step "SIL 故障注入 sensor_fault" 300 \
        bash -c "cd $ROOT/fly-simulater && cargo test --test sensor_fault"; }
do_hil()      { need_elf || return 0
    step "HIL 双机闭环 x_hil_mcusim" 900 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_hil_mcusim"; }
do_fault()    { need_elf || return 0
    step "MCU 故障注入 x_fault_injection" 600 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_fault_injection";
    step "总线嗅探 x_bus_trace" 600 \
        bash -c "cd $ROOT/mcu_simulater && cargo test $RELEASE --test x_bus_trace"; }

WHAT="${1:-all}"
case "$WHAT" in
    all)       do_firmware; do_sensors; do_unlock; do_sil; do_hil; do_fault ;;
    firmware)  do_firmware ;;
    sensors)   do_sensors ;;
    unlock)    do_unlock ;;
    sil)       do_sil ;;
    hil)       do_hil ;;
    fault)     do_fault ;;
    *) echo "未知步骤: $WHAT（可选 all/firmware/sensors/unlock/sil/hil/fault）"; exit 2 ;;
esac

echo ""
echo "==================== 汇总 ===================="
echo "PASS=$PASS FAIL=$FAIL"
if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    printf '失败步骤: %s\n' "${FAILED_STEPS[@]}"
    exit 1
fi
echo "一键联调全部通过 ✔"
