# `iot_ota/ota/get-last-firmware` 请求参数完整分析

> 目标 App：九号出行 cn.ninebot.segway 6.10.9（iOS arm64）
> 证据来源：真实 HAR 抓包、服务端下发配置、二进制静态检查、以及用自建客户端实测（HTTP 200 可解密）

---

## 0. 结论速览

这个接口的**地址和全部参数都不是 App 硬编码的**，而是由服务端配置下发。
静态检查证实：`get-last-firmware`、`download_type`、`tft_v`、`tft_pn`、`rTftV`、`rTftPN`
在 iOS 二进制中出现次数**全部为 0**。

因此"完整参数"的权威定义 = **服务端配置里的模板**，也就是本文第 3 节。

---

## 1. 三层封装结构

```
HTTP body
└── wire 层   {"d","h","k","p","t"}                       ← 实际抓到的 5 个字段
    └── d = AES-128-CBC(wrapper)
        └── wrapper  {"data","keyDataFour","keyDataOne",
                      "keyDataThree","keyDataTwo",
                      "platform","timeStamp"}
            └── data = AndroidB64(内层业务 JSON)          ← 业务参数在这里
```

### wire 层（实测）

| 字段 | 值 |
|---|---|
| `d` | Base64(AES-128-CBC(wrapper))，PKCS7，IV = 16×0x00 |
| `h` | `md5hex(wrapper)` 小写 |
| `k` | Base64(RSA-1024-PKCS1v15(AES 密钥))，恒定 128 字节 |
| `p` | `"101"` 常量 |
| `t` | `"0"` 常量 |

RSA 公钥（N1，真实生效的那把）：
```
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDT3m0c/8y9c13PzaFbATEg+Zwd
kpPcCy0V21VKBBSx16ckVtLERAQ7EH8d6DqgEbyzayAwlQd1gDhUmx27hDWafXr9
/evUZkkBegcsNnKrIlh93lPKccjk+LDXS1TnDIIFiTlSbNnaYwehI/9pUbKCI3h7
yE0pum6hJh/9QtGPlwIDAQAB
```
> 注：二进制里另有一把 `Ci0v4VEUhOdfIE...` 是死数据，无代码引用，用它会失败。

### wrapper（实测）

AES 密钥 = 16 字节随机可打印 ASCII。
响应密钥**不是**这把，而是 `DeriveKey(kd1,kd2,kd3,kd4)` 派生——所以服务端能回加密数据。

| 字段 | 值 |
|---|---|
| `data` | AndroidB64(内层业务 JSON)：标准 base64，每 76 字符插 `\n`，末尾恒 `\n` |
| `keyDataOne` | randHex(11) |
| `keyDataTwo` | randHex(11) |
| `keyDataThree` | randHex(10) |
| `keyDataFour` | 8 字符，取自 69 字符集 `a-zA-Z0-9;-_.,+/` |
| `platform` | 业务域用 `2` |
| `timeStamp` | Unix **秒**（业务域） |

---

## 2. 内层业务 JSON = 该接口的全部业务参数

### 2.1 顶层字段

| 字段 | 类型 | 值 / 来源 |
|---|---|---|
| `uid` | string | 账号 uid（登录态） |
| `wnumber` | string | 整车序列号 |
| `env_type` | string | 固定 `"1"` |
| `download_type` | string | 固定 `"2"` |
| `parts` | array | 部件数组，见 2.2 |

### 2.2 `parts[]` 完整部件清单

每个元素结构：`{"part_type":…, "version":…, "pn":…}`（`BFG` 无 `pn`）

| part_type | version 变量 | pn 变量 |
|---|---|---|
| MCU | `$mcu_v` | `$mcu_pn` |
| BFG | `$bfg_v` | — |
| ABS-F | `$absf_v` | `$absf_pn` |
| ABS-R | `$absr_v` | `$absr_pn` |
| CHG | `$chg_v` | `$chg_pn` |
| HEP | `$hep_v` | `$hep_pn` |
| LIGHT | `$bep_v` | `$bep_pn` |
| ECU | `$ecu_v` | `$ecu_pn` |
| BMS1 / BMS2 / BMS3 | `$bms1_v` … | `$bms*_pn` |
| DIS | `$dis_v` | `$dis_pn` |
| **TFT** | **`$tft_v`** | **`$tft_pn`** |
| BMS-BLE1/2/3 | `$bmsBle*_v` | `$bmsBle*_pn` |
| BLE | `$bt100_ble_v` | `$bt100_ble_pn` |
| FL-APL | `$flapl_v` | `$flapl_pn` |

### 2.3 示例（TFT 单项，最小可用形态）

```json
{"uid":"541117341","wnumber":"3ZDCK2619J3650","env_type":"1","download_type":"2",
 "parts":[{"part_type":"TFT","version":"<tft_v>","pn":"<tft_pn>"}]}
```

---

## 3. 每个 `$变量` 的真实来源

变量值由配置里的**采集规则**决定，结构为：

```json
{"command":"<BLE 读命令>", "cache_key":"<变量名>", "transform":{"parse":"toInt|toPn","0","<长度>"}}
```

| 环节 | 说明 |
|---|---|
| `command` | 通过 BLE 向车机发一条读命令，例如读 TFT 版本/料号 |
| `cache_key` | 结果以 `tft_v` / `tft_pn` 之类的键缓存，供请求模板替换 `$tft_v` |
| `transform` | `toInt,0,2` = 取前 2 字节转整数；`toPn,0,14` = 取前 14 字节转料号字符串 |

读取是**批量轮询**的（一次下发 13 条 `period:0` 命令，之后周期性续读），
所以值会在内存里累积缓存。

> **重要**：以上命令名、cache_key 名在 iOS 二进制中均为 0 次命中，
> 说明整套采集规则都是运行时从服务端下载的。因此无法从二进制静态枚举，
> 只能从服务端配置或运行时内存获得。

---

## 4. 完整请求头（HAR 实测，25 个）

```
POST /iot_ota/ota/get-last-firmware   HTTP/1.1
Host: steeldust.ninebot.com
Language: zh
Client-Ver: 610093816
User-Agent: Ninebot/6.10.9 (cn.ninebot.segway; build:3816; iOS 27.0.1) Alamofire/5.10.2
MID: 541117341
Uid: 541117341
Cookie: install_id=…; ttreq=1$…
NET-Version: 1.0.13
Service-Time: <13 位毫秒时间戳>
Request-Id: <32 位十六进制>
Business-Type: 1
Device-Id: <UUID 大写>
Sys-Language: zh-hans-cn
Platform: iOS
Ninebot-Version: 2
Platform-Ver: 27.0.1
Accept-Language: zh-Hans-CN;q=1.0
Login-Country: CN
Access-Token: <JWT，RS256>
Accept: application/json
Content-Type: text/html            ← 伪装，实际是加密二进制
App-Version: 610093816
Accept-Encoding: br;q=1.0, gzip;q=0.9, deflate;q=0.8
Regionx: bj
```

---

## 5. 响应结构

```json
{"v":101, "s":"<base64 128B>", "r":"<base64 AES 密文>"}
```

- `r`：AES-128-CBC 密文，key = `DeriveKey(kd1..kd4)`，IV = 0
- 解出的是 wrapper，业务数据在 `data` 里（再 AndroidB64 解一层）
- `s`：128 字节 RSA 块（签名），业务上未参与解密

---

## 6. 实测状态

| 项目 | 状态 |
|---|---|
| wire 层封装 | ✅ 实测 HTTP 200 |
| AES-128-CBC + IV=0 + PKCS7 | ✅ 实测 |
| RSA 公钥 N1 | ✅ 实测 |
| 响应 `DeriveKey` 解密 | ✅ 实测，成功解出业务 JSON |
| 重放 App 原始请求 | ✅ HTTP 200（证明头/token/host 全对） |
| 自建请求带业务参数 | ⚠️ HTTP 200 但业务码 `190001 / 4104` |

### 4104 的含义（实测推断）

- 不带公共参数 → `340000 / 4103`
- 带公共参数 → `190001 / 4104`
- 换成 Android 风格头、换部件、换 platform、换时间戳单位 → 恒为 4104
- 车辆列表等**其他业务接口**同样是 4104

→ 4104 是**业务层参数校验未通过**的通用码，与封装无关。
Go 侧客户端把内层 JSON 按 **struct 字段序**序列化并据此算 `checkcode`
（`checkcode = MD5(无 checkcode 的紧凑 JSON).upper()`）。
字段序不一致时服务端重算的 checkcode 与请求不符即被拒。

---

## 7. 工具与用法

| 文件 | 用途 |
|---|---|
| `scripts/ninebot_crypto.py` | wire 层完整实现（AES/RSA/wrapper/DeriveKey） |
| `scripts/ota_wire.py` | 构造并发送 OTA 请求，自动解密响应 |

```bash
python3 scripts/ota_wire.py \
  --token '<Access-Token>' --uid 541117341 --wnumber 3ZDCK2619J3650 \
  --with-common --part TFT --version 0
```

---

## 8. 剩余阻塞

要把请求做到能被服务端接受，必须满足其一：

1. **内层 JSON 的字段顺序与 checkcode 规则完全一致** —— 需要一份真实的内层明文
2. **`parts[]` 提供真实 version/pn** —— 值只在车机 BLE 或 App 内存里

两者都需要"看到 App 那次请求的明文"。已尝试的运行时抓取：
- `aes256EncryptData:withKey:iv:` 钩子 → 不触发（App 用 128 位版本）
- `aesEncryptData:withKey:iv:` / `gzip:` 钩子 → App 启动即闪退
- `NSUserDefaults` + 沙盒文件只读扫描 → 未命中（缓存只在内存）

**零风险可行解**：App 内 `Documents/NetLog/` 若存在，可直接读；或等有车时用 BLE 读真实值。

---

# 附录 A：真实内层明文（安卓客户端实测解密，2026-10-31）

```json
{
  "uid": "541117341",
  "wnumber": "3ZDCK2619J3650",
  "env_type": "1",
  "download_type": "2",
  "parts": [ {"part_type":"MCU"}, {"part_type":"BFG"}, ... {"part_type":"TFT"}, ... ],
  "download": "0",
  "access_token": "<JWT>",
  "sys_language": "zh-hans-cn",
  "client_ver": "610124167",
  "device_id": "<32位hex>",
  "regionx": "bj",
  "language": "zh",
  "ostype": "and",
  "lang": "zh",
  "platform_ver": "14 Google_Pixel 5",
  "platform": "android",
  "login_country": "CN",
  "serviceTime": 1793435504671,
  "nonce": "0b02EDD3D247FAD0725D4330C90EDB34",
  "checkcode": "D6D4A4B61924AEF588B9FA349548769F"
}
```

## 关键修正（相对第 2 节）

| 项 | 之前认为 | 实际 |
|---|---|---|
| `parts[]` 内容 | 每个都带 version + pn | **只带 `part_type`**；版本未知时 version/pn 字段整体不出现 |
| 内层是否有 access_token | 无 | **有**，放在 body 里（这是 4104 的根因） |
| 额外字段 | 无 | `download` / `serviceTime` / `nonce` / `checkcode` |
| 公共参数 | 猜测 | `sys_language, client_ver, device_id, regionx, language, ostype, lang, platform_ver, platform, login_country` |

`checkcode = MD5(不含 checkcode 的紧凑 JSON).upper()`
`nonce` = 32 位十六进制，首字节小写、其余大写

## 实测结果（全部 code=1 success）

| 改动 | 结果 |
|---|---|
| `parts[TFT].version = "0"` | `code=1`，`parts_version: []` |
| `version = 0`（数字） | 同上 |
| `version = "1" / "999" / "65535" / "0000"` | 同上 |
| 全部 18 个部件都上报 `version` | 同上 |
| `download_type = 0 / 1 / 3`、`env_type = 2`、`download = 0/1` | 同上 |
| `version = "1.0.0"`（非纯数字） | `code=500001` 报错 |

**结论：请求已完全打通（HTTP 200 + 解密成功 + `code=1`），但 `parts_version` 恒为空。
服务端判定"是否有更新"不依据客户端上报的 version，而是依据自身记录的车辆部件信息。
该车当前确实没有可用固件更新（与 App 显示"已是最新"一致）。**

响应的完整字段：
```json
{"parts_version":[], "show_kart_tip":false, "special_version_status":false,
 "forced_status":false, "forced_content":"", "blue_ota_support":1}
```
有更新时，新版本信息与下载地址应出现在 `parts_version[]` 中。
