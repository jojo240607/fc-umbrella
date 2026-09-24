#!/usr/bin/env bash
# H 场一键验证（纯 PC 模拟回归）——流程定义与基线维护规则见 docs/h-field.md
#
# 纪律（c1-migration-plan §5.38，用户定规，不要轻易更改）：
#   所有源码改动先过 H 场 → 全绿 → 才允许进 M 场回归（./scripts/integrate.sh）。
#
# 用法：
#   ./scripts/h_verify.sh           # 完整 H 场（flyctrl-core + sensor_fault + fly-sim-core，约 8 分钟）
#   ./scripts/h_verify.sh --fast    # 快速档（flyctrl-core + sensor_fault，秒级；跳过 fly-sim-core 慢测）
#
# 基线（2026-09-24 实测，出处 c1-migration-plan §5.127 终验）：
#   flyctrl-core  117/0（4 ignored，~1s；lib 93 + 集成 24）
#   fly-sim-core  176/0（2 ignored，~7min；att_est 271s + pos_ctrl 103s 是大头）
#   sensor_fault    6/0（~1s，verify.sh SIL 项同源）
# 增/删测试后：更新此基线 + docs/h-field.md 基线表，并附一句原因与日期。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BASE_FLYCTRL_CORE=117
BASE_FLY_SIM_CORE=176
BASE_SENSOR_FAULT=6

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

# 从 cargo 输出汇总 passed/failed/ignored（跨多个测试目标求和）→ "P F I"
sum_results() {
    sed -nE 's/^test result: \w+\. +([0-9]+) passed; +([0-9]+) failed; +([0-9]+) ignored.*/\1 \2 \3/p' \
        | awk '{p+=$1; f+=$2; i+=$3} END {print p+0, f+0, i+0}'
}

# run_family <名称> <基线passed> <耗时提示> <目录> <cargo参数...>
run_family() {
    local name="$1" base="$2" eta="$3" dir="$4"; shift 4
    echo ""
    echo "---- H场: $name（基线 ${base}/0，$eta）----"
    local log rc p f i
    log="$(mktemp /tmp/h_field_XXXXXX.log)"
    ( cd "$dir" && cargo test "$@" ) >"$log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "[FAIL] $name：cargo 退出码 $rc（编译错误或测试失败）"
        grep -E "^error|FAILED|panicked" "$log" | head -15
        rm -f "$log"
        return 1
    fi
    read -r p f i <<< "$(sum_results <"$log")"
    rm -f "$log"
    local verdict="PASS" note=""
    if [ "$f" -ne 0 ]; then
        verdict="FAIL"
    elif [ "$p" -ne "$base" ]; then
        verdict="WARN"; note="（计数≠基线 ${base}：多半新增/删除了测试 ⇒ 同步更新基线）"
    fi
    echo "[$verdict] $name: ${p} passed / ${f} failed / ${i} ignored ${note}"
    [ "$f" -eq 0 ]
}

FAIL=0
run_family "flyctrl-core" "$BASE_FLYCTRL_CORE" "~1s" "$ROOT/flyctrl" -p flyctrl-core || FAIL=1
run_family "sensor_fault" "$BASE_SENSOR_FAULT" "~1s" "$ROOT/fly-simulater" --test sensor_fault || FAIL=1
if [ $FAST -eq 0 ]; then
    run_family "fly-sim-core" "$BASE_FLY_SIM_CORE" "~7min（att_est/pos_ctrl 慢）" "$ROOT/fly-simulater" -p fly-sim-core || FAIL=1
fi

echo ""
if [ $FAIL -eq 0 ]; then
    echo "[H场] 全绿 ✓ —— 按 §5.38 纪律，允许进 M 场回归（./scripts/integrate.sh firmware && ./scripts/integrate.sh）"
else
    echo "[H场] 有失败 ✗ —— 先在 H 场修复，不要进 M 场（§5.38 纪律）"
    exit 1
fi
