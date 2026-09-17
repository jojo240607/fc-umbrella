#!/usr/bin/env bash
# 构建飞控固件。用法：./scripts/build.sh [real-sensors|hil] [out.bin]
#
# 默认产物名按「联调约定」固定——README / docs / scripts / 11 个测试 / fly-sim-server
# 都引用这两个名字，不能再按 feature 直接拼：
#   real-sensors -> /tmp/flyctrl_real.bin
#   hil          -> /tmp/flyctrl_hil.bin
# （旧写法 real-sensors 会拼出 /tmp/flyctrl_real-sensors.bin，没有第二处引用，
#   等于"构建成功但没人找得到产物"。）
set -euo pipefail
cd "$(dirname "$0")/../flyctrl"
FEAT="${1:-real-sensors}"
case "$FEAT" in
  real-sensors) DEFAULT_OUT="/tmp/flyctrl_real.bin" ;;
  *)            DEFAULT_OUT="/tmp/flyctrl_${FEAT}.bin" ;;
esac
OUT="${2:-$DEFAULT_OUT}"
python3 build_app.py --features "$FEAT" --out "$OUT"
echo "[build] ${FEAT} -> ${OUT}"
