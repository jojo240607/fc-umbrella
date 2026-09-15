#!/usr/bin/env bash
# 一键回归（各仓库核心测试，快）。任一失败会在结尾汇总并给出重跑指引。
# 机器慢时建议加 --release；SIL/HIL/全链路长测试见 docs/integration.md。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=()

# run <名称> <命令...>
run() {
    local name="$1"; shift
    echo "==== $name ===="
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "$out" | tail -30
        echo "[FAIL] $name (rc=$rc)"
        FAILED+=("$name")
        return
    fi
    echo "$out" | grep -E "test result" | tail -5
}

run "flyctrl core lib"         bash -c "cd $ROOT/flyctrl && cargo test --lib"
run "fly-simulater fly-sim-core" bash -c "cd $ROOT/fly-simulater && cargo test -p fly-sim-core --lib"
run "fly-simulater sensor_fault" bash -c "cd $ROOT/fly-simulater && cargo test --test sensor_fault"
run "mcu_simulater lib"        bash -c "cd $ROOT/mcu_simulater && cargo test --lib"

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "[verify] 全部通过 ✓（SIL/HIL/全链路长测试请按 docs/integration.md 单跑）"
else
    echo "[verify] 失败 ${#FAILED[@]} 项：${FAILED[*]}"
    echo "        重跑命令见 docs/integration.md 对应章节（integrate.sh 各步骤同源）"
    exit 1
fi
