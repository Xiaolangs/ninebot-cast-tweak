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
static BOOL        gCasting = NO;

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

// ---------------- Hooks ----------------
%hook NBPixelBufferConverter

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    if (!gCasting || !image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) return %orig;                       // 绘制失败 → 用原生画面
    CVPixelBufferRef buf = %orig(mine);            // 仍走 App 的转换/编码逻辑
    CGImageRelease(mine);
    return buf;
}

- (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image {
    if (!gCasting || !image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) return %orig;
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

%end

%hook NBVideoManager

- (void)recordVideo:(id)target stopAfter:(BOOL)stopAfter {
    gCasting = YES;
    if (gLog) os_log(gLog, "recordVideo: casting=YES");
    %orig;
}

- (void)stop {
    gCasting = NO;
    if (gLog) os_log(gLog, "stop: casting=NO");
    %orig;
}

%end

%ctor {
    gLog  = os_log_create("com.rev.projectionoverride", "general");
    gLock = [NSLock new];
    if (gLog) os_log(gLog, "ProjectionOverride(Logos) loaded");
}
