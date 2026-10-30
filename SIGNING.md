# 签名方案（基于你提供的 ZODB6R 证书）

## 1. 我从两个文件里读到的确定事实

| 项 | 值 |
|---|---|
| 证书主体 | `iPhone Distribution: Corder Clark (YSQ5786EY6)` |
| Team ID | `YSQ5786EY6` |
| 证书有效期 | 2026-07-05 → **2027-07-05** |
| p12 密码 | `1`（已验证可解出证书） |
| 描述文件类型 | **Ad-hoc**（`ProvisionedDevices` 只有 1 台） |
| 设备 UDID | `00008130-00165D6436DA001C` |
| App ID | `YSQ5786EY6.app.spinach4448.grapefruit6740`（**非通配**） |
| get-task-allow | `false`（发布证书，无法 lldb 调试） |
| aps-environment | `production` |

## 2. ⚠️ 决定性结论：必须改 Bundle ID

描述文件的 App ID 是**具体值** `app.spinach4448.grapefruit6740`，不是通配符。
iOS 安装时会校验 `application-identifier` 与 App 的 Bundle ID 一致，
而九号出行的 Bundle ID 是 `cn.ninebot.segway` —— 直接签会装不上（entitlement / bundle id 不匹配）。

**所以流水线会自动把 `CFBundleIdentifier` 改成 `app.spinach4448.grapefruit6740`**
（从描述文件读取 `application-identifier` 推导，不靠手填）。

### 这个改动的真实代价（必须知情）

1. **会与 App Store 版并存**安装（两个九号出行）。
2. 服务端若校验 bundle id / appkey，可能导致登录或接口异常——这是**未经证实**的风险，需实机验证。
3. 推送（APNs）不会工作：`aps-environment=production` 但推送证书属于那个 App ID，不是九号的。
4. 分享/唤起用 URL Scheme（微信、QQ、米 ID）仍可用，因为走的是 scheme 不是 bundle id。
5. `get-task-allow=false` → 不能用 Xcode 附加调试；排查只能看 `os_log`。

### 设备限制

Ad-hoc 只能装到描述文件里那台设备：`00008130-00165D6436DA001C`。
**如果这不是你要用的 iPhone，装不上的**——需要重新生成一份包含目标机 UDID 的描述文件。

## 3. 需要你设置 3 个 Secret

仓库 → Settings → Secrets and variables → Actions → New repository secret：

```bash
# 生成待粘贴的值（在你本机执行，别提交文件）
openssl base64 -A -in /Users/mac11/Downloads/证书_ZODB6R/ZODB6R.p12 | pbcopy      # → P12_BASE64
openssl base64 -A -in /Users/mac11/Downloads/证书_ZODB6R/ZODB6R.mobileprovision | pbcopy  # → PROFILE_BASE64
```
- `P12_BASE64` = 上面第一个
- `PROFILE_BASE64` = 上面第二个
- `P12_PASSWORD` = `1`

> ⚠️ 该 p12 密码是 `1`，且私钥已在你我之间传递过。**测试完建议吊销并重新签发**。
> p12 / mobileprovision 已加入 `.gitignore`，绝不会进仓库。

## 4. 把 IPA 放进私有 Release（不进 git）

255 MB 的 IPA 不适合提交。用私有 Release 存一份，CI 用内置 `GITHUB_TOKEN` 下载：

```bash
gh release create ipa-assets /Users/mac11/Downloads/cn.ninebot.segway_6.10.9_und3fined.ipa \
  --title "IPA assets" --notes "签名用原始 IPA"
# 注意：资产名需为 Ninebot.ipa
```
或改名后再传：`cp .../cn.ninebot...ipa Ninebot.ipa && gh release upload ...`
（也可在手动触发时直接填 `ipa_url` 直链，跳过 Release。）

## 5. 触发与产物

Actions → **Build & Sign IPA** → Run workflow。
流程：构建 dylib → 取 IPA → 导入证书到临时 keychain → 提取 entitlements →
注入 dylib + 改 bundle id → 由深到浅逐层重签 → 校验 → 上传 `Ninebot-signed`。

产物：`Ninebot_ProjectionOverride.ipa`，用 Apple Configurator / Xcode Devices 安装。

## 6. 如果是通配描述文件会怎样

流水线会检测到 `*` 并**保留原 bundle id**（`cn.ninebot.segway`），此时上面第 2 节的风险全部不存在。
当前这份不是通配，所以会改名。

## 7. 我没有做的事（需要你授权）

- **没有创建 GitHub 私有仓库**：本机无 `gh`、无 token、无凭据（`git credential.helper=osxkeychain` 但我无法访问钥匙串）。
- 没有推送任何东西，证书也没有离开本机。
