#!/bin/bash
# 打包成 .app。ad-hoc 签名是必须的：UserNotifications 与 SMAppService 都要求真正的 bundle + 签名。
set -e
cd "$(dirname "$0")"

echo "构建流影…"
# -disable-sandbox：@Observable / Observation 宏插件在受限 SwiftPM 沙箱里会失败。
swift build -c release -Xswiftc -disable-sandbox

# 内嵌 liuying-engine：Go 单文件二进制，编进 .app/Contents/MacOS/ 供 B 站后端使用。
# 路径可用 ENGINE_SRC 覆盖；本机默认与流影平级的仓库。CGO_ENABLED=0 产出无动态依赖。
ENGINE_SRC="${ENGINE_SRC:-/Users/yufei/Git/liuying-engine}"
if [ ! -f "$ENGINE_SRC/go.mod" ]; then
    echo "❌ 找不到 liuying-engine 源码：$ENGINE_SRC（可用 ENGINE_SRC 环境变量指定）"
    exit 1
fi
echo "构建 liuying-engine（$ENGINE_SRC）…"
GO_BIN="${GO_BIN:-}"
if [ -z "$GO_BIN" ]; then
    for candidate in /opt/homebrew/bin/go /usr/local/bin/go; do
        [ -x "$candidate" ] && GO_BIN="$candidate" && break
    done
fi
[ -z "$GO_BIN" ] && GO_BIN="$(command -v go 2>/dev/null || true)"
if [ -z "$GO_BIN" ]; then
    echo "❌ 找不到 go 可执行文件（可用 GO_BIN 环境变量指定）"
    exit 1
fi
REPO_ROOT="$(pwd)"
(cd "$ENGINE_SRC" && CGO_ENABLED=0 "$GO_BIN" build -trimpath -ldflags "-s -w" -o "$REPO_ROOT/.build/release/liuying-engine" .)
echo "  liuying-engine 已构建"

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
cp "$BUILD_DIR/liuying-engine" "$TARGET/Contents/MacOS/"
chmod +x "$TARGET/Contents/MacOS/liuying-engine"
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

# 确认内嵌二进制可执行且被签名覆盖（--deep 会签 Contents/MacOS 下的 Mach-O）。
test -x "$TARGET/Contents/MacOS/liuying-engine" || { echo "❌ 内嵌 liuying-engine 不可执行"; exit 1; }
codesign -v "$TARGET/Contents/MacOS/liuying-engine" 2>/dev/null \
    && echo "  liuying-engine 已随 .app 签名" \
    || echo "  ⚠️  liuying-engine 未单独验证通过，检查 codesign --deep 是否覆盖"

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
