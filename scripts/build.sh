#!/usr/bin/env bash
# 构建飞控固件。用法：./scripts/build.sh [real-sensors|hil] [out.bin]
set -euo pipefail
cd "$(dirname "$0")/../flyctrl"
FEAT="${1:-real-sensors}"
OUT="${2:-/tmp/flyctrl_${FEAT}.bin}"
python3 build_app.py --features "$FEAT" --out "$OUT"
echo "[build] ${FEAT} -> ${OUT}"
