#!/usr/bin/env bash
#
# One-shot setup: build the bundle, install it, register the LaunchAgent, and
# raise the Screen Recording consent dialog.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build.sh"

echo
echo "==> 安装到 ~/Applications 并注册后台服务"
"$ROOT/dist/ScreenBeam.app/Contents/MacOS/screenbeam" install

echo
echo "==> 当前状态"
"$ROOT/dist/ScreenBeam.app/Contents/MacOS/screenbeam" status || true
