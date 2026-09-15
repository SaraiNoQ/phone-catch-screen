#!/usr/bin/env bash
#
# One-shot setup: build the bundle, install it, register the LaunchAgent, and
# raise the Screen Recording consent dialog.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build.sh"

# Discover the bundle rather than naming it here. A hardcoded name silently
# installs a *stale* bundle left over from a previous build after a rename —
# which is exactly what happened once. build.sh clears dist/ of old bundles, so
# there should be precisely one.
BUNDLE="$(/usr/bin/find "$ROOT/dist" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "$BUNDLE" ]]; then
    echo "dist/ 下没有找到 .app，构建可能失败了。" >&2
    exit 1
fi

BINARY="$BUNDLE/Contents/MacOS/screenbeam"
echo
echo "==> 安装到 ~/Applications 并注册后台服务（$(basename "$BUNDLE")）"
"$BINARY" install

echo
echo "==> 当前状态"
"$BINARY" status || true
