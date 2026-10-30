#!/bin/bash
# 重打包后的自检：确认 dylib 只注入一次、bundle id 正确、描述文件已嵌入
set -uo pipefail
IPA="${1:?用法: check-ipa.sh <ipa路径>}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unzip -q "$IPA" -d "$T" || { echo "❌ IPA 解包失败"; exit 1; }
APP=$(find "$T/Payload" -maxdepth 1 -name "*.app" -type d | head -1)
[ -z "$APP" ] && { echo "❌ 找不到 Payload/*.app"; exit 1; }
BIN="$APP/$(basename "${APP%.app}")"
[ -f "$BIN" ] || BIN=$(find "$APP" -maxdepth 1 -type f -perm -u+x | head -1)

echo "=== 1. LC_LOAD_DYLIB 中 Projection 条目（必须恰好 1 条）==="
N=$(otool -L "$BIN" | grep -ci "Projection" || true)
otool -L "$BIN" | grep -i "Projection" || echo "  （无）"
[ "$N" -eq 1 ] && echo "  ✅ 1 条" || echo "  ❌ 发现 $N 条（重复注入会导致多份逻辑同时运行）"

echo "=== 2. Frameworks 下的 dylib 文件（必须恰好 1 个）==="
ls -la "$APP/Frameworks/" 2>/dev/null | grep -i projection || echo "  （无）"
M=$(find "$APP" -name "*Projection*.dylib" | wc -l | tr -d ' ')
[ "$M" -eq 1 ] && echo "  ✅ 1 个" || echo "  ❌ 发现 $M 个文件"

echo "=== 3. Bundle ID ==="
BID=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
echo "  $BID"
[ "$BID" = "app.spinach4448.grapefruit6740" ] && echo "  ✅ 与描述文件 App ID 一致" \
  || echo "  ⚠️ 需为 app.spinach4448.grapefruit6740（非通配 App ID 时必须改）"

echo "=== 4. 描述文件 ==="
[ -f "$APP/embedded.mobileprovision" ] && echo "  ✅ 已嵌入" || echo "  ❌ 缺少 embedded.mobileprovision"

echo "=== 5. 签名 ==="
codesign --verify --strict "$APP" 2>&1 | tail -2 && echo "  （无输出=通过）"
