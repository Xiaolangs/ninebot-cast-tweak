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
// 两段式：先在「逻辑画布」上画内容，再按 POOrientation 旋转合成到 w×h 输出缓冲。
// 90/270 时逻辑画布宽高互换（h×w），因此旋转后可无损贴满，不需要缩放。
// POScaleMode: "fit"(默认，留黑边) / "fill"(裁切铺满)
static int OrientationDeg(void) {
    id o = [[NSUserDefaults standardUserDefaults] objectForKey:@"POOrientation"];
    int d = o ? [o intValue] : 90;   // 默认 90°（可按需改 0/270）
    if (d != 0 && d != 90 && d != 180 && d != 270) d = 180;
    return d;
}

// 在 cw×ch 上绘制内容（左上原点）
static CGImageRef RenderContent(size_t cw, size_t ch) {
    if (cw == 0 || ch == 0) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, cw, ch, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextTranslateCTM(ctx, 0, (CGFloat)ch);
    CGContextScaleCTM(ctx, 1, -1);

    CGFloat W = cw, H = ch;
    CGContextSetRGBFillColor(ctx, 0.05, 0.06, 0.09, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, W, H));

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

static CGImageRef RenderFrame(size_t w, size_t h) {
    if (w == 0 || h == 0) return NULL;
    int deg = OrientationDeg();

    size_t cw = (deg == 90 || deg == 270) ? h : w;
    size_t ch = (deg == 90 || deg == 270) ? w : h;

    CGImageRef content = RenderContent(cw, ch);
    if (!content) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) { CGImageRelease(content); return NULL; }

    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));

    // 旋转后内容的包围盒：90/270 为 ch×cw，0/180 为 cw×ch
    BOOL swap = (deg == 90 || deg == 270);
    double outW = swap ? (double)ch : (double)cw;
    double outH = swap ? (double)cw : (double)ch;
    id modeObj = [[NSUserDefaults standardUserDefaults] objectForKey:@"POScaleMode"];
    BOOL fill = modeObj && [modeObj isKindOfClass:[NSString class]] &&
                [modeObj caseInsensitiveCompare:@"fill"] == NSOrderedSame;
    double sx = (double)w / outW, sy = (double)h / outH;
    double scale = fill ? (sx > sy ? sx : sy) : (sx < sy ? sx : sy);

    CGContextTranslateCTM(ctx, w / 2.0, h / 2.0);
    CGContextRotateCTM(ctx, (CGFloat)(deg * M_PI / 180.0));
    CGContextScaleCTM(ctx, (CGFloat)scale, (CGFloat)scale);
    CGContextTranslateCTM(ctx, -(CGFloat)cw / 2.0, -(CGFloat)ch / 2.0);  // 注意：cw/ch 是 size_t，取反前必须转浮点
    CGContextTranslateCTM(ctx, 0, (CGFloat)ch);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, cw, ch), content);
    CGImageRelease(content);

    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
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



// ================= 网络/解密 明文打印（诊断）=================
static BOOL gNetLog = YES;
static int  gJsonLogCount = 0;
static int  gUrlLogCount  = 0;

// 把 id（NSData/NSString）转成可读片段
static NSString *Describe(id obj, NSUInteger maxLen) {
    if (!obj) return @"(nil)";
    if ([obj isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)obj;
        NSString *utf8 = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (utf8 && utf8.length > 0) {
            NSString *t = utf8.length > maxLen ? [utf8 substringToIndex:maxLen] : utf8;
            return [NSString stringWithFormat:@"(%luB utf8) %@%@", (unsigned long)d.length, t,
                    utf8.length > maxLen ? @"…" : @""];
        }
        NSData *head = d.length > 48 ? [d subdataWithRange:NSMakeRange(0, 48)] : d;
        return [NSString stringWithFormat:@"(%luB b64) %@%@", (unsigned long)d.length,
                [head base64EncodedStringWithOptions:0], d.length > 48 ? @"…" : @""];
    }
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *t = (NSString *)obj;
        return t.length > maxLen ? [[t substringToIndex:maxLen] stringByAppendingString:@"…"] : t;
    }
    return [obj description];
}

// URL 是否值得打（默认只打主题/资源/zip 相关，PONetLogAll=YES 打全部）
static BOOL UrlInteresting(NSString *u) {
    if (!u) return NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"PONetLogAll"]) return YES;
    NSString *low = u.lowercaseString;
    for (NSString *k in @[@"theme", @"resource", @"skin", @"dashskin", @"upload", @".zip", @"get-new-version"]) {
        if ([low containsString:k]) return YES;
    }
    return NO;
}

static void LogURL(NSString *u, const char *how) {
    if (!gNetLog || !u || gUrlLogCount > 200) return;
    if (!UrlInteresting(u)) return;
    gUrlLogCount++;
    BOOL hasSign = [u.lowercaseString containsString:@"nbchecksignv1"];
    os_log(gLog, "[URL] %{public}s sign=%{public}s\n%{public}s",
           how, hasSign ? "YES" : "NO", u.UTF8String);
}

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
    // 预览做反向旋转：车机转 deg，预览转 -deg，肉眼所见即车机所见
    int deg = OrientationDeg();
    if (deg != 0) {
        double a = -(deg * M_PI / 180.0);
        POAffine t = { cos(a), sin(a), -sin(a), cos(a), 0, 0 };
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


// ================= 网络/解密 hook =================
%hook NSURLSession

- (id)dataTaskWithURL:(id)url {
    LogURL(((id (*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString")), "dataTaskWithURL");
    return %orig;
}
- (id)dataTaskWithRequest:(id)req {
    LogURL(((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(req, sel_registerName("URL")), sel_registerName("absoluteString")), "dataTaskWithRequest");
    return %orig;
}
- (id)downloadTaskWithURL:(id)url {
    LogURL(((id (*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString")), "downloadTaskWithURL");
    return %orig;
}
- (id)downloadTaskWithRequest:(id)req {
    LogURL(((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(req, sel_registerName("URL")), sel_registerName("absoluteString")), "downloadTaskWithRequest");
    return %orig;
}

%end

// 解密层：JCOREDataSecurity（+ / - 两种形式都挂）
%hook JCOREDataSecurity

+ (id)AES256DecryptData:(id)data withKey:(id)key {
    id r = %orig;
    if (gNetLog && gJsonLogCount < 400) {
        gJsonLogCount++;
        os_log(gLog, "[DEC] +AES256DecryptData key=%{public}s\n  in =%{public}s\n  out=%{public}s",
               Describe(key, 64).UTF8String, Describe(data, 500).UTF8String, Describe(r, 900).UTF8String);
    }
    return r;
}
- (id)AES256DecryptData:(id)data withKey:(id)key {
    id r = %orig;
    if (gNetLog && gJsonLogCount < 400) {
        gJsonLogCount++;
        os_log(gLog, "[DEC] -AES256DecryptData key=%{public}s\n  in =%{public}s\n  out=%{public}s",
               Describe(key, 64).UTF8String, Describe(data, 500).UTF8String, Describe(r, 900).UTF8String);
    }
    return r;
}
+ (id)decrypt:(id)cipher aesKey:(id)key {
    id r = %orig;
    if (gNetLog && gJsonLogCount < 400) {
        gJsonLogCount++;
        os_log(gLog, "[DEC] +decrypt:aesKey: key=%{public}s\n  in =%{public}s\n  out=%{public}s",
               Describe(key, 64).UTF8String, Describe(cipher, 500).UTF8String, Describe(r, 900).UTF8String);
    }
    return r;
}
- (id)decrypt:(id)cipher aesKey:(id)key {
    id r = %orig;
    if (gNetLog && gJsonLogCount < 400) {
        gJsonLogCount++;
        os_log(gLog, "[DEC] -decrypt:aesKey: key=%{public}s\n  in =%{public}s\n  out=%{public}s",
               Describe(key, 64).UTF8String, Describe(cipher, 500).UTF8String, Describe(r, 900).UTF8String);
    }
    return r;
}

%end

// JSON 层：解密后的明文最终会到这里，双向打印
%hook NSJSONSerialization

+ (id)JSONObjectWithData:(id)data options:(unsigned long)opt error:(id *)err {
    if (gNetLog && gJsonLogCount < 400 && [data isKindOfClass:[NSData class]]
        && ((NSData *)data).length > 40) {
        NSString *txt = Describe(data, 900);
        if ([txt containsString:@"{"] || [txt containsString:@"["]) {
            gJsonLogCount++;
            os_log(gLog, "[RESP] %{public}s", txt.UTF8String);
        }
    }
    return %orig;
}
+ (id)dataWithJSONObject:(id)obj options:(unsigned long)opt error:(id *)err {
    id r = %orig;
    if (gNetLog && gJsonLogCount < 400 && [r isKindOfClass:[NSData class]]) {
        NSString *txt = Describe(r, 900);
        if ([txt containsString:@"{"] || [txt containsString:@"["]) {
            gJsonLogCount++;
            os_log(gLog, "[REQ] %{public}s", txt.UTF8String);
        }
    }
    return r;
}

%end

%ctor {
    gLog  = os_log_create("com.rev.projectionoverride", "general");
    gLock = [NSLock new];
    int deg = OrientationDeg();
    BOOL mir = [[NSUserDefaults standardUserDefaults] boolForKey:@"POMirror"];
    id m = [[NSUserDefaults standardUserDefaults] objectForKey:@"POScaleMode"];
    os_log(gLog, "ProjectionOverride 2.2 已加载（朝向=%d° 镜像=%s 适配=%s）",
           deg, mir ? "是" : "否", m ? "自定义" : "fit");

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
