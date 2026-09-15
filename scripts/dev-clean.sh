#!/usr/bin/env bash
#
# Removes everything this project put on the machine.
#
# Deliberately narrow: it only touches paths this project created, addressed by
# absolute path, and it never recurses outside the repo. Shared toolchain state
# (the SwiftPM caches, Command Line Tools) is left alone — see CLEANUP.md.
#
# Dry run by default. Pass --yes to actually delete.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/PHONE-CATCH-SCREEN"
LOGS="$HOME/Library/Logs/PHONE-CATCH-SCREEN"
APP="$HOME/Applications/PHONE-CATCH-SCREEN.app"
AGENT="$HOME/Library/LaunchAgents/com.sarainoq.screenbeam.plist"

DRY_RUN=1
[[ "${1:-}" == "--yes" ]] && DRY_RUN=0

echo
if (( DRY_RUN )); then
    echo "演练模式：下面这些会被删除。加 --yes 才会真的执行。"
else
    echo "将删除以下内容："
fi
echo

targets=("$ROOT/.build" "$ROOT/dist" "$SUPPORT" "$LOGS")
for target in "${targets[@]}"; do
    if [[ -e "$target" ]]; then
        printf '  %-8s %s\n' "$(du -sh "$target" 2>/dev/null | cut -f1)" "$target"
    fi
done

# The installed app and its agent are handled by the app's own uninstall, which
# also stops the service first — deleting the bundle out from under a running
# LaunchAgent would leave it respawning against a missing binary.
installed=0
for target in "$APP" "$AGENT"; do
    [[ -e "$target" ]] && installed=1
done
if (( installed )); then
    echo
    echo "  已安装的后台服务会先通过 screenbeam uninstall 停止并移除："
    [[ -e "$APP" ]] && echo "          $APP"
    [[ -e "$AGENT" ]] && echo "          $AGENT"
fi

echo
if (( DRY_RUN )); then
    echo "（演练结束，未删除任何文件）"
    echo
    exit 0
fi

if (( installed )); then
    echo "==> 停止并卸载后台服务"
    if [[ -x "$APP/Contents/MacOS/screenbeam" ]]; then
        "$APP/Contents/MacOS/screenbeam" uninstall || true
    else
        /bin/launchctl bootout "gui/$(id -u)/com.sarainoq.screenbeam" 2>/dev/null || true
        /bin/rm -f "$AGENT"
        /bin/rm -rf "$APP"
    fi
fi

for target in "${targets[@]}"; do
    [[ -e "$target" ]] || continue
    echo "==> 删除 $target"
    /bin/rm -rf "$target"
done

echo
echo "完成。剩下这一项 macOS 不允许脚本处理，需要你手动做："
echo "  系统设置 → 隐私与安全性 → 屏幕录制 → 移除 PHONE·CATCH·SCREEN 条目"
echo
