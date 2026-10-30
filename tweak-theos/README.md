# ProjectionOverride — Theos (Logos) 版

九号出行(cn.ninebot.segway) 投屏导航「整帧替换」dylib。
拦截 `-[NBPixelBufferConverter pixelBufferFromCGImage:]`（App 渲染帧 → 编码器输入端），
**自签侧载可直接注入，不需要越狱、不需要 CydiaSubstrate。**

## 1. 工程结构

```
tweak-theos/
├── Makefile              # TARGET/ARCHS/FRAMEWORKS
├── control               # dpkg 元数据（打包时才用得到）
├── Tweak.x               # Logos 源码（%hook / %orig / %ctor）
├── substrate_shim.m      # 关键：自己实现 MSHookMessageEx，免越狱
├── include/substrate.h   # 最小 substrate 头，编译期用
└── Tweak.mm              # logos.pl 生成物（验证用，不参与编译）
```

## 2. 环境准备

```bash
export THEOS=/path/to/theos          # 本机验证用的是 theos 官方仓库 + theos/logos
```
需要 **Xcode + iOS SDK**（Theos 的 `iphone:clang` 工具链依赖）。只有 Command Line Tools 时，
`xcrun --sdk iphoneos --show-sdk-path` 会失败，必须先装 Xcode：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 3. 编译

```bash
cd tweak-theos
make            # 只出 dylib，不打包 deb
```
产物位置（Theos 版本不同二选一）：
- `.theos/obj/arm64/ProjectionOverride.dylib`
- `.theos/obj/ProjectionOverride.dylib`

`install_name` 已固定为 `@executable_path/ProjectionOverride.dylib`，所以也可以直接放在主程序同目录。

## 4. 免越狱原理（重要）

Logos 的 `%hook` 会被编译成对 `MSHookMessageEx()` 的调用。越狱设备上这个符号由
CydiaSubstrate/ellekit 提供；**侧载的重签 App 里没有 substrate**，直接加载会报
`symbol not found: _MSHookMessageEx`。

本工程用 `substrate_shim.m` **自己实现** `MSHookMessageEx`（内部就是
`class_getInstanceMethod` + `method_setImplementation`），因此：

- 不链接 `-lsubstrate`；
- 无越狱依赖，侧载注入即可运行；
- 已实测：产物中 `_MSHookMessageEx` 为**已定义符号(T)**，未定义符号里 substrate 相关命中数 **0**。

副作用：`%hookf`（hook C 函数）**不可用**，本工程也未使用；只 hook ObjC 方法。

## 5. 注入（自签侧载）

```bash
cp .theos/obj/arm64/ProjectionOverride.dylib Payload/Ninebot.app/Frameworks/
optool install -c load -p "@executable_path/Frameworks/ProjectionOverride.dylib" \
       -t Payload/Ninebot.app/Ninebot
# dylib 与主程序必须同一证书签名
codesign -f -s "Apple Development: you@example.com" Payload/Ninebot.app/Frameworks/ProjectionOverride.dylib
codesign -f -s "Apple Development: you@example.com" --entitlements ent.plist Payload/Ninebot.app
```
或直接用 **Sideloadly**（把 dylib 拖进 Tweak 列表）自动完成注入+重签。

## 6. 验证

```bash
log stream --predicate 'subsystem == "com.rev.projectionoverride"'
# 期望：ProjectionOverride(Logos) loaded → recordVideo: casting=YES
```
灰度开关：`NSUserDefaults` 写 `NBProjectionOverride = NO` 立刻恢复原生画面。

## 7. 本次已做的实际校验（在无 iOS SDK 的机器上）

| 校验项 | 工具 | 结果 |
|---|---|---|
| Logos 语法/预处理 | 官方 `theos/logos` 的 `logos.pl` | **0 error**，正确生成 4 个 `MSHookMessageEx` 安装点 |
| 生成代码可编译性 | `clang++ -dynamiclib -arch arm64`（macOS SDK） | **0 error**，产出 arm64 dylib（55,200 B） |
| substrate 依赖 | `nm -gU` / `nm -u` | `_MSHookMessageEx` 已定义；未定义符号中 substrate 命中 **0** |
| API 时效性 | 编译告警 | 已弃用 `CGContextSelectFont/ShowTextAtPoint` 已换成 CoreText |

> 说明：macOS SDK 编译验证的是 **Logos 生成代码 + 我们的源码与 API 用法**；
> 真正的 iOS arm64 产物仍需你的机器装了 Xcode/iPhoneOS SDK 后 `make`。

## 8. 限制

1. 只 hook ObjC 方法；`NBPixelBufferConverter`/`NBVideoManager` 均在主二进制内，按类名定位，**不含硬编码地址**，升级后依然有效。
2. 替换的是编码器**输入**，输出仍是 App 的 H.264/MJPEG 码流（车机只解码），尺寸必须与车机 `ConfigModel.targetSize` 一致——代码按传入 CGImage 真实尺寸绘制，自动适配各机型。
3. 回调在投屏线程 25fps 触发，`FrameForSize` 已做 250ms 帧缓存 + 锁保护；重活不要放里面。
4. 心跳是 RTCP APP `command 5 + [0,2]`，丢心跳超限会主动停投；hook 内禁止阻塞。
5. 该机型投屏是否 100% 走 `pixelBufferFromCGImage:` 尚无运行时证据；MJPEG 分支已一并 hook，若仍未变需退到
   `-[NBVideoManager imageVideoEncoder:didEncodedImage:]`。
