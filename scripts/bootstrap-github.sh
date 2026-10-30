#!/bin/bash
# 一键：建私有仓库 → 推送 → 设 Secrets → 建 Release 传 IPA → 触发构建签名
# 用法: bootstrap-github.sh <repo名> <p12路径> <profile路径> <p12密码> <ipa路径>
set -euo pipefail
REPO_NAME="${1:?}"; P12="${2:?}"; PROFILE="${3:?}"; P12PW="${4:?}"; IPA="${5:?}"
cd "$(dirname "$0")/.."

GH=/Users/mac11/Desktop/dsh/xx/tools/gh/gh_2.103.3_macOS_arm64/bin/gh
export GH_TOKEN="$(cat /Users/mac11/Desktop/dsh/xx/.ghcfg/token)"
export GH_CONFIG_DIR=/Users/mac11/Desktop/dsh/xx/.ghcfg

OWNER=$("$GH" api user -q .login)
echo "登入账号: $OWNER"

# 1) 建私有仓库并推送
if "$GH" repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  echo "仓库已存在，跳过创建"
else
  "$GH" repo create "$REPO_NAME" --private --source . --remote origin --push
fi
git push -u origin main 2>/dev/null || git push origin main || true

# 2) Secrets（私钥不落地明文）
openssl base64 -A -in "$P12"     | "$GH" secret set P12_BASE64     -R "$OWNER/$REPO_NAME"
openssl base64 -A -in "$PROFILE" | "$GH" secret set PROFILE_BASE64 -R "$OWNER/$REPO_NAME"
printf '%s' "$P12PW" | "$GH" secret set P12_PASSWORD -R "$OWNER/$REPO_NAME"
echo "Secrets 已设置"

# 3) IPA 放私有 Release（不进 git）
TMP=$(mktemp -d); cp "$IPA" "$TMP/Ninebot.ipa"
if "$GH" release view ipa-assets -R "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  "$GH" release upload ipa-assets "$TMP/Ninebot.ipa" --clobber -R "$OWNER/$REPO_NAME"
else
  "$GH" release create ipa-assets "$TMP/Ninebot.ipa" \
    --title "IPA assets" --notes "签名用原始 IPA" -R "$OWNER/$REPO_NAME"
fi
rm -rf "$TMP"
echo "Release 就绪"
