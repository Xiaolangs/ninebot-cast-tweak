# ProjectionOverride — 九号出行投屏画面整帧替换

目标：`cn.ninebot.segway` 6.10.9 投屏导航画面（① 层拦截）
方式：自签侧载 + dylib 注入（无需越狱、无需 Substrate）

## 1. 拦截点（来自本次 Ghidra 分析）

| 符号 | 地址(本版本) | 作用 |
|---|---|---|
| `-[NBPixelBufferConverter pixelBufferFromCGImage:]` | `0x1010e0bfc` | App 把渲染好的 CGImage → CVPixelBuffer（32BGRA）交编码器。**主拦截点** |
| `-[NBPixelBufferConverter pixelBufferFromCGImage_Mjpeg:]` | `0x1010e0dd0` | MJPEG 备用编码路径（BLE 场景） |
| `-[NBVideoManager recordVideo:stopAfter:]` | `0x1010e4d90` | 投屏开始 → 置 `casting=YES`（门控） |
| `-[NBVideoManager stop]` | `0x1010e57ec` | 投屏结束 → 置 `casting=NO` |

代码**只用类名+选择器**定位，不写死地址，App 升级后仍然有效。
未命中时的退路：`-[NBVideoManager imageVideoEncoder:didEncodedImage:]`（编码后，需自产码流）。

## 2. 构建

需要 **Xcode（含 iOS SDK）**；只有 Command Line Tools 时先安装 Xcode：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
./build.sh          # 产出 ProjectionOverride.dylib
```
（本机已用 macOS SDK 校验过语法与 API：0 error。`CGContextSelectFont` 等已废弃 API 已换成 CoreText。）

## 3. 注入（自签侧载，三选一）

**A. Sideloadly（最省事）**：把 `ProjectionOverride.dylib` 拖到 Sideloadly 的 Tweak 列表，选 IPA → 你的 Apple ID → Start。它自动完成 LC_LOAD_DYLIB 注入、重签、安装。

**B. Azule / TrollFools(侧载模式)**：同样支持 dylib 注入 + 重签。

**C. 手工**：
```bash
unzip -q Ninebot.ipa -d work && cd work
cp ../ProjectionOverride.dylib Payload/Ninebot.app/Frameworks/
# 1) 加加载指令
optool install -c load \
  -p "@executable_path/Frameworks/ProjectionOverride.dylib" \
  -t Payload/Ninebot.app/Ninebot
# 2) dylib 与主程序必须用同一证书签名（否则 dyld 拒绝加载）
codesign -f -s "Apple Development: you@example.com" Payload/Ninebot.app/Frameworks/ProjectionOverride.dylib
codesign -f -s "Apple Development: you@example.com" \
  --entitlements <原entitlements>.plist Payload/Ninebot.app
zip -qr ../Ninebot_patched.ipa Payload
```

> **签名一致性是硬要求**：主程序与 dylib 证书不同 → 加载失败（code signature invalid / different team）。
> 重签前先用 `codesign -d --entitlements :- Payload/Ninebot.app` 导出原始 entitlements 并原样复用，否则可能丢 BLE 后台、推送、网络相关能力。

## 4. 验证

- 日志：`log stream --predicate 'subsystem == "com.rev.projectionoverride"'`，应看到
  `hooked NBPixelBufferConverter -pixelBufferFromCGImage:` 与 `recordVideo: start (casting=YES)`。
- 灰度开关：`NSUserDefaults` 写 `NBProjectionOverride = NO` 即刻恢复原生画面（便于 A/B）。
- 若 hook 日志出现、但画面未变 → 说明该机型走的是 MJPEG 或另一条渲染路径，检查 `_Mjpeg` 的 hook 日志与 `didEncodedImage:` 退路。

## 5. 限制与风险

1. **必须仍是合法码流**：替换的是编码器**输入**，输出仍由 App 的 H.264/MJPEG 编码，车机只解码。
2. **尺寸必须匹配**：代码用传入 CGImage 的真实尺寸绘制，因此 D1X/D2X/F43/2.4"/5" 各机型自动适配；切勿硬编码分辨率（默认 240×320，车机可通过 `ConfigModel` 覆盖 `targetSize`）。
3. **性能**：回调在投屏线程上以 25fps 触发。静态内容请预渲染并缓存（本代码已缓存 250ms），重活不要放主线程。
4. **心跳**：控制面是 RTCP APP（`command 5 + [0,2]`），丢心跳超限会主动停投；hook 内不要阻塞。
5. **BLE 带宽**：BLE 路径仅适合极简画面；常规投屏走 UDP/KCP `5012/5013`。
6. **7 天证书**：免费 Apple ID 签名的 App 每 7 天需重签；App 若强依赖推送/App Attest，重签后可能登录异常——投屏本身是本地链路，不受影响。
7. **反篡改未验证**：二进制含 `jailbreak/cydia/frida/ptrace` 字符串，但未定位到具体检测函数，也未确认投屏是否被门控；若出现异常退出，优先排查此处。
8. 该 IPA 为 **thin arm64**，无 arm64e 切片；设备为 arm64e 时 ObjC 方法替换不受 PAC 影响。

## 6. 下一步可做

- 把 `RenderFrame()` 换成真实内容：可复用 App 自己的 HUD 数据（`NavigationInfoModel` 的 `iconType/turnIconImage/crossImage/gpsSignal/routeTrafficLightCount`），只替换你要改的元素。
- 需要"保留 App 布局、只改某一元素"时改走 ④ 层 `NavigationViewBuilder buildView(_:fatherView:userImage:)` @`0x1010a3260`（Swift，需按 mangled 名或基址+偏移 hook）。
