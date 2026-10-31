# 九号出行 6.10.9 — 主题功能分析

目标 `Payload/Ninebot.app/Ninebot`（SHA-256 `1302f193…0284b`）
方法：持久化 Ghidra 工程 `ghidra_proj/NinebotIPA` + `analysis/qualified.tsv`（676,540 函数）+ 字符串库；本轮新增反编译 40 函数（`analysis/theme/`）

---

## 0. 结论先行

App 里 **不是一套主题，而是三套并存、互不相干**：

| # | 体系 | 作用域 | 核心 |
|---|---|---|---|
| **A** | **App 主题**（`NBThemeKit`） | App 全局配色/图片/深浅色 | key→资源解析 + 跟随系统 |
| **B** | **车机仪表皮肤**（Device/Dashboard Skin） | 车型详情页仪表盘动效 | 服务端下发资源包 + **VAP 动画** |
| C | 第三方主题（百度/高德/BMINS/ZLPhoto/RN） | 各自 SDK 内部 | 与 A/B 无关 |

改主题相关的东西，先要确认改的是哪一套——这是最容易踩的坑。

---

## 1. 体系 A：App 主题（NBThemeKit）

### 架构：key → 资源的动态解析

| 组件 | 地址 | 作用 |
|---|---|---|
| `NBThemeSpace.dynamicKey` | `0x100d56c2c` | 取某控件对应的主题 key |
| `NBThemeSpace.themeValueString` | `0x100d56d78` | key → 字符串值（颜色/尺寸） |
| `NBThemeSpace.filePath` | `0x100d56d84` | key → 资源文件路径 |
| `NBThemeSpace.dynamicBlock` | `0x100d568d0` | 动态取值回调 |
| `UIColor.dy` / `UIImage.dy` | `0x100d561f0` / `0x100d564c4` | 取"动态"颜色/图片（随主题变） |
| `UIView.themeChangeBlock` | `0x100d56ac4` | 单个视图的主题变更回调 |

### 管理器 `NBThemeManager`

| 能力 | 地址 |
|---|---|
| `currentTheme` / `currentThemePath` | `0x100d572b4` / `0x100d574c8` |
| `isDarkStyle` | `0x100d57244` |
| `isFollowSystem` / `setupFollowStyle` | `0x100d57914` / `0x100d58934` |
| `setupThemeConfig` | `0x100d5807c` |
| `setTheme` / `reload` | `0x100d58544` / `0x100d58548` |
| `themeChangeAndReloadMsg` | `0x100d58700` |
| `lastStyle` | `0x100d57fb8` |

**要点**：主题是「资源包 + key 表」，不是编译期硬编码。切换时通过 `reload` + `themeChangeBlock` 刷新所有已注册视图。

### 资源组织

包内 `theme.json`（947 B）只做一件事：**tab 栏的明暗配置映射**

```json
"robot":    { "normal": "tab_robot.json",       "dark": "tab_robot_dark.json" },
"tracking": { "normal": "tab_tracking.json",    "dark": "tab_tracking.json" }
```

`tab_*.json` 共 12 个（含 `_dark` 变体），另有 `v_country_mutil_c(n).json` 做国家/地区差异。

### 业务入口与开关

- `Common.ThemeEntranceListItem.themeShow` `0x1000b4c9c` / `vipShow` `0x1000b4ca4` —— 主题入口，**带 VIP 判定**
- `Common.NewDeviceNavBarFlagManager`：`isSupportTheme` `0x10042f090`、`systemSkinShow` `0x10042f54c`、`onlySystemSkinShow` `0x10042f454`、`requestThemeAndMemberSwitchStatus` `0x10042f904` —— 车机是否支持主题、是否只显示系统皮肤、会员开关状态（服务端下发）
- 通知：`appSkinUpdateSuccess`、`notifyUpdateThemeAppResource`、`switchThemeSubTab`

---

## 2. 体系 B：车机仪表皮肤（重点）

### 数据链路

```
服务端 /app-api/theme/resource/v2/device/resources
      │  DeviceSkinResourcePoolData { randomAppResource, resourceList }
      ▼
ThemeSkinResourcesDownload（并发下载器：stateQueue / maxConcurrentCount / pendingResources）
      ▼
资源池 ThemeSkinResourcePool（目录 ThemeSkinResource/，缓存 currentTheme）
      ▼
QGVAPlayer 播放（VAP 动画）+ QGVAPConfigManager / QGVAPCommonInfo / QGVAPMaskInfo
      ▼
车型详情页快捷区：MotorDetailShortCutsCell / ScooterDetailShortCutsCell /
                 EbikeDetailShortCutsCell / UlockDetailShortCutsCell（clearSkinResourceBlock 释放）
```

### 服务端接口（从字符串提取）

| 路径 | 用途推断 |
|---|---|
| `/app-api/theme/resource/v2/device/resources` | 拉取设备皮肤资源列表 |
| `/app-api/theme/v1/batch-show-config` | 批量展示配置 |
| `/app-api/theme/v1/get-new-version` | 版本号（判断是否需更新） |
| `/app-api/theme/v1/cancel-reddot` | 取消红点 |
| `/app-api/theme/v1/get-app-front-common-config` | 通用前置配置 |
| `/app-api/offline-activity/theme/v1/list` | 活动主题列表 |

### 关键类型（源码路径已泄漏，便于对照）

```
Vehicle/Other/ThemeSkinResourcesDownload.swift
Vehicle/Other/ThemeSkinResourcePoolTool.swift
Vehicle/Dynamic/Common/DashboardSkinContainer
NBBaseUIKit/Classes/DynamicUI/dashboard/SkinInfoCardCell
```

- `DeviceSkinResourcePool` / `DeviceSkinResourcePoolApi` / `DeviceSkinResourcePoolData`
- `ThemeSkinResourcePool` / `ThemeSkinResourcePoolTool` / `ThemeSkinResourcesDownload`
- `ThemeSkinResource{Progress, Result, Error, Failure, PlayMode}`
- `DashSkinData { resourceCode, resourceName }`、`DashSkinInfo`、`DashboardSkinProtocol`、`DashboardSkinContainer.CodingKeys`（Codable，传给 RN 侧）
- `MotorDetailContainerV2.lastPlayThemeSkinResourcePoolTimestamp` `0x100b392b0` —— 上次播放时间戳（避免重复播放/做节流）
- `DashboardSkinContainer.update` `0x100a7d2f8` / `initView` `0x100a7d5b8` / `handlefileRetrieveData` `0x101c4bb74`
- `SkinInfoCardCell.setup` `0x1009244b4` / `changeButtonAction` `0x100924bbc`（"更换"按钮 → 换肤）

### 能力位与商业模式

`NewDeviceNavBarFlagManager` 的三个开关说明这是一套**按车型/会员分级**的功能：
`isSupportTheme`（该车机是否支持）、`systemSkinShow`（是否展示系统皮肤）、`onlySystemSkinShow`（只允许系统皮肤，即第三方皮肤不可用），配合 `ThemeEntranceListItem.vipShow` 做 VIP 门槛。

---

## 3. 体系 C：第三方主题（与 A/B 无关）

- `BNTheme`(62) / `BNThemeKit` / `BNThemeView` / `BNPNThemeConfig` / `BNAutoThemeDelegate` —— 百度导航主题
- `BMINSThemeManager`(37) / `BMINSThemeColorManager` / `BMINSThemeStatus*` —— 百度 INS 导航
- `AMapNaviCompositeThemeConfig`(47) —— 高德导航主题
- `ZLPhotoBrowser.ZLPhotoThemeColorDeploy`(77) —— 相册组件
- `RCTAppearance`(14) —— React Native 的深浅色事件桥接

导航 SDK 的主题（日/夜地图样式）走各自的 `themeWillChange:` 回调，与 App 主题独立。

---

## 4. 可以直接上手的观察点

| 想做什么 | 入口 |
|---|---|
| 看当前 App 主题与路径 | `NBThemeManager.currentThemePath` `0x100d574c8` |
| 强制某个主题 | `NBThemeManager.setTheme` `0x100d58544` + `reload` `0x100d58548` |
| 跟随系统开关 | `isFollowSystem` setter `0x100d57a9c` |
| 车机皮肤能力 | `NewDeviceNavBarFlagManager.isSupportTheme` `0x10042f090` |
| 皮肤下载/播放 | `ThemeSkinResourcesDownload`、`ThemeSkinResourcePool`、`QGVAPlayer` |

---

## 5. 未知与局限

1. `DeviceSkinResourcePool*` / `ThemeSkinResource*` 是 Swift 结构体/枚举，无 ObjC 符号，**未逐函数反编译**；下载器的并发与失败重试细节未展开。
2. `DashSkinData/DashSkinInfo` 的完整 JSON 契约只解出 `resourceCode` / `resourceName`（Codable 的 CodingKeys 存在元数据里，未全量提取）。
3. `ThemeSkinResource/` 的具体沙盒落盘位置（Library 还是 Documents 子目录）未确认。
4. 皮肤资源包内部格式（zip 内是 `.vap` + 配置 json 还是 mp4）未验证——只有 VAP 播放器存在这一强证据。
5. 服务端返回的字段与错误码未观测（需要抓包）。
6. `systemSkinShow` / `onlySystemSkinShow` 的服务端判定条件未知。

---

## 6. 复现

```bash
G=/Users/mac11/Desktop/work/tools/ghidra_12.1.4
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home
export GHIDRA_HEADLESS_MAXMEM=9G
export JAVA_TOOL_OPTIONS="-Duser.home=/Users/mac11/Desktop/dsh/xx/ghome"
$G/support/analyzeHeadless /Users/mac11/Desktop/dsh/xx/ghidra_proj NinebotIPA \
  -process Ninebot -noanalysis -scriptPath /Users/mac11/Desktop/dsh/xx/ghidra_scripts \
  -postScript DecompileSelected.java <out> "关键字" 40
```

---

# 附录：体系 B 的资源包格式与落盘（2026-10-31 补充）

依据：二进制内 `[ThemeSkinResourcePool]` 附近的**中文日志字面量**（偏移 `0x8eeb2a0` 起）——这些日志把整条流程写得很完整，比反编译更直白。

## B.1 格式结论：是 mp4，不是 .vap 文件

| 证据 | 说明 |
|---|---|
| `[ThemeSkinResourcePool] 资源包没有mp4动效` | 包内**必须有 mp4 动效**，缺失时只降级为静态背景 |
| `QGVAPlayer --- [ThemeSkinResourcePool] 已删除解压目录` / `已删除 zip 文件` | 下载物是 **zip**，解压后使用，用完**删 zip 和解压目录** |
| `SSZipArchive`(33) / `unzipFile`(32) / `ZipArchive`(89) | 解压用 SSZipArchive |
| `vapc` box、`shouldStartPlayMP4:config:`、`onGetYUVAPlanes` | QGVAPlayer 播的是**带 alpha 的 mp4**（VAP 容器） |
| `.vap` 仅出现 2 次，且都在 `com.qgame.vap.*` 域名里 | `.vap` **不是**皮肤文件扩展名，只是播放器标识 |

**结论**：皮肤包 = **zip（服务端下发）→ 解压 → 目录内含 `<x>.mp4`（VAP 动效）+ 背景图片**；播放走 QGVAPlayer。

## B.2 从日志还原的状态机

```
请求皮肤资源接口
  └ downloadUrl 接口 → 接口返回失败 code: / download resources count=
      └ ❌ [DeviceResource] 过滤下载链接 nbchecksignv1 参数后 为空   ← 下载 URL 含签名参数，需先剥离/处理
      └ ✅ [DeviceResource] 主题皮肤获取本地加密资源成功            ← 本地资源是加密的
          └ 下载 → ❌ [ThemeSkinResourcePool] 写入 zip 文件失败 path=
          └ 解压（SSZipArchive）→ 检查资源包是否有 mp4 动效
              └ 无 mp4 → "[ThemeSkinResourcePool] 资源包没有mp4动效"（降级静态背景）
          └ [ThemeSkinResourcePool] 已缓存资源 key=
              └ QGVAPlayer 播放；播放后 "已删除解压目录" + "已删除 zip 文件"

播放期缓存逻辑：
  pool 缓存未命中 key=            ← 未命中
  pool 缓存存在，但没有可播放的本地资源 key=
  命中本地主题，准备播放 playMode=   ← ThemeSkinResourcePlayMode
  500ms 内重复触发，忽略本次播放      ← 500ms 节流
  本地缓存与接口完全一致，跳过缓存更新和下载
  已缓存资源池 key=
  刷新current时，resource为空，
  [ThemeSkinResourcePool] 未找到 DetailViewController，无法设置背景
  [ThemeSkinResourcePool] 背景图片加载失败 path=
```

## B.3 签名与完整性

```
nbchecksignv1=:                        ← 下载/资源签名参数
resouce sign invalid
开始校验图片数据:  → 校验图片数据: Sign值校验不通过: / 校验通过
```
资源带签名校验，走图片/资源校验通道；下载链接中的 `nbchecksignv1` 参数会被**过滤**后处理。这意味着**外部替换皮肤资源需要过签名校验**，是自制皮肤包的主要门槛。

## B.4 落盘位置

- 目录名为 `ThemeSkinResource/`（二进制中是独立字面量，出现 2 次）
- 池对象 `ThemeSkinResourcePool`（`_TtC7Vehicle25ThemeSkinResourcePoolTool`）
- **父目录（Caches 还是 Documents）静态无法确定**——二进制里没有拼出完整路径的字符串，属于运行时用 `FileManager` 组装

需要在真机确认，两种办法：
1. 打开「车型详情页」触发一次皮肤下载后，遍历 App 沙盒找 `ThemeSkinResource` 目录
2. 用我们的 dylib 打一行日志（约 5 行代码），输出 `cachesDirectory`/`documentsDirectory` 下该目录的绝对路径与文件清单

## B.5 附带发现：内置仪表动画（非下载）

`dash_bg_dark.mp4`、`dash_speed_change.mp4`、`dash_nitrogen_change.mp4`、`nitrogen_change_dark.mp4`、`sh_speed_change_dark.mp4`、`validationVideo.mp4(_dark)`

配套类：`_TtC7Vehicle18VehicleDashboardVC`（仪表页）、`_TtC7Vehicle18DashboardBGVideoVC`（背景视频，`avPlayerItem` + `observerThemView`）

→ **仪表页背景是内置 mp4 播放**，与云端皮肤包是两套机制。`_dark` 后缀说明背景视频也跟随深浅色主题。

## B.6 仍未确定

1. 皮肤包内 mp4 的**具体命名规则**（`%@/%@.mp4` 这个名字格式串属于相册/视频缓存，不能直接套用到皮肤包）
2. 解压目录结构（是否按 `resourceCode` 分层）
3. `ThemeSkinResourcePlayMode` 的枚举取值（一次性/循环/预览）
4. 服务端返回的 `resourceList` 字段全集（只解出 `resourceCode` / `resourceName`）

---

# 附录 B：主题/皮肤云端接口实测（2026-10-31）

加密通道打通后，用自建客户端实测得到的**可用/不可用**清单。

## 网关地址

| 用途 | 主机 |
|---|---|
| **主题/皮肤** | `cn-cbu-gateway.ninebot.com` ← 关键发现 |
| 固件 OTA | `steeldust.ninebot.com` |
| 业务（行程等） | `api-jhcx-v6-bj.ninebot.com` |

## 已实测可用（code=1）

| 路径 | 返回 |
|---|---|
| `/app-api/theme/v1/get-new-version` | `{"showRedDot":0}` |
| `/app-api/theme/v1/get-app-front-common-config` | `{"bannerHeight":320,"bannerWidth":286,"bannerScale":2}` |
| `/app-api/theme/v1/batch-show-config` | `{"showEntranceList":[]}` |
| `/app-api/theme/v1/cancel-reddot` | 成功 |

## 已注册但参数未解（code=500001 服务异常）

| 路径 | 说明 |
|---|---|
| `/app-api/theme/resource/v2/device/resources` | **皮肤资源列表（核心）** |
| `/app-api/device/resource/v1/device/resource` | 设备资源 |

已试参数组合：`resourceCode`(字符串/数组/空)、`resourceVersion`(字符串/对象)、
`resourceType`、`vehicleType`、`page/size`、`Business-Type` 0/1/5、`Rn-*` 头、GET 方法 —— 均 500001。

## 皮肤模块的静态结构（Swift）

| 类 | 职责 |
|---|---|
| `ThemeSkinResourcePoolTool` | 皮肤资源池 |
| `ThemeSkinResourcesDownload` | 皮肤下载器 |
| `DashboardSkinContainer` | 仪表皮肤容器 |
| `SyncShopResourceContainer` | 商店资源同步 |
| `ResourceDownloadInterceptor` | 下载拦截 |
| `VideoResourceTool` | 视频资源（对应加密 mp4） |

数据模型 `NBDynamicModule.DashSkinData` 字段：
`resourceCode`、`resourceName`

相关字段（Swift 元数据）：
`resourceVersion`、`resourceType`、`needReboot`、`support5ab5`、
`skinEncString`（← 加密后的皮肤串）、`downloadStatus`、`bgAnimation`

> `skinEncString` 印证了此前结论：皮肤资源是**加密串**，需解密后才能下载/渲染。

## 下一步

`/app-api/theme/resource/v2/device/resources` 的正确参数组合仍未解出。
建议在有真实抓包（App 内点开皮肤商店/切换皮肤）时对照，或在 App 内 hook
`ThemeSkinResourcesDownload` 的请求构造，直接拿到参数名与取值。
