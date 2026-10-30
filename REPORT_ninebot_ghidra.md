# 九号出行 (cn.ninebot.segway) 6.10.9 — Ghidra 逆向分析报告

目标: `/Users/mac11/Downloads/cn.ninebot.segway_6.10.9_und3fined.ipa`
主二进制: `Payload/Ninebot.app/Ninebot`
SHA-256: `1302f1938023fd8a6d967c0e27b090e9aaeee695d0f43a80a7587fd79520284b`

---

## 1. 身份与构建事实（observation）

| 项 | 值 |
|---|---|
| Bundle ID | `cn.ninebot.segway` |
| 显示名 / 版本 | 九号出行 / 6.10.9 |
| 架构 | arm64（thin） |
| 大小 | 205,182,080 B；`__TEXT` 175 MB，`__text` 144,377,556 B |
| Ghidra 语言 | `AARCH64:LE:64:AppleSilicon:swift` |
| 函数总数 | **676,540**（含 21,075 外部符号） |
| 定义字符串 | 75,852（Ghidra 定义集，非全部字面量） |
| 符号 | 736,534（nm）；8,891 个 ObjC 类；70,443 个 Swift 符号 |
| 技术栈 | React Native + Hermes；大量 Swift；动态库仅 5 个（IJKMediaPlayerKit / ScanKitFrameWork / hermes / NEYDnn / NBBLEEncryption）|

App 配置（`AppConfig.plist`）：`ChannelKey=3(Online)`、`ServiceKey=4(production)`、`BugsnagKey=3(Online)`。
`Info.plist` 声明 `NSAllowsArbitraryLoads = true`（全局放开 ATS），并保留 `NSExceptionAllowsInsecureHTTPLoads`。

## 2. 分析方法（可复现）

REA MCP 的 Ghidra 会话受客户端 ~10 分钟调用超时限制，无法完成 205 MB 导入（每次超时后临时数据库被丢弃）。改为直接驱动 Ghidra 12.1.4 headless，建立**持久化工程**，从而只导入/分析一次：

- 工程：`ghidra_proj/NinebotIPA`（3.3 GB）
- 分析耗时：8,060 s（2h14m），`Analysis succeeded`
- 关闭的三个重型 analyzer：`Decompiler Parameter ID`、`Decompiler Switch Analysis`、`Aggressive Instruction Finder`（脚本 `ghidra_scripts/DisableSlowAnalyzers.java`）；反编译改为按需执行
- 产物：`analysis/dump/functions.tsv`、`strings.tsv`、`externals.tsv`；`analysis/qualified.tsv`（带命名空间）；`analysis/allstrings.txt`
- 按需反编译：`analysis/crypto/`、`crypto2/`、`cipher/`（共 80 个函数，0 失败）

## 3. 模块地图（按命名空间的函数数）

自研/核心：`NBBaseUIKit` 3916 · `NBDynamicModule` 3130 · `Vehicle` 1455(+扩展 413) · `Common` 1300 · `NBUserSDK` 814 · `NBMapModul` 723 · **`NBBluetoothModule` 646** · `BNStrategyManager` 571 · `NBVideoFactoryModule` 567 · `NBTimeLine` 409 · `VMapDSLTools` 401 · `NBAuth` 315
地图/导航：`BNaviModel` 916 · `BARMainController` 906 · `MAMapView` 513 · `BNaviViewController` 442 · `BNRoutePlanManager` 417 · `BMKMapView` 396 · `AMapNaviDriveManager` 292（百度 BMK/BN + 高德 AMap 双地图栈并存）
三方库：`ZLPhotoBrowser` 1144 · `Alamofire` 1144 · `JXSegmentedView` 668 · `Former` 608 · `Lottie` 364 · `RxSwift`/`RxCocoa`/`FLEX`·`Floaty`·`YYTextView`

## 4. 加密与密钥相关代码（核心发现）

### 4.1 `JCOREDataSecurity` 加密套件
`JCOREDataSecurity::encrypt:aesKey:` @ `0x1005a1bf4`
→ UTF-8 → `AES256EncryptData:withKey:` @ `0x1005a1efc` → Base64。

`AES256EncryptData:withKey:` 实际调用 `doCryptWith:key:keyLen:operation:options:iv:` @ `0x1005a212c`，实参为 **`keyLen = 0x10`、`operation = 0`、`options = 3`、`iv = nil`**。

在 CommonCrypto 调用点（`0x1005a2258` → `CCCrypt`）观察到寄存器设置：
`x0=0`（kCCEncrypt）、`w1=0`（kCCAlgorithmAES）、`x2=3`（kCCOptionPKCS7Padding|kCCOptionECBMode）、`x4=0x10`（密钥长度 16）、`x5=0`（IV 为空）。

**结论（derived）**：名为 "AES256" 的方法实际做的是 **AES-128-ECB + PKCS7**，无 IV。
（算法由 keyLen 决定：alg=0 + 16 字节密钥 = AES-128；options 含 ECB 位 = ECB 模式。寄存器与 CCCrypt ABI 的对应为推断，常量为观察值。）

其他同类：`aes256EncryptData:withKey:iv:` @ `0x1005a1f34`、`aes256DecryptData:withKey:` @ `0x1005a2110`、`doCipher:key:context:padding:` @ `0x1005a1d38`、`encryptDataTypeToCurrentStringType:` @ `0x1005a19e4`。

### 4.2 请求签名
`JCOREDataSecurity::hmacSHA256WithKey:content:` @ `0x1005a2ef0`
→ 对 key/content 取 `cStringUsingEncoding:4`(UTF-8)，`strlen` 求长，调用 `CCHmac(2 /*kCCHmacAlgSHA256*/, key, keyLen, content, contentLen, out)`，输出 32 字节并格式化成 64 字符小写十六进制。
（注：以 `strlen` 而非 `length` 取长，二进制内容会被截断——静态观察到的实现细节。）

### 4.3 非对称 / 硬件密钥
- `Common.SecureEnclaveUtil.signString(tag:text:)` @ `0x100443770`、`signData` @ `0x1004436cc`、`verifySignature` @ `0x100443de8`/`0x100443dec`、`retrievePublicKey` @ `0x10044360c`、`deleteKey` @ `0x10044345c` —— 基于 Secure Enclave 的签名/验签（Swift）。
- `$decryptRSA_OAEP_SHA256` @ `0x1009eecf8`、`$encryptRSA_OAEP_SHA256` @ `0x1009eeee8`
- `UTDIDAES::AES256EncryptWithKey:forKey:` @ `0x1074b6568`、`BMK_AES128_CTR_decryptData:withKey:iv:` @ `0x1074ebcc8`、`BMK_AES128_CBC_…` @ `0x1074ec01c`、`AMapRSAEncryptor` @ `0x104d91ea4`、`BARRSA::encryptData:withKeyRef:isSign:` @ `0x10807480c`
- 包内另有 `public_key.der`；`config.nb`(211 KB) 为 Base64 编码的加密配置块（未在本次解密）。

## 5. 网络面（字符串层，observation）

自有服务：`api-jhcx-v6-bj.ninebot.com/v6`、`cnnx-omsgw.ninebot.com`、`cn-cbu-gateway.ninebot.com`、`account-bj/account-sg.ninebot.com`、`bj-cauth.ninebot.com`、`snssdk.ninebot.com`、`steeldust.ninebot.com`、`ebike.ninebot.com`、`h5-bj.ninebot.com`、`support-m.ninebot.com`、`z.ninebot.com`。
**发布包含测试/开发域名**：`api-jhcx-v6-dev-bj`、`api-jhcx-v6-test-bj`、`api-jhcx-v6-release-bj`、`api-jhcx-v6-debug-bj`、`cn-test3-oms-gateway`、`steeldust-test`、`account-test`、`test-cauth`、`api6-bj-pre-test`（来自 `Server.json` 与二进制内嵌字符串）。
第三方：`lbsnavi.cdn.bcebos.com`(249) `newclient.map.baidu.com`(63) `appnavi.baidu.com`(45) `api.map.baidu.com`(31) `m5.amap.com`(21) `mps.amap.com`(16) 等；`ce3e75d5.jpush.cn`（极光推送）。

## 6. 第三方 SDK 指纹（字符串计数）
百度地图/导航 (70) · 支付宝 (19) · 华为 HMS (15) · 高德 (6) · Bugly/Bugsnag (7) · 微信/QQ 开放平台 · 微博 · 字节 · Facebook · 小米 Passport · 极光推送。

## 7. 反调试 / 完整性检测迹象
字符串层面存在 `jailbreak`(9)、`cydia`(13)、`frida`(2)、`ptrace`(8) 等符号；未发现 `AntiFraud`/`SUDrmm` 类命名。仅“存在相关字符串”，**未逐一定位到具体检测函数并验证行为**（见未知项）。

## 8. 未知与局限
1. 关闭 `Decompiler Parameter ID` 后，未标注原型的函数参数类型较粗糙；对证据引用的函数已按需反编译验证。
2. Ghidra 的 varargs（`CCCrypt`、`objc_msgSend`）寄存器参数恢复不完整，本文对 CCCrypt 的判定依赖指令级读寄存器，已标注为 inferred。
3. `objc_stub` 49,985 条为 Ghidra 生成的 ObjC 消息桩，不代表真实函数。
4. 423,667 个函数无命名空间/无符号（含 C++ 内联、模板、Swift witness 等）。
5. React Native 业务逻辑的 JS bundle 未内嵌（包内无 `main.jsbundle`；仅 `AlipaySDK.bridge.js` 等桥接脚本），业务逻辑可能动态下发——本次未涉及。
6. `config.nb`、`string_release.zip`、`NEYDnn`(模型) 未展开分析。
7. 越狱/调试检测的实际启用情况、AES 密钥来源（`JCOREHttpSisRequest`/`JCOREConfigRequest` 的 `aesKey` 取值链路）未追踪完。

## 9. 继续分析（复用已建工程，无需重新导入）

```bash
G=/Users/mac11/Desktop/work/tools/ghidra_12.1.4
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home
export GHIDRA_HEADLESS_MAXMEM=9G
export JAVA_TOOL_OPTIONS="-Duser.home=/Users/mac11/Desktop/dsh/xx/ghome"
$G/support/analyzeHeadless /Users/mac11/Desktop/dsh/xx/ghidra_proj NinebotIPA \
  -process Ninebot -noanalysis \
  -scriptPath /Users/mac11/Desktop/dsh/xx/ghidra_scripts \
  -postScript DecompileSelected.java <输出目录> "关键字1|关键字2" 40
```
每次运行约 4–5 分钟（工程加载 + 反编译），不重复分析。
可用脚本：`DecompileSelected.java`（按名反编译）、`DumpQualified.java`（全量限定名）、`DumpInstr.java <start> <end>`（指令级）。
