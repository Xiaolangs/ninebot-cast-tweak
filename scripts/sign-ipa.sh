#!/bin/bash
# Ad-hoc 重签：解包 → 注入 dylib → 改 bundle id → 底层向上逐层签名 → 重新打包
# 依赖环境变量：SIGN_ID / ENT_PLIST / WORK_DIR / NEW_BUNDLE_ID
set -euo pipefail

: "${SIGN_ID:?}" "${ENT_PLIST:?}" "${WORK_DIR:?}" "${NEW_BUNDLE_ID:?}"
IPA_IN="$1"; DYLIB="$2"; IPA_OUT="$3"

cd "$WORK_DIR"
rm -rf Payload && unzip -q "$IPA_IN"
APP="Payload/Ninebot.app"

cp "$DYLIB" "$APP/Frameworks/ProjectionOverride.dylib"
python3 "$(dirname "$0")/inject.py" "$APP" "Frameworks/ProjectionOverride.dylib" "$NEW_BUNDLE_ID"

# --- 从描述文件取 entitlements（其中 application-identifier 已对应此 App ID）---
cp "$PROFILE_PATH" "$APP/embedded.mobileprovision"

sign_plain() { codesign -f -s "$SIGN_ID" --timestamp=none "$@"; }

# 1) 先签所有嵌套二进制（framework / dylib / appex），由深到浅
find "$APP/Frameworks" -type f \( -perm -u+x -o -name "*.dylib" \) 2>/dev/null | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then echo "  sign $f"; sign_plain "$f"; fi
done
if [ -d "$APP/PlugIns" ]; then
  find "$APP/PlugIns" -name "*.appex" -type d | while read -r e; do
    find "$e" -type f -perm -u+x | while read -r f; do
      file "$f" | grep -q "Mach-O" && sign_plain "$f"
    done
    sign_plain --entitlements "$ENT_PLIST" "$e"
  done
fi
# 2) 主程序（带 entitlements）
sign_plain --entitlements "$ENT_PLIST" "$APP/Ninebot"
# 3) 整个 App 包
sign_plain --entitlements "$ENT_PLIST" "$APP"

codesign -d --entitlements :- "$APP" 2>/dev/null | head -5 || true
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3

rm -f "$IPA_OUT"
zip -qryX "$IPA_OUT" Payload
echo "✅ 产出: $IPA_OUT ($(du -h "$IPA_OUT" | cut -f1))"
