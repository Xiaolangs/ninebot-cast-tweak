// DebugPanel — 悬浮「调试」按钮 + 信息面板
//
// 零钩子设计：不使用任何 %hook，只在加载后创建一个可拖动悬浮按钮。
// 按钮位于独立穿透窗口内，除按钮本身外不拦截任何触摸，不影响 App 正常操作。
//
// 面板内容：
//   1. 环境信息（bundle / 版本 / 系统 / 机型）
//   2. 关键沙盒路径（可复制）
//   3. 皮肤资源缓存扫描 —— 重点：找出已下载的仪表皮肤 zip / bin
//   4. 一键复制报告、导出到 Documents

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <os/log.h>

static os_log_t gLog = NULL;

#pragma mark - 工具

static NSString *DPHuman(unsigned long long n) {
    if (n < 1024) return [NSString stringWithFormat:@"%lluB", n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1fKB", n / 1024.0];
    if (n < 1024ULL * 1024 * 1024) return [NSString stringWithFormat:@"%.2fMB", n / 1048576.0];
    return [NSString stringWithFormat:@"%.2fGB", n / 1073741824.0];
}

static BOOL DPInteresting(NSString *name) {
    NSString *l = name.lowercaseString;
    for (NSString *k in @[@"theme", @"skin", @"dash", @"resource", @"instrument"]) {
        if ([l containsString:k]) return YES;
    }
    return NO;
}

static BOOL DPInterestingExt(NSString *name) {
    NSString *e = name.pathExtension.lowercaseString;
    return [@[@"zip", @"bin", @"mp4", @"json"] containsObject:e];
}

// 递归扫描，收集「关键字命中」或「大于 100KB」的文件
static void DPWalk(NSString *dir, NSMutableArray<NSDictionary *> *out, int depth) {
    if (depth > 5 || out.count > 300) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *it in items) {
        if (out.count > 300) return;
        NSString *p = [dir stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir]) continue;
        if (isDir) {
            DPWalk(p, out, depth + 1);
            continue;
        }
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        unsigned long long size = [attr[NSFileSize] unsignedLongLongValue];
        if (size >= 100 * 1024 || DPInteresting(it)) {
            [out addObject:@{@"path": p, @"size": @(size),
                             @"hit": @(DPInteresting(it) || DPInterestingExt(it))}];
        }
    }
}

static NSString *DPBuildReport(void) {
    NSMutableString *r = [NSMutableString string];
    NSBundle *b = [NSBundle mainBundle];
    UIDevice *dev = [UIDevice currentDevice];

    [r appendString:@"== 环境 ==\n"];
    [r appendFormat:@"bundle   : %@\n", b.bundleIdentifier];
    [r appendFormat:@"版本     : %@ (%@)\n",
        [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [b objectForInfoDictionaryKey:@"CFBundleVersion"]];
    [r appendFormat:@"系统     : %@ %@\n", dev.systemName, dev.systemVersion];
    [r appendFormat:@"机型     : %@\n", dev.model];
    [r appendFormat:@"时间     : %@\n\n", [NSDate date]];

    NSArray *paths = @[
        @[@"Documents",   NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @""],
        @[@"Library",     NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject ?: @""],
        @[@"Caches",      NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @""],
        @[@"tmp",         NSTemporaryDirectory() ?: @""],
    ];
    [r appendString:@"== 沙盒路径 ==\n"];
    for (NSArray *pair in paths) [r appendFormat:@"%-10@ %@\n", pair[0], pair[1]];
    [r appendString:@"\n"];

    [r appendString:@"== 缓存文件扫描（关键字命中 或 >100KB）==\n"];
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    for (NSArray *pair in paths) {
        NSString *base = pair[1];
        if (!base.length) continue;
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:base isDirectory:&isDir] && isDir)
            DPWalk(base, files, 0);
    }
    // 排序：关键字命中优先，其次按大小
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *c) {
        BOOL ha = [a[@"hit"] boolValue], hc = [c[@"hit"] boolValue];
        if (ha != hc) return ha ? NSOrderedAscending : NSOrderedDescending;
        return [c[@"size"] compare:a[@"size"]];
    }];
    if (!files.count) {
        [r appendString:@"（未发现候选文件）\n"];
    } else {
        for (NSDictionary *f in files) {
            NSString *p = f[@"path"];
            NSString *shown = [p stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"];
            [r appendFormat:@"%@ %-9@ %@\n", [f[@"hit"] boolValue] ? @"★" : @" ",
                DPHuman([f[@"size"] unsignedLongLongValue]), shown];
        }
        [r appendFormat:@"\n共 %lu 项\n", (unsigned long)files.count];
    }
    return r;
}

#pragma mark - 调试面板

@interface DPDebugVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@end

@implementation DPDebugVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"调试";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.tv = [[UITextView alloc] initWithFrame:CGRectZero];
    self.tv.editable = NO;
    self.tv.selectable = YES;
    self.tv.alwaysBounceVertical = YES;
    self.tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.tv.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tv];
    [NSLayoutConstraint activateConstraints:@[
        [self.tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(close)];
    [self reload];
}

- (void)reload {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *rep = DPBuildReport();
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.tv.text = rep;
            [UIPasteboard generalPasteboard].string = rep;
        });
    });
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - 穿透窗口 + 悬浮按钮

@interface DPWindow : UIWindow
@end

@implementation DPWindow
// 除按钮外，所有触摸都交给下面的 App，绝不吞事件
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

@interface DPController : NSObject
@property (nonatomic, strong) DPWindow *win;
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, assign) CGPoint startCenter;
+ (instancetype)shared;
- (void)install;
@end

@implementation DPController

+ (instancetype)shared {
    static DPController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DPController new]; });
    return s;
}

- (void)install {
    if (self.win) return;
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            sc.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)sc; break;
        }
    }
    DPWindow *w = scene ? [[DPWindow alloc] initWithWindowScene:scene]
                        : [[DPWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [UIViewController new];

    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 56, 56);
    b.backgroundColor = [UIColor colorWithRed:0.15 green:0.45 blue:0.95 alpha:0.85];
    [b setTitle:@"调试" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 28;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.3;
    b.layer.shadowRadius = 4;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    [b addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [b addGestureRecognizer:pan];

    b.center = CGPointMake(w.bounds.size.width - 48, w.bounds.size.height * 0.72);
    [w.rootViewController.view addSubview:b];
    w.hidden = NO;

    self.win = w;
    self.btn = b;
    os_log(gLog, "[DBG] 悬浮按钮已安装");
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.btn.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.startCenter = self.btn.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint c = CGPointMake(self.startCenter.x + t.x, self.startCenter.y + t.y);
        CGFloat half = self.btn.bounds.size.width / 2;
        CGFloat maxX = self.btn.superview.bounds.size.width - half;
        CGFloat maxY = self.btn.superview.bounds.size.height - half;
        c.x = MAX(half, MIN(maxX, c.x));
        c.y = MAX(half + 44, MIN(maxY, c.y));
        self.btn.center = c;
    } else if (g.state == UIGestureRecognizerStateEnded) {
        // 松手后吸附到左/右边缘
        CGFloat half = self.btn.bounds.size.width / 2;
        CGFloat w = self.btn.superview.bounds.size.width;
        CGPoint c = self.btn.center;
        c.x = (c.x < w / 2) ? half + 4 : w - half - 4;
        [UIView animateWithDuration:0.2 animations:^{ self.btn.center = c; }];
    }
}

- (void)tap {
    UIViewController *host = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w == self.win || w.hidden || w.alpha < 0.01) continue;
        if (w.isKeyWindow) { host = w.rootViewController; break; }
    }
    if (!host) {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w != self.win && w.rootViewController) { host = w.rootViewController; break; }
        }
    }
    if (!host) host = self.win.rootViewController;
    while (host.presentedViewController) host = host.presentedViewController;

    DPDebugVC *vc = [DPDebugVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [host presentViewController:nav animated:YES completion:nil];
}

@end

__attribute__((constructor)) static void DPInit(void) {
    gLog = os_log_create("com.rev.debugpanel", "general");
    os_log(gLog, "DebugPanel 1.0 已加载");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[DPController shared] install];
    });
}
