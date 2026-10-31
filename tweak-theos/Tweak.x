// ProjectionOverride — 九号出行(cn.ninebot.segway) 投屏导航「整帧替换」正式版
//
// 拦截点：+[NBPixelBufferConverter pixelBufferFromCGImage:]（类方法，已实测）
//         +[NBPixelBufferConverter pixelBufferFromCGImage_Mjpeg:]（MJPEG 备用路径）
// 该类属于 NBVideoFactoryModule（投屏专用），因此无条件替换是安全的。
// 日志前缀 [CAST]：投屏真正开始时会出现 frame #1 / #101 / ...

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <os/log.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

@interface NBPixelBufferConverter : NSObject
+ (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image;
+ (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image;
- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image;
- (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image;
@end

static os_log_t gLog   = NULL;
static NSLock  *gLock  = nil;
static int      gFrames = 0;
static int      gDumped = 0;

static BOOL OverrideEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"NBProjectionOverride"];
    return v ? [v boolValue] : YES;          // 置 NO 即恢复原生画面
}


// ---------------- 朝向 ----------------
// 基准：已做垂直翻转使坐标系为左上原点（保证文字正向）
// POOrientation: 0 或 180（默认 180，实测车机为 180 旋转）；POMirror: 水平镜像
static void ApplyOrientation(CGContextRef ctx, size_t w, size_t h) {
    CGContextTranslateCTM(ctx, 0, (CGFloat)h);
    CGContextScaleCTM(ctx, 1, -1);                      // 基准翻转

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id o = [d objectForKey:@"POOrientation"];
    int deg = o ? [o intValue] : 180;                   // 默认 180

    if (deg == 180) {
        CGContextTranslateCTM(ctx, (CGFloat)w, (CGFloat)h);
        CGContextScaleCTM(ctx, -1, -1);                 // 绕中心旋转 180
    }
    if ([d boolForKey:@"POMirror"]) {
        CGContextTranslateCTM(ctx, (CGFloat)w, 0);
        CGContextScaleCTM(ctx, -1, 1);                  // 水平镜像
    }
}

// ---------------- 你的画面 ----------------
static CGImageRef RenderFrame(size_t w, size_t h) {
    if (w == 0 || h == 0) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    ApplyOrientation(ctx, w, h);

    CGContextSetRGBFillColor(ctx, 0.05, 0.06, 0.09, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));

    CGFloat W = w, H = h;
    CGContextSetRGBFillColor(ctx, 0.13, 0.78, 0.55, 1.0);
    CGMutablePathRef p = CGPathCreateMutable();
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

// 可选：把真正要发给车机的画面导出（POFrameDump=YES 时前 5 帧）
static void MaybeDump(CGImageRef img, int idx) {
    if (gDumped >= 5) return;
    id flag = [[NSUserDefaults standardUserDefaults] objectForKey:@"POFrameDump"];
    if (!flag || ![flag boolValue]) return;
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!docs.count) return;
    NSString *dir = [docs[0] stringByAppendingPathComponent:@"POFrames"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"cast_%03d.png", idx]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (!dst) return;
    CGImageDestinationAddImage(dst, img, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
    gDumped++;
    os_log(gLog, "[CAST] 已导出 %{public}s", path.UTF8String);
}

static void NoteFrame(size_t w, size_t h) {
    gFrames++;
    if (gFrames == 1 || gFrames % 100 == 0) {
        os_log(gLog, "[CAST] frame #%d size=%zux%zu（投屏正在推流，画面已替换）", gFrames, w, h);
    }
}

// ---------------- Hooks ----------------
%hook NBPixelBufferConverter

+ (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    NoteFrame(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) return %orig;
    MaybeDump(mine, gFrames);
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

+ (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image {
    NoteFrame(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) return %orig;
    MaybeDump(mine, gFrames);
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    NoteFrame(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) return %orig;
    MaybeDump(mine, gFrames);
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

- (CVPixelBufferRef)pixelBufferFromCGImage_Mjpeg:(CGImageRef)image {
    NoteFrame(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!image || !OverrideEnabled()) return %orig;
    CGImageRef mine = FrameForSize(CGImageGetWidth(image), CGImageGetHeight(image));
    if (!mine) return %orig;
    MaybeDump(mine, gFrames);
    CVPixelBufferRef buf = %orig(mine);
    CGImageRelease(mine);
    return buf;
}

%end


// ================= 模拟投屏（本地全屏预览）=================
typedef struct { double x, y, w, h; } PORect;
typedef struct { double a, b, c, d, tx, ty; } POAffine;

@interface POSimTarget : NSObject
- (void)handleTap:(id)sender;
- (void)handleButton:(id)sender;
- (void)tick:(id)timer;
@end

static id  gPreviewTimer = nil;
static int gPreviewTick = 0;

static id KeyWindow(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIApplication"),
                                            sel_registerName("sharedApplication"));
    if (!app) return nil;
    NSSet *scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
    Class sceneCls = objc_getClass("UIWindowScene");
    for (id sc in scenes) {
        if (sceneCls && ![sc isKindOfClass:sceneCls]) continue;
        for (id w in ((id (*)(id, SEL))objc_msgSend)(sc, sel_registerName("windows"))) {
            if (((BOOL (*)(id, SEL))objc_msgSend)(w, sel_registerName("isKeyWindow"))) return w;
        }
    }
    return nil;
}

static id RootVC(void) {
    id w = KeyWindow();
    return w ? ((id (*)(id, SEL))objc_msgSend)(w, sel_registerName("rootViewController")) : nil;
}

static id FindLabel(id view, NSString *needle, int depth) {
    if (!view || depth > 40) return nil;
    if (((BOOL (*)(id, SEL, id))objc_msgSend)(view, sel_registerName("isKindOfClass:"),
                                          objc_getClass("UILabel"))) {
        id text = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("text"));
        if (text && [text isKindOfClass:[NSString class]] && [text containsString:needle]) return view;
    }
    for (id sv in ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews"))) {
        id hit = FindLabel(sv, needle, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

@implementation POSimTarget

- (void)openPreview {
    id root = RootVC();
    id win  = KeyWindow();
    if (!root || !win) { os_log(gLog, "[SIM] 无窗口，无法预览"); return; }

    PORect b = ((PORect (*)(id, SEL))objc_msgSend)(win, sel_registerName("bounds"));

    id vc = ((id (*)(id, SEL, id, id))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIViewController"), sel_registerName("alloc")),
        sel_registerName("initWithNibName:bundle:"), nil, nil);
    if (!vc) { os_log(gLog, "[SIM] VC 创建失败"); return; }

    PORect full = {0, 0, b.w, b.h};
    id view = ((id (*)(id, SEL, PORect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIView"), sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), full);
    ((void (*)(id, SEL, id))objc_msgSend)(view, sel_registerName("setBackgroundColor:"),
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIColor"), sel_registerName("blackColor")));
    ((void (*)(id, SEL, id))objc_msgSend)(vc, sel_registerName("setView:"), view);

    PORect f = {0, 0, b.w, b.w * 320.0 / 240.0};
    f.y = (b.h - f.h) / 2.0;
    id iv = ((id (*)(id, SEL, PORect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIImageView"), sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), f);
    ((void (*)(id, SEL, id))objc_msgSend)(view, sel_registerName("addSubview:"), iv);

    // 车机按 180° 显示，预览反向旋转 → 肉眼所见即车机所见
    id o = [[NSUserDefaults standardUserDefaults] objectForKey:@"POOrientation"];
    int deg = o ? [o intValue] : 180;
    if (deg == 180) {
        POAffine t = {-1, 0, 0, -1, 0, 0};
        ((void (*)(id, SEL, POAffine))objc_msgSend)(iv, sel_registerName("setTransform:"), t);
    }

    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(root,
        sel_registerName("presentViewController:animated:completion:"), vc, YES, ^{
            os_log(gLog, "[SIM] 模拟投屏已打开（点击画面可关闭）");
        });

    gPreviewTick = 0;
    gPreviewTimer = ((id (*)(id, SEL, double, id, SEL, id, BOOL))objc_msgSend)(
        objc_getClass("NSTimer"),
        sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        0.04, self, sel_registerName("tick:"), iv, YES);

    // 点击画面关闭
    ((void (*)(id, SEL, BOOL))objc_msgSend)(view, sel_registerName("setUserInteractionEnabled:"), YES);
    id gr = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UITapGestureRecognizer"), sel_registerName("alloc")),
        sel_registerName("initWithTarget:action:"), self, sel_registerName("handleButton:"));
    ((void (*)(id, SEL, id))objc_msgSend)(view, sel_registerName("addGestureRecognizer:"), gr);
    os_log(gLog, "[SIM] 预览定时器已启动");
}

- (void)tick:(id)timer {
    if (gPreviewTick++ < 0) return;
    id iv = ((id (*)(id, SEL))objc_msgSend)(timer, sel_registerName("userInfo"));
    if (!iv) return;
    CGImageRef img = RenderFrame(240, 320);
    if (!img) return;
    id ui = ((id (*)(id, SEL, CGImageRef, double, long))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIImage"), sel_registerName("alloc")),
        sel_registerName("initWithCGImage:scale:orientation:"), img, 1.0, 0);
    ((void (*)(id, SEL, id))objc_msgSend)(iv, sel_registerName("setImage:"), ui);
    CGImageRelease(img);
}

- (void)handleTap:(id)sender { os_log(gLog, "[SIM] 命中「拥有爱车」标签"); [self openPreview]; }
- (void)handleButton:(id)sender {
    if (gPreviewTimer) {
        ((void (*)(id, SEL))objc_msgSend)(gPreviewTimer, sel_registerName("invalidate"));
        gPreviewTimer = nil;
        id root = RootVC();
        if (root) ((void (*)(id, SEL, BOOL, id))objc_msgSend)(root,
            sel_registerName("dismissViewControllerAnimated:completion:"), YES, nil);
        os_log(gLog, "[SIM] 预览已关闭");
        return;
    }
    os_log(gLog, "[SIM] 点击悬浮按钮");
    [self openPreview];
}

@end

static POSimTarget *gSimTarget = nil;
static BOOL gLabelHooked = NO;

static void InstallEntryPoint(void) {
    if (gLabelHooked) return;
    id root = RootVC();
    if (!root) return;
    id v = ((id (*)(id, SEL))objc_msgSend)(root, sel_registerName("view"));
    id label = FindLabel(v, @"拥有爱车", 0);
    if (!label) label = FindLabel(v, @"爱车", 0);
    if (!label) return;

    ((void (*)(id, SEL, BOOL))objc_msgSend)(label, sel_registerName("setUserInteractionEnabled:"), YES);
    id gr = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UITapGestureRecognizer"), sel_registerName("alloc")),
        sel_registerName("initWithTarget:action:"), gSimTarget, sel_registerName("handleTap:"));
    ((void (*)(id, SEL, id))objc_msgSend)(label, sel_registerName("addGestureRecognizer:"), gr);
    gLabelHooked = YES;
    os_log(gLog, "[SIM] ✅ 已在「拥有爱车」标签挂载点击");
}

static void InstallFloatingButton(void) {
    id w = KeyWindow();
    if (!w) return;
    PORect b = ((PORect (*)(id, SEL))objc_msgSend)(w, sel_registerName("bounds"));
    PORect f = { b.w - 116, b.h - 150, 104, 42 };
    id btn = ((id (*)(id, SEL, PORect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIButton"), sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), f);
    ((void (*)(id, SEL, id, long))objc_msgSend)(btn, sel_registerName("setTitle:forState:"), @"模拟投屏", 0);
    id color = ((id (*)(id, SEL, double, double))objc_msgSend)(objc_getClass("UIColor"),
        sel_registerName("colorWithWhite:alpha:"), 0.25, 0.9);
    ((void (*)(id, SEL, id))objc_msgSend)(btn, sel_registerName("setBackgroundColor:"), color);
    ((void (*)(id, SEL, id, SEL, long))objc_msgSend)(btn,
        sel_registerName("addTarget:action:forControlEvents:"),
        gSimTarget, sel_registerName("handleButton:"), 64);
    ((void (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("addSubview:"), btn);
    os_log(gLog, "[SIM] 悬浮按钮已添加");
}

%ctor {
    gLog  = os_log_create("com.rev.projectionoverride", "general");
    gLock = [NSLock new];
    id o = [[NSUserDefaults standardUserDefaults] objectForKey:@"POOrientation"];
    int deg = o ? [o intValue] : 180;
    BOOL mir = [[NSUserDefaults standardUserDefaults] boolForKey:@"POMirror"];
    os_log(gLog, "ProjectionOverride 2.0 已加载（朝向=%d° 镜像=%s）", deg, mir ? "是" : "否");

    gSimTarget = [POSimTarget new];
    id noBtn = [[NSUserDefaults standardUserDefaults] objectForKey:@"POSimFloatingButton"];
    BOOL wantBtn = noBtn ? [noBtn boolValue] : YES;

    // 启动后持续扫描入口（首页可能异步渲染）
    for (int i = 1; i <= 20; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            InstallEntryPoint();
            if (wantBtn && i == 6) InstallFloatingButton();
        });
    }
}
