#!/usr/bin/env bash
#
# Builds ScreenBeam and assembles a real .app bundle.
#
# The bundle is not cosmetic. macOS keys the Screen Recording (TCC) grant to a
# process's code identity. A bare `swift build` binary has none, so the grant
# lands on whatever launched it — Terminal, or launchd — and evaporates the next
# time you rebuild. A bundle with a fixed CFBundleIdentifier and a signature is
# what makes the permission stick to ScreenBeam itself.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="PHONE-CATCH-SCREEN"
BUNDLE_ID="com.sarainoq.screenbeam"
CONFIG="${CONFIG:-release}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# The Swift source is the single source of truth for the version.
VERSION="$(/usr/bin/grep -m1 'static let current' \
    Sources/ScreenBeamCore/Support/ScreenBeamVersion.swift \
    | /usr/bin/sed -E 's/.*"(.*)".*/\1/')"
VERSION="${VERSION:-0.0.0}"

echo "==> 构建 ScreenBeam $VERSION ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/screenbeam"
if [[ ! -x "$BIN" ]]; then
    echo "构建产物不存在：$BIN" >&2
    exit 1
fi

echo "==> 组装 $APP"
# Clear every bundle, not just the one we are about to build. A leftover from an
# earlier name would otherwise linger in dist/ and could be picked up by install.
rm -rf "$DIST"/*.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/screenbeam"
chmod +x "$APP/Contents/MacOS/screenbeam"

/usr/bin/sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- Signing -----------------------------------------------------------------
#
# Prefer a real code-signing identity when one exists. For an ad-hoc signature
# the designated requirement is the cdhash, which changes on every rebuild — so
# macOS treats the new binary as a different app and the Screen Recording grant
# has to be given again. A stable identity avoids that entirely.

IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk '/[0-9]+\) [0-9A-F]{40}/ {print $2; exit}')"

if [[ -n "${IDENTITY:-}" ]]; then
    echo "==> 使用签名身份 $IDENTITY"
    /usr/bin/codesign --force --deep --options runtime \
        --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
else
    echo "==> 使用 ad-hoc 签名（未找到代码签名证书）"
    echo "    注意：ad-hoc 签名的应用每次重新构建后，屏幕录制权限可能需要重新授予。"
    /usr/bin/codesign --force --deep \
        --identifier "$BUNDLE_ID" --sign - "$APP"
fi

/usr/bin/codesign --verify --verbose=1 "$APP" 2>&1 | /usr/bin/sed 's/^/    /'

echo
echo "==> 完成：$APP"
echo
echo "下一步："
echo "    screenbeam install      # 安装到 ~/Applications 并注册后台服务"
echo "  或"
echo "    $APP/Contents/MacOS/screenbeam run    # 直接前台试运行"
