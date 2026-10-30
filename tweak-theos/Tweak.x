// ProjectionOverride — 九号出行(cn.ninebot.segway) 投屏导航「整帧替换」
// Logos 版。拦截 -[NBPixelBufferConverter pixelBufferFromCGImage:]（编码器输入端）。
// 免越狱可侧载：hook 由 substrate_shim.m 提供的 MSHookMessageEx 完成。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreText/CoreText.h>
#import <os/log.h>
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

static void ReadCenterPixel(CVPixelBufferRef pb, int *r, int *g, int *b) {
    *r = *g = *b = -1;
    if (!pb) return;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    if (base) {
        uint8_t *px = base + (h / 2) * bpr + (w / 2) * 4;   // BGRA
        *b = px[0]; *g = px[1]; *r = px[2];
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

static void RunSelfTest(void) {
    Class c = objc_getClass("NBPixelBufferConverter");
    if (!c) { os_log(gLog, "[SELFTEST] FAIL: 类不存在"); return; }

    id conv = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("alloc")),
                                              sel_registerName("init"));
    if (!conv) { os_log(gLog, "[SELFTEST] FAIL: 实例创建失败"); return; }

    CGImageRef sentinel = MakeSentinel(240, 320);
    if (!sentinel) { os_log(gLog, "[SELFTEST] FAIL: 哨兵图创建失败"); return; }

    CVPixelBufferRef pb = ((CVPixelBufferRef (*)(id, SEL, CGImageRef))objc_msgSend)(
        conv, sel_registerName("pixelBufferFromCGImage:"), sentinel);
    CGImageRelease(sentinel);

    if (!pb) { os_log(gLog, "[SELFTEST] FAIL: 返回空缓冲"); return; }

    int r, g, b;
    ReadCenterPixel(pb, &r, &g, &b);
    os_log(gLog, "[SELFTEST] 中心像素 R=%d G=%d B=%d (纯红=255,0,0)", r, g, b);

    // 我们的背景色是 (13,15,23)；红色哨兵若原样通过则是 (255,0,0)
    BOOL hooked = (r >= 0) && (r < 120);      // 不是红色 → 被替换了
    os_log(gLog, "[SELFTEST] 结论: hook %{public}s", hooked ? "✅ 生效（画面已被替换）" : "❌ 未生效（哨兵图原样返回）");
    CVPixelBufferRelease(pb);
}

// ---------------- Hooks ----------------
%hook NBPixelBufferConverter

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    gPBCalls++;
    if (gPBCalls == 1 || gPBCalls % 50 == 0) {
        os_log(gLog, "[DIAG] pixelBufferFromCGImage #%d size=%zux%zu",
               gPBCalls, CGImageGetWidth(image), CGImageGetHeight(image));
    }
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) {
        os_log(gLog, "[DIAG] RenderFrame 返回 NULL，回落原生画面");
        return %orig;
    }
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

- (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image {
    gMjpegCalls++;
    if (gMjpegCalls == 1 || gMjpegCalls % 50 == 0) {
        os_log(gLog, "[DIAG] MJPEG 分支 #%d size=%zux%zu",
               gMjpegCalls, CGImageGetWidth(image), CGImageGetHeight(image));
    }
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
    os_log(gLog, "ProjectionOverride(Logos) loaded [DIAG v2]");

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
}
