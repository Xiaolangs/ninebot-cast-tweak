// ProjectionOverride — 九号出行(cn.ninebot.segway) 投屏导航「整帧替换」
// Logos 版。拦截 -[NBPixelBufferConverter pixelBufferFromCGImage:]（编码器输入端）。
// 免越狱可侧载：hook 由 substrate_shim.m 提供的 MSHookMessageEx 完成。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreText/CoreText.h>
#import <os/log.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// ---- 目标类声明（二进制无头文件，按 Ghidra 分析结果手写）----
@interface NBPixelBufferConverter : NSObject
- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image;
- (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image;
@end

@interface NBVideoManager : NSObject
- (void)recordVideo:(id)target stopAfter:(BOOL)stopAfter;
- (void)stop;
@end

static os_log_t    gLog     = NULL;
static NSLock     *gLock    = nil;
static int         gPBCalls = 0;      // pixelBufferFromCGImage: 调用次数
static int         gMjpegCalls = 0;   // Mjpeg 分支次数
static int         gEncCalls = 0;     // 编码输出次数

static BOOL OverrideEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"NBProjectionOverride"];
    return v ? [v boolValue] : YES;   // 置 NO 可恢复原生画面做对比
}

// ---- 你的画面（占位实现，换成自己的内容）----
static CGImageRef RenderFrame(size_t w, size_t h) {
    if (w == 0 || h == 0) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);  // BGRA，与 App 一致
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextTranslateCTM(ctx, 0, (CGFloat)h);      // 翻成左上原点，便于按"屏幕坐标"画
    CGContextScaleCTM(ctx, 1, -1);

    CGContextSetRGBFillColor(ctx, 0.05, 0.06, 0.09, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));

    // 示例：一个直行箭头
    CGContextSetRGBFillColor(ctx, 0.13, 0.78, 0.55, 1.0);
    CGMutablePathRef p = CGPathCreateMutable();
    CGFloat W = w, H = h;
    CGPathMoveToPoint(p, NULL, W*0.50, H*0.78);
    CGPathAddLineToPoint(p, NULL, W*0.24, H*0.48);
    CGPathAddLineToPoint(p, NULL, W*0.40, H*0.48);
    CGPathAddLineToPoint(p, NULL, W*0.40, H*0.20);
    CGPathAddLineToPoint(p, NULL, W*0.60, H*0.20);
    CGPathAddLineToPoint(p, NULL, W*0.60, H*0.48);
    CGPathAddLineToPoint(p, NULL, W*0.76, H*0.48);
    CGPathCloseSubpath(p);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGPathRelease(p);

    // 文字（CoreText）
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), H * 0.11, NULL);
    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    const void *keys[] = { kCTForegroundColorAttributeName };
    const void *vals[] = { white };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef astr = CFAttributedStringCreate(NULL, CFSTR("CUSTOM HUD"), attrs);
    CTLineRef line = CTLineCreateWithAttributedString(astr);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    CGContextSetTextPosition(ctx, W * 0.10, H * 0.62);
    CTLineDraw(line, ctx);
    CFRelease(line); CFRelease(astr); CFRelease(attrs); CFRelease(white); CFRelease(font);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

// 帧缓存：投屏以 25fps 调用本 hook，静态内容不重绘
static CGImageRef FrameForSize(size_t w, size_t h) {
    [gLock lock];
    static CGImageRef cache = NULL;
    static size_t cw = 0, ch = 0;
    static CFAbsoluteTime at = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!cache || cw != w || ch != h || (now - at) > 0.25) {
        if (cache) { CGImageRelease(cache); cache = NULL; }
        cache = RenderFrame(w, h);
        cw = w; ch = h; at = now;
    }
    CGImageRef out = cache ? CGImageRetain(cache) : NULL;
    [gLock unlock];
    return out;
}



// ================= 帧导出（确认 App 是否在产帧）=================
static int gDumpIdx = 0;
static void DumpImage(CGImageRef img, const char *tag) {
    if (!img) return;
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!dirs.count) return;
    NSString *dir = [dirs[0] stringByAppendingPathComponent:@"POFrames"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%s_%03d.png", tag, gDumpIdx++]];
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
        CFSTR("public.png"), 1, NULL);
    if (!dst) return;
    CGImageDestinationAddImage(dst, img, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
    os_log(gLog, "[DUMP] 已导出 %{public}s", path.UTF8String);
}

// ================= 自动打开内置调试工具 =================
static void OpenDebugTool(void) {
    id flag = [[NSUserDefaults standardUserDefaults] objectForKey:@"POAutoOpenDebug"];
    if (flag && ![flag boolValue]) { os_log(gLog, "[DBG] 已按要求跳过"); return; }

    Class vcClass = objc_getClass("_TtC7Vehicle22VehicleDebugToolHomeVC");
    if (!vcClass) { os_log(gLog, "[DBG] 调试工具类不存在"); return; }

    @try {
        id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIApplication"),
                                                 sel_registerName("sharedApplication"));
        if (!app) { os_log(gLog, "[DBG] 无 UIApplication"); return; }

        NSSet *scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
        Class sceneCls = objc_getClass("UIWindowScene");
        id keyWindow = nil;
        for (id sc in scenes) {
            if (sceneCls && ![sc isKindOfClass:sceneCls]) continue;
            NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(sc, sel_registerName("windows"));
            for (id w in wins) {
                if (((BOOL (*)(id, SEL))objc_msgSend)(w, sel_registerName("isKeyWindow"))) {
                    keyWindow = w; break;
                }
            }
            if (keyWindow) break;
        }
        if (!keyWindow) { os_log(gLog, "[DBG] 没找到 keyWindow"); return; }

        id root = ((id (*)(id, SEL))objc_msgSend)(keyWindow, sel_registerName("rootViewController"));
        if (!root) { os_log(gLog, "[DBG] 没有 rootVC"); return; }

        id vc = ((id (*)(id, SEL, id, id))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)vcClass, sel_registerName("alloc")),
            sel_registerName("initWithNibName:bundle:"), nil, nil);
        if (!vc) { os_log(gLog, "[DBG] 实例化失败"); return; }

        id nav = ((id (*)(id, SEL, id))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UINavigationController"),
                                            sel_registerName("alloc")),
            sel_registerName("initWithRootViewController:"), vc);

        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(root,
            sel_registerName("presentViewController:animated:completion:"), nav, YES, ^{
                os_log(gLog, "[DBG] 调试工具已打开");
            });
    } @catch (NSException *e) {
        os_log(gLog, "[DBG] 打开失败: %{public}s", e.reason.UTF8String ?: "?");
    }
}

// ================= 运行时选择器导出 =================
#import <objc/runtime.h>

static void DumpSelectors(const char *clsName, int maxCount) {
    Class c = objc_getClass(clsName);
    if (!c) { os_log(gLog, "[DIAG] %{public}s 不存在", clsName); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    os_log(gLog, "[DIAG] %{public}s: %u 个方法%s", clsName, n, n > maxCount ? "（截断）" : "");
    for (unsigned int i = 0; i < n && i < (unsigned int)maxCount; i++)
        os_log(gLog, "[DIAG]    -%{public}s", sel_getName(method_getName(ms[i])));
    free(ms);
}

// ================= 无车辆自检 =================
// 原理：传入一张纯红哨兵图调用被 hook 的方法。
//   hook 生效 → 红图被替换成我们的深色画面 → 采样点不是红色
//   hook 未生效 → 原样转换 → 采样点是红色
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <ImageIO/ImageIO.h>

static CGImageRef MakeSentinel(int w, int h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextSetRGBFillColor(ctx, 1.0, 0.0, 0.0, 1.0);   // 纯红
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

static void RunSelfTest(void) {
    Class c = objc_getClass("NBPixelBufferConverter");
    if (!c) { os_log(gLog, "[SELFTEST] ❌ 类不存在"); return; }

    SEL sel = sel_registerName("pixelBufferFromCGImage:");
    Method im = class_getInstanceMethod(c, sel);
    Method cm = class_getClassMethod(c, sel);
    os_log(gLog, "[SELFTEST] 类名=%{public}s 实例方法=%{public}s 类方法=%{public}s",
           class_getName(c), im ? "是" : "否", cm ? "是" : "否");
    if (!im && !cm) { os_log(gLog, "[SELFTEST] ❌ 两种形式都不存在"); return; }
    // 不再提前 return：下面继续做计数验证

    // 自绘能力自检（与 App 无关）
    CGImageRef mine = RenderFrame(240, 320);
    if (mine) {
        os_log(gLog, "[SELFTEST] RenderFrame ✅ 成功 %zux%zu",
               CGImageGetWidth(mine), CGImageGetHeight(mine));
        CGImageRelease(mine);
    } else {
        os_log(gLog, "[SELFTEST] RenderFrame ❌ 失败");
    }

    // 核心判据：调用一次，看我们的 hook 有没有被触发（计数器 +1）
    CGImageRef sentinel = MakeSentinel(240, 320);
    if (!sentinel) { os_log(gLog, "[SELFTEST] 前置失败"); return; }

    int before = gPBCalls;
    // 关键：按【类方法】形式调用（已确认它是 + 方法）
    CVPixelBufferRef pb = ((CVPixelBufferRef (*)(id, SEL, CGImageRef))objc_msgSend)((id)c, sel, sentinel);
    int after = gPBCalls;
    CGImageRelease(sentinel);

    os_log(gLog, "[SELFTEST] hook 调用计数 %d -> %d", before, after);
    os_log(gLog, "[SELFTEST] 结论: hook %{public}s",
           (after > before) ? "✅ 已安装并被触发（替换链路 OK）"
                            : "❌ 未安装（调用未经过我们的实现）");
    os_log(gLog, "[SELFTEST] 原实现返回=%{public}s（裸实例返回 NULL 属正常，不作为判据）",
           pb ? "非 NULL" : "NULL");
    if (pb) CVPixelBufferRelease(pb);
}

// ---------------- Hooks ----------------
%hook NBPixelBufferConverter

// ---- 类方法（真正的调用形式）----
+ (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    gPBCalls++;
    if (gPBCalls == 1 || gPBCalls % 50 == 0)
        os_log(gLog, "[DIAG] +pixelBufferFromCGImage #%d size=%zux%zu",
               gPBCalls, CGImageGetWidth(image), CGImageGetHeight(image));
    if (gDumpIdx < 3) DumpImage(image, "orig");       // 导出 App 原始帧，证明它在产帧
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) { os_log(gLog, "[DIAG] RenderFrame 返回 NULL"); return %orig; }
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

+ (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image {
    gMjpegCalls++;
    if (gMjpegCalls == 1 || gMjpegCalls % 50 == 0)
        os_log(gLog, "[DIAG] +Mjpeg #%d size=%zux%zu",
               gMjpegCalls, CGImageGetWidth(image), CGImageGetHeight(image));
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) return %orig;
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

// ---- 实例方法（备用，若某些调用点走实例形式）----
- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    gPBCalls++;
    if (gPBCalls == 1 || gPBCalls % 50 == 0)
        os_log(gLog, "[DIAG] -pixelBufferFromCGImage #%d size=%zux%zu",
               gPBCalls, CGImageGetWidth(image), CGImageGetHeight(image));
    if (gDumpIdx < 3) DumpImage(image, "orig");       // 导出 App 原始帧，证明它在产帧
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) { os_log(gLog, "[DIAG] RenderFrame 返回 NULL"); return %orig; }
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

- (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image {
    gMjpegCalls++;
    if (gMjpegCalls == 1 || gMjpegCalls % 50 == 0)
        os_log(gLog, "[DIAG] -Mjpeg #%d size=%zux%zu",
               gMjpegCalls, CGImageGetWidth(image), CGImageGetHeight(image));
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) return %orig;
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

%end

%hook NBVideoManager

- (void)recordVideo:(id)target stopAfter:(BOOL)stopAfter {
    if (gLog) os_log(gLog, "[DIAG] recordVideo:stopAfter: 被调用");
    %orig;
}

- (void)imageVideoEncoder:(id)encoder didEncodedImage:(id)image {
    gEncCalls++;
    if (gEncCalls == 1 || gEncCalls % 50 == 0)
        os_log(gLog, "[DIAG] 编码输出帧 #%d", gEncCalls);
    %orig;
}

%end

%ctor {
    gLog  = os_log_create("com.rev.projectionoverride", "general");
    gLock = [NSLock new];
    os_log(gLog, "ProjectionOverride(Logos) loaded [DIAG v8 20261030e]");

    // 关键诊断：枚举已加载镜像，数一数有几个 Projection 副本
    {
        int copies = 0, total = _dyld_image_count();
        for (int i = 0; i < total; i++) {
            const char *p = _dyld_get_image_name(i);
            if (p && strstr(p, "Projection")) {
                copies++;
                os_log(gLog, "[DYLD] #%d %{public}s", copies, p);
            }
        }
        os_log(gLog, "[DYLD] 共加载 %d 个 ProjectionOverride 副本（应为 1）", copies);
    }

    const char *names[] = {
        "NBPixelBufferConverter", "NBVideoManager",
        "_TtC7Vehicle25NBProjectionScreenManager",
        "_TtC20NBVideoFactoryModule21NavigationViewBuilder",
        "_TtC20NBVideoFactoryModule14VideoGenerator",
        "_TtC20NBVideoFactoryModule21NavigationViewHandler",
        "_TtC20NBVideoFactoryModule28VideoSocketsConnetionManager",
        "_TtC20NBVideoFactoryModule13SnapshotTimer",
        "_TtC20NBVideoFactoryModule16NavConfigManager",
        "_TtC20NBVideoFactoryModule19NavigationInfoModel"
    };
    const int kNumClasses = 10;
    for (int i = 0; i < kNumClasses; i++) {
        Class c = objc_getClass(names[i]);
        BOOL hasSel = NO;
        if (c && i == 0)
            hasSel = class_getInstanceMethod(c, @selector(pixelBufferFromCGImage:)) != NULL;
        os_log(gLog, "[DIAG] class %{public}s -> %{public}s%s",
               names[i], c ? "存在" : "不存在",
               hasSel ? " (含 pixelBufferFromCGImage:)" : "");
    }

    // 运行时导出选择器，消除对 mangled/选择器名的猜测
    for (int i = 0; i < kNumClasses; i++) DumpSelectors(names[i], 24);

    // 启动 5 秒后自检（等 App 完成 launch，避免干扰）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ RunSelfTest(); });

    // 启动 10 秒后自动打开内置调试工具（含"模拟导航/视频投屏工具"）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ OpenDebugTool(); });
}
