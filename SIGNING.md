# 本地重打包说明（签名由你自己完成）

> CI 只负责产出 dylib；IPA 注入与重签在你本机做。下面是我从证书文件里读到的**关键事实**和**已知坑**。

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

## 3. ⚠️ 已知坑：这个 p12 无法直接被 macOS 导入

`ZODB6R.p12` 用的是 **PBES2 / PBKDF2 / AES-256-CBC**（`openssl pkcs12 -info` 可验证）。
macOS 的 Security 框架对此报 `SecKeychainItemImport: Unable to decode the provided data.`，
`security import` 会失败、`find-identity` 显示 0 个身份。

必须先转成 3DES/SHA1 的老格式再导入：

```bash
cd ~/Downloads/证书_ZODB6R
openssl pkcs12 -in ZODB6R.p12 -passin pass:1 -nodes -out /tmp/zodb.pem

# ⚠️ /tmp/zodb.pem 是**明文私钥**，导入成功后请立刻 rm
openssl pkcs12 -export -in /tmp/zodb.pem -out /tmp/zodb_fixed.p12 -passout pass:1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security create-keychain -p test ~/sign.keychain
security unlock-keychain -p test ~/sign.keychain
security import /tmp/zodb_fixed.p12 -k ~/sign.keychain -P 1 -A -t cert -f pkcs12
security find-identity -v -p codesigning ~/sign.keychain     # 应显示 1 valid identity
rm -f /tmp/zodb.pem /tmp/zodb_fixed.p12
```

签名时用：`codesign -f -s "<identity>" --keychain ~/sign.keychain ...`

## 4. 本地重打包流程（参考 `scripts/sign-ipa.sh`）

1. 解包 IPA → `Payload/Ninebot.app`
2. 放 dylib 到 `Frameworks/`，并用 `scripts/inject.py` 加 `LC_LOAD_DYLIB`
   （`pip3 install 'lief==0.15.1'`；或改用 `insert_dylib`/`optool`）
3. **改 `CFBundleIdentifier`** → `app.spinach4448.grapefruit6740`（见第 2 节，非通配 App ID 必须改）
4. 从描述文件取 entitlements：`security cms -D -i ZODB6R.mobileprovision > p.plist`
   `plutil -extract Entitlements xml1 -o ent.plist p.plist`
5. 把 `embedded.mobileprovision` 放进 App 包
6. 由深到浅签名：Frameworks 内所有 Mach-O → PlugIns/*.appex → `Ninebot` → 整个 App（带 entitlements）
7. `zip -qryX out.ipa Payload`

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
