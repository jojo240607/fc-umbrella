#!/usr/bin/env bash
# 初始化所有子模块（含本地路径子模块的 file 协议放行）。
set -euo pipefail
cd "$(dirname "$0")/.."
if git config protocol.file.allow >/dev/null 2>&1 && [ "$(git config protocol.file.allow)" = "never" ]; then
    echo "[init] file 协议被禁用，本次用 -c 放行"
    git -c protocol.file.allow=always submodule update --init --recursive
else
    git submodule update --init --recursive
fi
echo "[init] 子模块就绪："
git submodule status
