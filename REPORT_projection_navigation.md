# 九号出行 6.10.9 — 投屏导航（Projection / Navigation Cast）逻辑分析

目标 `Payload/Ninebot.app/Ninebot`（SHA-256 `1302f193…0284b`，arm64）
方法：持久化 Ghidra 工程 `ghidra_proj/NinebotIPA`，按需反编译（本次新增 6 个批次、约 200 个函数，0 失败）。
证据目录：`analysis/videofactory`、`analysis/flow`、`analysis/enc`、`analysis/proj`、`analysis/cast`

---

## 0. 一句话结论

投屏导航**不是**把地图界面直接镜像出去，而是**手机端自己按车机型号渲染一套专用 HUD（转向/距离/路口放大图/红绿灯数/进度条），编码成 RTP 视频流，通过 UDP/KCP（默认 5012/5013）或 BLE 通道推送到车机屏幕**；控制面用 RTCP APP 包，含心跳与质量反馈。

## 1. 总控：`Vehicle.NBProjectionScreenManager`（投射屏管理器）

| 成员 | 地址 | 说明 |
|---|---|---|
| `setupResources(with: ConfigModel)` | `0x101e77b94` | 启动：拿到车机下发的 `ConfigModel` 后建资源 |
| `releaseResources()` | `0x101e77d10` | 停止并释放 |
| `videoGenerator` | `0x101e7ec84` | 持有 `VideoGenerator` |
| `videoUdpController` | `0x101e82d64` | 持有 UDP/RTP 控制器 |
| `naviInfo` / `navigationStatus` / `isBackground` | `0x101e771b8` / `0x101e77548` / `0x101e77290` | 导航状态与前后台 |
| `port` | `0x10038edfc` | `UInt16?`，默认 nil（运行时由车机给定） |
| `mapConfig` | `0x101063950` | `ConfigModel?` |

委托回调（发送门控与质量）：`videoGenerator:shouldSendRTPData:` `0x101e7fd5c`、`shouldSendRTCPData:` `0x101e7fddc`、`didRecievedHeartBeat:` `0x101e7f0e4`、`rtcpMeesageOnError:` `0x101e7fce8`、`modeChanged:` `0x101e7fe7c`。

调用关系（`analysis/callers.txt`）：`NBProjectionScreenManager::videoGenerator` → `VideoGenerator::startRecordVideo` @`0x1010c9268`；`VideoGenerator::videoManagerModeDidChanged` 也会重入 `startRecordVideo`。
模式入口：`NBMapModul::NBMapView::setNaviBroadcastMode(NaviBroadcastMode)` @`0x100c9bb80`；UI 为 `Vehicle::BroadcastModeView::clickAction:` @`0x101c01dc0`；百度侧有 `BNaviSettingVoiceModel::setHiddenNaviBroadcastMode:`。

## 2. 渲染：`NBVideoFactoryModule`（759 函数，投屏核心模块）

`NavigationViewBuilder`：`naviInfo`、`configuration`、`units`、`isBackground`、`containerView`，核心 `buildView(_:fatherView:userImage:)` @`0x1010a3260`。

按车机型号分套布局（每套独立 View）：
- 屏幕规格：`D1XTurnInfoView`、`D1X1TurnInfoView`、`D2XCombinedInfoView`、`F43TurnInfoView`/`F43CombinedInfoView`、`TwoFourInchesTurnInfoView`(2.4")、`FiveInchesTurnView`(5")
- 组件：`CombinedTurnInfoView`、`CombinedDistanceInfoView`、`NavigationProgressBarView`、`D2XProgressView`、`TrafficStatusBar`、`RoadLineSeperateView`、`CombinedMapInfoView`、`BackgroundInfoView`、`EasterEggsView`

投屏数据模型 `NavigationInfoModel` 字段（`analysis/videofactory/`）：`iconType`(0x100ac4ad8)、`crossImage`/`turnIconImage`(0x100ca11b0/0x100ca11f4)、`gpsSignal`(0x100b365d4)、`index`(0x100b36658)、`routeTrafficLightCount`(0x100ca112c)、`roadLine`、`speed`。

旁证：包内 `mode.bundle/mode_14/*.sty`（`navdaymapits`、`navnightviewallits`、`navipolockday`、`smallscreennav`、`navipoday` 等）即这套 HUD 的地图样式资源。

## 3. 编码：`VideoGenerator` + `NBVideoManager`

`VideoGenerator` 关键方法（`analysis/flow`）：
`startRecordVideo` `0x1010c9268` · `stopRecordVideo` `0x1010c9ac0` · `suspendRecordVideo` `0x1010c9c34` · `buildMapView` `0x1010c8cb4` · `removeAllViews` `0x1010c900c` · `createStartHeartBeatCommand` `0x1010ca59c` · `handleRTCP` `0x1010ca3f0` · `continueSendBleData` `0x1010ca434` · `videoBufferShouldSend` `0x1010cb3d0` · `rtcpBufferShouldSend` `0x1010cb588` · `clearRTPQueue`/`clearPFramesInQueue`。
编码回调：`videoManager:didGenerateVideoFrame:withEncoderType:`、`videoManagerFrameRateDidChanged:`、`videoManagerBitRateDidChanged:`、`videoManagerModeDidChanged:`、`videoManager:didRecievedHeartBeat:`。

`NBVideoConfiguration.defaultConfiguration` @`0x1010e4a10`（内联常量，**推断**为按属性声明顺序赋值）：

| 项 | 值 |
|---|---|
| frameRate | **25 fps**（0x19） |
| bitRate | **500,000 bps** |
| videoSize / originImageSize | **240 × 320**（0x406E…=240.0, 0x4074…=320.0） |
| packetSize | **1400 B**（0x578，RTP MTU） |
| gopSize | **10** |
| max_b_frame | **2** |

车机可覆盖（`ConfigModel`，`analysis/enc`）：`videoSize`/`targetSize`/`scaleSize`/`scale`/`codecType`/`maxBFrame`/`frameRate`/`bitRate`/`gopSize`/**`layout`**/`hearBeat`/`compressType`/`rtcpChannel`/`production`。`layout` 即上表机型布局选择依据。

## 4. 传输

**UDP/RTP 路径**：`VideoUDPController.rtpPort = 0x1394 (5012)`、`rtcpPort = 0x1395 (5013)`（`0x101063a68`/`0x101063a70`）。
底层可用 `KCPClient`/`KCPServer`（UDP 上 KCP 可靠层，`connect` `0x10108f57c`、`send` `0x101090100`、`close` `0x101090e98`）、`UDPSocketClient`、`TCPSocketServer/Client`。
KCP 参数结构 `KCPClientSettings`：`rx_minrto / fastresend / sndwnd / rcvwnd / nodelay / interval / resend / nc`（`0x10108e318`）。

**RTP 分帧**：`NBRTPHandler::createRTPBufferFrom:withPayload:RTPStandard:isFirst:isEnd:` @`0x1010e2a64`
→ `_rtp_packet_create/init/set_payload`；`isEnd` 置 marker 位（`|0x100`）；`RTPStandard == 2` 时置扩展位（`|0x8`）并创建视频专用扩展头（按帧类型映射 1/2/3）——即标准 2 为视频档。配套帧队列：`enqueueFrame:`、`dequeueFrame`、`clearPFrameInQueue`、`resetRTPIndex`。

**BLE 路径**：`NBBleSdk::BleManager::sendRtcpData` @`0x10097c288`（另有 `sendRtpData`、`registerRtcpNotification`）；`NBBluetoothModule::BleRTCPDataSend`（`$sendRTCPData` `0x1009c13d4`、`$sendLongData`、`$finalSend` `0x1009c20b0`，含 `peripheralIsReadyAction` 流控）、`BleRTPDataSend`、`VideoBleDataHandler::handleRTCPResponse` @`0x1009d5114`。

## 5. 控制面：RTCP APP

`NBRTCPHandler::createAppCommandBy:withValues:` @`0x1010e15c0`：`_rtcp_app_create/init` → 把 `values` 每个元素压成 int32 连续写入 `_rtcp_app_set_data` → `_rtcp_app_size/serialize` → NSData。`command == 6` 走另一分支（`createByeCommand` 相关）。
`NBRTPHandler`/`NBRTCPHandler::parse:` @`0x1010e1774` 为收包解析。

**心跳**：`VideoGenerator::createStartHeartBeatCommand()` @`0x1010ca59c` = `createAppCommandBy:`**5**`withValues:`**[0, 2]；配套 `maxHeartBeatLostTimes`（丢心跳上限）、`resetHeartBeatAttempts`。

## 6. 质量与降级

- 丢包率：字符串 `[丢包率统计] 未发送丢包率获取指令, reson: 非投屏导航或创建丢包指令失败`、`getPacketLostRate()`（`0x8ef05dc` 区段，NBDynamicModule/RN 侧），说明**仅投屏导航时**才拉取丢包统计。
- 自适应：`videoManagerFrameRateDidChanged` / `BitRateDidChanged` / `ModeChanged` 由编码器回调驱动重配。
- 后台：`BackgroundCheckable.startObserveBackgroundS…` @`0x10106295c`；`VideoGenerator.isBackground`/`isSuspend`。

## 7. 能力分级（推断）

二进制内成对出现的能力标记：`支持简易导航` 与 `支持投屏导航` / `支持导航设置` / `支持导航分享`（`0x8ef07d7` 区段）。
**推断**：低配车机走"简易导航"（纯文本 TBT，走 BLE/RTCP 应用命令），高配车机走"投屏导航"（HUD 视频流，走 UDP/KCP 5012）。该分级由固件能力位决定；本次未逐条定位到分支代码，标记为未知。

## 8. 未知与局限

1. `shouldSendRTPData`/`shouldSendRTCPData` 是薄包装（转调 `FUN_101e84034`/`FUN_101e84580`），门控策略未展开。
2. RTCP APP 命令号表仅确认 **5 = 心跳启动（参数 [0,2]）**；其余命令号（含 6）未穷举。
3. `NaviBroadcastMode` 枚举用例名由 `staticsName` 查表得到，未逐项解出（表地址 `0x1093cbfb8`）。
4. `KCPClientSettings` 实际调优值由调用方传入，未定位常量调用点。
5. BLE 与 UDP 的选择规则（推测按连接类型/能力位）未定位分支。
6. Swift async + CoreBluetooth 的伪代码高度抽象，`startRecordVideo`/`finalSend` 内部时序未能逐语句还原。
7. `0x1093cbfb8` 等 Swift 元数据/查表结构未解析；`objc_stub::FUN_*` 为 Ghidra 未解析的消息桩。

## 9. 可复现

工程已固化，任意函数可按需反编译（约 4–5 分钟/批，不重复分析）：

```bash
G=/Users/mac11/Desktop/work/tools/ghidra_12.1.4
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home
export GHIDRA_HEADLESS_MAXMEM=9G
export JAVA_TOOL_OPTIONS="-Duser.home=/Users/mac11/Desktop/dsh/xx/ghome"
$G/support/analyzeHeadless /Users/mac11/Desktop/dsh/xx/ghidra_proj NinebotIPA \
  -process Ninebot -noanalysis -scriptPath /Users/mac11/Desktop/dsh/xx/ghidra_scripts \
  -postScript DecompileSelected.java <out> "关键字|关键字2" 40
```
脚本：`DecompileSelected`（按名反编译）、`Callers`（找调用者）、`FindRefs`（串引用）、`DumpInstr`（指令级）、`DumpQualified`（全量限定名）。
