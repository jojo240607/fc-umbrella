#!/usr/bin/env bash
# 一键回归（各仓库核心测试）。机器慢时建议单跑并加 --release。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==== flyctrl core ===="
(cd "$ROOT/flyctrl" && cargo test --lib 2>&1 | grep -E "test result" | head -1)
echo "==== fly-simulater fly-sim-core ===="
(cd "$ROOT/fly-simulater" && cargo test -p fly-sim-core 2>&1 | grep -E "test result" | head -3)
echo "==== fly-simulater sensor_fault ===="
(cd "$ROOT/fly-simulater" && cargo test --test sensor_fault 2>&1 | grep -E "test result" | head -1)
echo "==== mcu_simulater lib ===="
(cd "$ROOT/mcu_simulater" && cargo test --lib 2>&1 | grep -E "test result" | head -1)
echo "[verify] 完成（SIL/HIL/全链路等长测试请按 docs/integration.md 单跑）"
