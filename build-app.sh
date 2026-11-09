#!/bin/bash
# 打包成 .app。ad-hoc 签名是必须的：UserNotifications 与 SMAppService 都要求真正的 bundle + 签名。
set -e
cd "$(dirname "$0")"

echo "构建流影…"
# -disable-sandbox：@Observable / Observation 宏插件在受限 SwiftPM 沙箱里会失败。
swift build -c release -Xswiftc -disable-sandbox

APP_NAME="liuying"
# bundle 文件名用显示名，和 /Applications 里安装的名字保持一致 ——
# 否则「删掉 流影.app 再拷 liuying.app」会变成另一个路径，TCC 授权就对不上了。
APP_BUNDLE="流影.app"
BUILD_DIR=".build/release"
TARGET="$BUILD_DIR/$APP_BUNDLE"

rm -rf "$TARGET"
mkdir -p "$TARGET/Contents/MacOS" "$TARGET/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$TARGET/Contents/MacOS/"
cp "$BUILD_DIR/liuyingctl" "$TARGET/Contents/MacOS/"
cp Resources/Info.plist "$TARGET/Contents/"

if [ -f Resources/liuying.icns ]; then
    cp Resources/liuying.icns "$TARGET/Contents/Resources/"
else
    echo "⚠️  没有 Resources/liuying.icns，先用 tools/render-icon.swift 生成"
fi

# SwiftPM 资源 bundle（当前没有，将来加 xcstrings 时会用到）
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    rm -rf "$TARGET/Contents/Resources/$(basename "$bundle")"
    cp -R "$bundle" "$TARGET/Contents/Resources/"
    echo "打包资源：$(basename "$bundle")"
done

echo "签名…"
# 优先用稳定的开发身份：TCC 授权（完全磁盘访问 / 文件夹访问）绑定代码签名，
# ad-hoc 签名每次重编都会变，授权就会失效；固定身份签名则能跨重编保留。
IDENTITY="Apple Development: yufei.im@gmail.com (W5FU2X8TUB)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$TARGET"
    echo "  已用：$IDENTITY"
else
    codesign --force --deep --sign - "$TARGET"
    echo "  ⚠️  没找到开发身份，退回 ad-hoc（重编后可能需要重新授权）"
fi
codesign -dv "$TARGET" 2>&1 | sed 's/^/  /'

echo ""
echo "✅ 已生成：$TARGET"
echo ""
echo "安装（/Applications 对 admin 组可写，不需要 sudo）："
echo "  pkill -f \"/Applications/流影.app/Contents/MacOS/liuying\""
echo "  rm -rf \"/Applications/流影.app\""
echo "  ditto \"$TARGET\" \"/Applications/流影.app\""
echo "  open \"/Applications/流影.app\""
echo ""
echo "命令行工具："
echo "  \"/Applications/流影.app/Contents/MacOS/liuyingctl\" doctor"
