// ThemeApply — 主页按钮：选择本地皮肤文件并应用到车辆详情页
//
// 逆向得到的官方链路（日志串证据）：
//   [DeviceResource] - start → downloadSkinData() / 缓存命中 → 解密
//     → setSkinData(skinData:) → zip 写本地 → 解压 → [SkinData] 设置背景
//     → QGVAPlayer 播放 mp4 → [ThemeSkinResourcePool] 命中本地主题，准备播放
//   缓存键形如 skinData_bg_<wnumber>
//
// 本工具做法：
//   1. 主页放一个「皮肤」按钮（挂在 App 主窗口，不建覆盖窗口）
//   2. 点击 → 系统文件选择器 → 选本地 zip/文件
//   3. 拷入 App 沙盒（Documents/ThemeLocal/ + 尝试写入缓存目录）
//   4. 主动调用 DeviceResource.playSkinResource() 触发官方应用流程
//   5. 全程打日志，便于下一步精确定位注入点

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

static os_log_t gLog = NULL;
static NSString *gPickedPath = nil;

#pragma mark - 工具

static UIWindow *KeyWindow(void) {
    UIWindow *best = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        if (w.isKeyWindow) return w;
        if (!best && w.rootViewController) best = w;
    }
    return best;
}

static UIViewController *TopVC(void) {
    UIViewController *host = KeyWindow().rootViewController;
    while (host.presentedViewController) host = host.presentedViewController;
    return host;
}

static id TrySingleton(Class cls) {
    if (!cls) return nil;
    for (NSString *n in @[@"shared", @"sharedInstance", @"defaultManager", @"standard",
                          @"instance", @"manager", @"current", @"default"]) {
        SEL s = NSSelectorFromString(n);
        if (![cls respondsToSelector:s]) continue;
        @try { id o = ((id(*)(id,SEL))objc_msgSend)(cls, s); if (o) return o; } @catch (__unused NSException *e) {}
    }
    return nil;
}

static void DumpMethods(const char *clsName) {
    Class c = objc_getClass(clsName);
    if (!c) { os_log(gLog, "[TA] 类缺失 %{public}s", clsName); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSMutableString *s = [NSMutableString string];
    for (unsigned int i = 0; i < n && i < 60; i++)
        [s appendFormat:@"%s ", sel_getName(method_getName(ms[i]))];
    free(ms);
    os_log(gLog, "[TA] %{public}s 方法(%u): %{public}s", clsName, n, s.UTF8String);
}

static NSArray<NSString *> *SandboxDirs(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *lib  = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    for (NSString *p in @[docs ?: @"", lib ?: @"", caches ?: @"", NSTemporaryDirectory() ?: @""])
        if (p.length) [a addObject:p];
    return a;
}

// 找出所有名字含 ThemeSkinResource / 皮肤缓存 的目录
static void LogSkinDirs(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in SandboxDirs()) {
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
        NSString *rel; int shown = 0;
        while ((rel = [e nextObject]) && shown < 20) {
            NSString *low = rel.lowercaseString;
            if (!([low containsString:@"themeskin"] || [low containsString:@"skinresource"] ||
                  [low containsString:@"skin"])) continue;
            NSString *full = [root stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            [fm fileExistsAtPath:full isDirectory:&isDir];
            if (!isDir) continue;
            os_log(gLog, "[TA] 皮肤目录: %{public}s",
                   [full stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"].UTF8String);
            [e skipDescendants];
            shown++;
        }
    }
}

#pragma mark - 应用

static void ApplyLocalSkin(NSString *path) {
    os_log(gLog, "[TA] ---- 开始应用本地皮肤: %{public}s ----", path.lastPathComponent.UTF8String);

    Class dr = objc_getClass("_TtC7Vehicle14DeviceResource");
    if (!dr) dr = objc_getClass("Vehicle.DeviceResource");
    os_log(gLog, "[TA] DeviceResource 类: %{public}s", dr ? "有" : "无");

    id inst = TrySingleton(dr);
    os_log(gLog, "[TA] DeviceResource 单例: %{public}s", inst ? "有" : "无");

    if (inst) {
        SEL s = NSSelectorFromString(@"playSkinResource");
        if ([inst respondsToSelector:s]) {
            os_log(gLog, "[TA] 调用 playSkinResource()");
            @try { ((void(*)(id,SEL))objc_msgSend)(inst, s); }
            @catch (NSException *e) { os_log(gLog, "[TA] playSkinResource 异常: %{public}s", e.reason.UTF8String); }
        } else {
            os_log(gLog, "[TA] DeviceResource 没有 playSkinResource 方法");
        }
    }

    // 通知皮肤资源状态变化，促使界面刷新
    @try {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"com.ninebot.vehicle.themeSkinResources.state"
                                                            object:nil];
        os_log(gLog, "[TA] 已发送 themeSkinResources.state 通知");
    } @catch (__unused NSException *e) {}

    LogSkinDirs();
}

#pragma mark - 文件选择

@interface TAProvider : NSObject <UIDocumentPickerDelegate>
+ (instancetype)shared;
- (void)pick;
@end

@implementation TAProvider

+ (instancetype)shared {
    static TAProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TAProvider new]; });
    return s;
}

- (void)pick {
    NSArray *types = @[@"public.item", @"public.data", @"public.zip-archive"];
    UIDocumentPickerViewController *vc =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types
                                                               inMode:UIDocumentPickerModeImport];
    vc.delegate = self;
    vc.allowsMultipleSelection = NO;
    [TopVC() presentViewController:vc animated:YES completion:nil];
    os_log(gLog, "[TA] 已弹出文件选择器");
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    os_log(gLog, "[TA] 选中文件: %{public}s", u.absoluteString.UTF8String);

    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject];
    dir = [dir stringByAppendingPathComponent:@"ThemeLocal"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:u.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];

    NSError *err = nil;
    BOOL scoped = [u startAccessingSecurityScopedResource];
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:&err];
    if (scoped) [u stopAccessingSecurityScopedResource];

    if (!ok) {
        os_log(gLog, "[TA] ❌ 拷贝失败: %{public}s", err.localizedDescription.UTF8String);
        return;
    }
    NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:dst error:nil];
    os_log(gLog, "[TA] ✅ 已保存: %{public}s (%llu B)", dst.UTF8String,
           [attr[NSFileSize] unsignedLongLongValue]);
    gPickedPath = dst;
    ApplyLocalSkin(dst);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c {
    os_log(gLog, "[TA] 已取消选择");
}

@end

#pragma mark - 悬浮按钮

@interface TAButton : NSObject
@property (nonatomic, strong) UIButton *btn;
+ (instancetype)shared;
- (void)install;
- (void)keepAlive;
@end

@implementation TAButton
+ (instancetype)shared {
    static TAButton *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TAButton new]; });
    return s;
}

- (void)install {
    if (self.btn && self.btn.superview) return;
    UIWindow *w = KeyWindow();
    if (!w) return;
    if (!self.btn) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, 52, 52);
        b.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.4 alpha:0.9];
        [b setTitle:@"皮肤" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.layer.cornerRadius = 26;
        b.layer.shadowColor = UIColor.blackColor.CGColor;
        b.layer.shadowOpacity = 0.3; b.layer.shadowRadius = 4;
        b.layer.shadowOffset = CGSizeMake(0, 2);
        [b addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [b addGestureRecognizer:pan];
        b.center = CGPointMake(w.bounds.size.width - 48, w.bounds.size.height * 0.55);
        self.btn = b;
    }
    [w addSubview:self.btn];
    [w bringSubviewToFront:self.btn];
}

- (void)keepAlive { if (!self.btn || !self.btn.superview) [self install]; }

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.btn.superview];
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint c = CGPointMake(self.btn.center.x + t.x, self.btn.center.y + t.y);
        CGFloat half = 26;
        c.x = MAX(half, MIN(self.btn.superview.bounds.size.width - half, c.x));
        c.y = MAX(half + 44, MIN(self.btn.superview.bounds.size.height - half, c.y));
        self.btn.center = c;
        [g setTranslation:CGPointZero inView:self.btn.superview];
    }
}

- (void)tap { [[TAProvider shared] pick]; }
@end

__attribute__((constructor)) static void TAInit(void) {
    gLog = os_log_create("com.rev.themeapply", "general");
    os_log(gLog, "ThemeApply 1.0 已加载");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DumpMethods("_TtC7Vehicle14DeviceResource");
        DumpMethods("_TtC7Vehicle18DeviceResourceData");
        DumpMethods("_TtC7Vehicle25ThemeSkinResourcePoolTool");
        [[TAButton shared] install];
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
                                                    block:^(__unused NSTimer *tm) { [[TAButton shared] keepAlive]; }];
        [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    });
}
