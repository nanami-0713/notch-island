#!/bin/bash
# 构建 NotchIsland.app：swift build release + 手工打包 bundle + 签名
# 签名身份：优先用本地名为 "NotchIsland Dev" 的自签证书（重建后辅助功能授权不失效）；
# 没有则回退 ad-hoc（-），此时每次重新构建后需在 系统设置→辅助功能 里重新授权。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/NotchIsland.app"
BIN=".build/release/NotchIsland"
# 在 /tmp 组装，避免 build/ 目录残留 Finder 属性导致 codesign 报 detritus
STAGE="$(mktemp -d)/NotchIsland.app"
APP="$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchIsland"
cp "Packaging/Info.plist" "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"

# MediaRemoteAdapter 助手（perl 宿主绕过 macOS 15.4+ 的 MediaRemote 封锁）
MRA_OUT="$APP/Contents/Resources/MediaRemoteAdapter"
mkdir -p "$MRA_OUT/MediaRemoteAdapter.framework"
clang -dynamiclib -fobjc-arc -fmodules -mmacosx-version-min=13.0 \
  -I "vendor/mediaremote-adapter/include" -I "vendor/mediaremote-adapter/src" \
  vendor/mediaremote-adapter/src/adapter/env.m \
  vendor/mediaremote-adapter/src/adapter/get.m \
  vendor/mediaremote-adapter/src/adapter/globals.m \
  vendor/mediaremote-adapter/src/adapter/keys.m \
  vendor/mediaremote-adapter/src/adapter/now_playing.m \
  vendor/mediaremote-adapter/src/adapter/repeat.m \
  vendor/mediaremote-adapter/src/adapter/seek.m \
  vendor/mediaremote-adapter/src/adapter/send.m \
  vendor/mediaremote-adapter/src/adapter/shuffle.m \
  vendor/mediaremote-adapter/src/adapter/speed.m \
  vendor/mediaremote-adapter/src/adapter/stream.m \
  vendor/mediaremote-adapter/src/adapter/test.m \
  vendor/mediaremote-adapter/src/private/MediaRemote.m \
  vendor/mediaremote-adapter/src/utility/Debounce.m \
  vendor/mediaremote-adapter/src/utility/helpers.m \
  -framework Foundation -framework AppKit \
  -o "$MRA_OUT/MediaRemoteAdapter.framework/MediaRemoteAdapter"
cp "vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" "$MRA_OUT/"

if [ -f "Packaging/AppIcon.icns" ]; then
  cp "Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign "NotchIsland Dev" "$MRA_OUT/MediaRemoteAdapter.framework/MediaRemoteAdapter" 2>/dev/null \
  || codesign --force --sign - "$MRA_OUT/MediaRemoteAdapter.framework/MediaRemoteAdapter"
if ! codesign --force --sign "NotchIsland Dev" "$APP" 2>/tmp/codesign_err.txt; then
  echo "stable sign failed: $(cat /tmp/codesign_err.txt)"
  codesign --force --sign - "$APP"
fi
# 不用 grep -q：提前退出会让 codesign 吃 SIGPIPE，配合 pipefail 误判为失败
AUTH=$(codesign -dvv "$APP" 2>&1 | grep "Authority=" || true)
if [[ "$AUTH" == *"NotchIsland Dev"* ]]; then
  echo "Signed with: NotchIsland Dev (stable, TCC 授权跨重建有效)"
else
  echo "Signed with: ad-hoc（提示：创建自签代码签名证书并命名为 NotchIsland Dev，可让辅助功能授权在重新构建后保持有效）"
fi
rm -rf build/NotchIsland.app
mkdir -p build
xattr -cr "$APP" 2>/dev/null || true
cp -R "$APP" build/NotchIsland.app
echo "Built: $PWD/build/NotchIsland.app"
