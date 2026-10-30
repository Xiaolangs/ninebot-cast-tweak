// ProjectionOverride.dylib
// 整帧替换九号出行「投屏导航」画面（NBVideoFactoryModule 视频管线，① 层）
//
// 原理：-[NBPixelBufferConverter pixelBufferFromCGImage:] 把 App 渲染好的
// CGImage 转成 CVPixelBuffer 交给编码器。本 dylib 用自己画的 CGImage 调原实现，
// 于是编码、RTP 分帧、RTCP 心跳、KCP/BLE 传输全部沿用 App 原逻辑。
//
// 不依赖 CydiaSubstrate/ellekit：仅用 ObjC runtime，可随自签 IPA 侧载运行。
// 不硬编码地址：全部按 类名/选择器 定位，App 升级后依然有效。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t gLog;
static IMP      g_origPNG   = NULL;   // pixelBufferFromCGImage:
static IMP      g_origMjpeg = NULL;   // pixelBufferFromCGImage_Mjpeg:
static BOOL     g_casting   = NO;     // 仅在投屏进行中替换
static CGImageRef g_cache   = NULL;   // 缓存帧
static size_t   g_cacheW    = 0, g_cacheH = 0;
static CFAbsoluteTime g_cacheAt = 0;
static NSLock  *g_lock      = nil;

static BOOL OverrideEnabled(void) {
    // 便于灰度和排查：设置里写 NO 即恢复原生画面
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"NBProjectionOverride"];
    return v ? [v boolValue] : YES;
}

// ---- 你的画面：在这里绘制 ----
// 注意：必须按 width/height 绘制（App 会传当前机型布局的真实尺寸）
static CGImageRef RenderFrame(size_t w, size_t h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little); // BGRA，与 App 一致
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    // CGBitmapContext 原点在左下，整体翻转以适配 App 的 UIImage 坐标系
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1, -1);

    // 背景
    CGContextSetRGBFillColor(ctx, 0.05, 0.06, 0.09, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));

    // 一条示例转向箭头（替换成你自己的图片/文字）
    CGContextSetRGBFillColor(ctx, 0.13, 0.78, 0.55, 1.0);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, w * 0.50, h * 0.74);
    CGPathAddLineToPoint(p, NULL, w * 0.24, h * 0.44);
    CGPathAddLineToPoint(p, NULL, w * 0.40, h * 0.44);
    CGPathAddLineToPoint(p, NULL, w * 0.40, h * 0.18);
    CGPathAddLineToPoint(p, NULL, w * 0.60, h * 0.18);
    CGPathAddLineToPoint(p, NULL, w * 0.60, h * 0.44);
    CGPathAddLineToPoint(p, NULL, w * 0.76, h * 0.44);
    CGPathCloseSubpath(p);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGPathRelease(p);

    // 文字（CoreText，避免已废弃 API）
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity); // 已做垂直翻转，见下
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), h * 0.11, NULL);
    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    CFStringRef key = CFSTR("NSColor");
    const void *keys[] = { key };
    const void *vals[] = { white };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef str = CFSTR("CUSTOM HUD");
    CFAttributedStringRef astr = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(astr);
    CGContextSetTextPosition(ctx, w * 0.10, h * 0.34);
    CTLineDraw(line, ctx);
    CFRelease(line); CFRelease(astr); CFRelease(attrs); CFRelease(white); CFRelease(font);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

// 每帧取用；尺寸变化或缓存过期时重绘
static CGImageRef FrameForSize(size_t w, size_t h) {
    [g_lock lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL stale = (g_cache == NULL) || (g_cacheW != w) || (g_cacheH != h) || (now - g_cacheAt > 0.25);
    if (stale) {
        if (g_cache) { CGImageRelease(g_cache); g_cache = NULL; }
        g_cache = RenderFrame(w, h);        // 失败则返回 NULL，走原生画面
        g_cacheW = w; g_cacheH = h; g_cacheAt = now;
    }
    CGImageRef out = g_cache ? CGImageRetain(g_cache) : NULL;
    [g_lock unlock];
    return out;
}

static CVPixelBufferRef Hook_PixelBufferFromCGImage(id self, SEL _cmd, CGImageRef img) {
    if (!g_casting || !img || !OverrideEnabled() || !g_origPNG) {
        return ((CVPixelBufferRef (*)(id, SEL, CGImageRef))g_origPNG)(self, _cmd, img);
    }
    // 关键：用进来的图片尺寸，保证跨机型（D1X/D2X/F43/2.4"/5"）尺寸自动匹配
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CGImageRef mine = FrameForSize(w, h);
    if (!mine) {
        return ((CVPixelBufferRef (*)(id, SEL, CGImageRef))g_origPNG)(self, _cmd, img);
    }
    CVPixelBufferRef buf = ((CVPixelBufferRef (*)(id, SEL, CGImageRef))g_origPNG)(self, _cmd, mine);
    CGImageRelease(mine);
    return buf;
}

static CVPixelBufferRef Hook_PixelBufferFromCGImage_Mjpeg(id self, SEL _cmd, CGImageRef img) {
    if (!g_casting || !img || !OverrideEnabled() || !g_origMjpeg) {
        return ((CVPixelBufferRef (*)(id, SEL, CGImageRef))g_origMjpeg)(self, _cmd, img);
    }
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CGImageRef mine = FrameForSize(w, h);
    if (!mine) return ((CVPixelBufferRef (*)(id, SEL, CGImageRef))g_origMjpeg)(self, _cmd, img);
    CVPixelBufferRef buf = ((CVPixelBufferRef (*)(id, SEL, CGImageRef))g_origMjpeg)(self, _cmd, mine);
    CGImageRelease(mine);
    return buf;
}

// ---- 投屏状态门控：只在投屏期间替换 ----
static void (*g_origRecord)(id, SEL, id, BOOL) = NULL;
static void (*g_origStop)(id, SEL) = NULL;

static void Hook_RecordVideo(id self, SEL _cmd, id target, BOOL stopAfter) {
    g_casting = YES;
    os_log(gLog, "recordVideo: start (casting=YES)");
    if (g_origRecord) g_origRecord(self, _cmd, target, stopAfter);
}
static void Hook_Stop(id self, SEL _cmd) {
    g_casting = NO;
    os_log(gLog, "stop (casting=NO)");
    if (g_origStop) g_origStop(self, _cmd);
}

static void Swizzle(const char *cls, const char *sel, IMP newImp, IMP *outOrig) {
    Class c = objc_getClass(cls);
    if (!c) { os_log(gLog, "class not found: %s", cls); return; }
    Method m = class_getInstanceMethod(c, sel_registerName(sel));
    if (!m) { os_log(gLog, "selector not found: %s -%s", cls, sel); return; }
    IMP old = method_setImplementation(m, newImp);
    if (outOrig) *outOrig = old;
    os_log(gLog, "hooked %s -%s", cls, sel);
}

__attribute__((constructor))
static void ProjectionOverrideInit(void) {
    gLog = os_log_create("com.rev.projectionoverride", "general");
    g_lock = [NSLock new];

    Swizzle("NBPixelBufferConverter", "pixelBufferFromCGImage:",
            (IMP)Hook_PixelBufferFromCGImage, &g_origPNG);
    Swizzle("NBPixelBufferConverter", "pixelBufferFromCGImage_Mjpeg:",
            (IMP)Hook_PixelBufferFromCGImage_Mjpeg, &g_origMjpeg);
    Swizzle("NBVideoManager", "recordVideo:stopAfter:", (IMP)Hook_RecordVideo, (IMP *)&g_origRecord);
    Swizzle("NBVideoManager", "stop", (IMP)Hook_Stop, (IMP *)&g_origStop);

    os_log(gLog, "ProjectionOverride loaded");
}
