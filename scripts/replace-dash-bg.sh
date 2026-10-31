#!/bin/bash
# 替换仪表页背景视频（默认皮肤），不需要 dylib、不需要连车、不需要解密
#
# 用法:
#   ./replace-dash-bg.sh <原IPA> <自定义mp4> <输出IPA> [--dark-only|--light-only]
#
# 规格要求（与官方一致，最稳）:
#   1126x2438 (亮) / 1124x2436 (暗)，H.264 High，yuv420p，30fps，约 2.03s，无音轨
set -euo pipefail

IN_IPA=${1:?原IPA}; CUSTOM=${2:?自定义mp4}; OUT_IPA=${3:?输出IPA}; MODE=${4:-both}
[[ -f "$IN_IPA" && -f "$CUSTOM" ]] || { echo "输入文件不存在"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "▸ 解包 $IN_IPA"
unzip -q "$IN_IPA" -d "$TMP"

BUNDLE="$TMP/Payload/Ninebot.app/Vehicle.bundle"
[[ -d "$BUNDLE" ]] || { echo "找不到 Vehicle.bundle"; exit 1; }

for f in dash_bg.mp4 dash_bg_dark.mp4; do
  case "$MODE" in
    --dark-only)  [[ "$f" == "dash_bg.mp4" ]] && continue ;;
    --light-only) [[ "$f" == "dash_bg_dark.mp4" ]] && continue ;;
  esac
  if [[ -f "$BUNDLE/$f" ]]; then
    echo "▸ 替换 $f  ($(stat -f%z "$BUNDLE/$f") B → $(stat -f%z "$CUSTOM") B)"
    cp "$CUSTOM" "$BUNDLE/$f"
  fi
done

echo "▸ 重新打包 $OUT_IPA"
rm -f "$OUT_IPA"
( cd "$TMP" && zip -qr "$OUT_IPA" Payload )
echo "✅ 完成: $OUT_IPA"
echo "   下一步：用你现有的重签名流程（注入 dylib 那套）签名并安装"
