#!/bin/bash
# 构建并启动 TCC 探针 .app。
#
# 关键点：必须经 `open` 由 LaunchServices 启动，探针才是自己的 TCC 责任进程；
# 直接在 shell 里跑二进制会把权限归属算到终端头上，测出来的结论无效。
set -e
cd "$(dirname "$0")/.."

OUT=".build/tcc-probe"
APP="$OUT/Probe.app"

mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译探针…"
swiftc -O tools/tcc-probe.swift -o "$APP/Contents/MacOS/Probe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleExecutable</key><string>Probe</string>
    <key>CFBundleIdentifier</key><string>im.yufei.liuying.probe</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>流影权限探针</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "ad-hoc 签名…"
codesign --force --deep --sign - "$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/  /'

mkdir -p "$HOME/Library/Logs/LiuYing"
RESULT="$HOME/Library/Logs/LiuYing/tcc-probe.txt"
rm -f "$RESULT"

echo "启动探针（会弹出窗口）…"
open "$APP"

echo ""
echo "结果文件：$RESULT"
echo "若被权限拦截：在探针窗口点「打开完全磁盘访问权限…」，把 Probe.app 加进去并勾选，"
echo "然后回到探针窗口点「重新检测」。授权后可能需要退出探针再重跑本脚本。"