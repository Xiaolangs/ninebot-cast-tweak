#!/bin/bash
# 修改 App 内置环境配置（免调试页直接切环境 / 开商城调试）
#
#   ./patch-appconfig.sh <app或ipa> --service dev|test|release|production|migrate \
#       [--channel develop|release|online] [--shop-debug 0|1] [--rn-env X] [--rn-branch X]
#
# ServiceKey/ServiceDict: 1=dev 2=test 3=release 4=production 5=migrate_cloud
# ChannelKey/ChannelDict: 1=Develop 2=Release 3=Online
set -euo pipefail

TARGET="${1:?用法: $0 <Ninebot.app|xxx.ipa> [选项]}"; shift
SERVICE=""; CHANNEL=""; SHOP=""; RNENV=""; RNBRANCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --service)    SERVICE="$2"; shift 2;;
    --channel)    CHANNEL="$2"; shift 2;;
    --shop-debug) SHOP="$2"; shift 2;;
    --rn-env)     RNENV="$2"; shift 2;;
    --rn-branch)  RNBRANCH="$2"; shift 2;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
APP=""
case "$TARGET" in
  *.ipa) unzip -q "$TARGET" -d "$WORK/x"; APP=$(find "$WORK/x/Payload" -maxdepth 1 -name "*.app" | head -1);;
  *.app) APP="$TARGET";;
  *) echo "目标必须是 .ipa 或 .app"; exit 1;;
esac
PL="$APP/AppConfig.plist"
[ -f "$PL" ] || { echo "未找到 $PL"; exit 1; }

get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PL" 2>/dev/null || echo "(无)"; }
setk(){ /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 $2" "$PL"; }

echo "=== 修改前 ==="
echo "  ServiceKey   = $(get ServiceKey)"
echo "  ChannelKey   = $(get ChannelKey)"
echo "  ShopDebug    = $(get ShopDebug)"
echo "  RNEnv        = $(get RNEnv)"
echo "  RNBranchName = $(get RNBranchName)"

case "$SERVICE" in
  dev) setk ServiceKey 1;; test) setk ServiceKey 2;; release) setk ServiceKey 3;;
  production|prod) setk ServiceKey 4;; migrate|migrate_cloud) setk ServiceKey 5;;
  "") ;;
  *) echo "未知 service: $SERVICE"; exit 1;;
esac
case "$CHANNEL" in
  develop|dev) setk ChannelKey 1;; release) setk ChannelKey 2;; online) setk ChannelKey 3;;
  "") ;;
  *) echo "未知 channel: $CHANNEL"; exit 1;;
esac
[ -n "$SHOP" ] && setk ShopDebug "$SHOP"
[ -n "$RNENV" ] && setk RNEnv "$RNENV"
[ -n "$RNBRANCH" ] && setk RNBranchName "$RNBRANCH"

echo "=== 修改后 ==="
echo "  ServiceKey   = $(get ServiceKey)"
echo "  ChannelKey   = $(get ChannelKey)"
echo "  ShopDebug    = $(get ShopDebug)"
echo "  RNEnv        = $(get RNEnv)"
echo "  RNBranchName = $(get RNBranchName)"

if [ "$TARGET" != "${TARGET%.ipa}" ]; then
  OUT="${TARGET%.ipa}-patched.ipa"
  ( cd "$WORK/x" && zip -qr "$OUT" Payload )
  echo "✅ 已生成: $OUT （需重新签名后安装）"
fi
