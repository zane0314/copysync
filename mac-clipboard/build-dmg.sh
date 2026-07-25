#!/bin/zsh
set -euo pipefail

root=${0:A:h}
build="$root/build-2.0"
app="$build/CopySync.app"
rm -rf "$build"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
clang -fobjc-arc "$root/CopySync.m" -framework Cocoa -framework ApplicationServices -framework Carbon -framework ServiceManagement -framework UserNotifications -framework WebKit -o "$app/Contents/MacOS/CopySync"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# 使用固定的自签名证书（signing/copysync-sign.p12，CN=CopySync Local Signing），
# 保证每次构建的 Designated Requirement 不变，macOS TCC（屏幕录制/辅助功能）授权在更新后仍然有效。
# 证书缺失时回退 ad-hoc 签名（更新后需重新授权）。
identity="CopySync Local Signing"
if security find-certificate -c "$identity" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  codesign --force --deep --sign "$identity" "$app"
else
  print "warning: 未找到签名证书 $identity，回退 ad-hoc 签名（更新后权限会失效）"
  codesign --force --deep --sign - "$app"
fi
hdiutil create -volname CopySync -srcfolder "$app" -ov -format UDZO "$build/CopySync-2.0.dmg"
print "Built $build/CopySync-2.0.dmg"
