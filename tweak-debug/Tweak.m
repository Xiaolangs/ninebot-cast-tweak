// DebugLauncher — 主页悬浮按钮，打开 App 内置调试工具
//
// 零钩子：不使用 %hook，只在启动后创建一个可拖动悬浮按钮（穿透窗口，不拦其他触摸）。
//   单击 → 打开内置调试工具主页
//   长按 → 列出所有可用调试页供选择（同时把可用性打到 Console）
//
// 目标类（Swift，需用 Module.Class 形式取）：
//   Vehicle.VehicleDebugToolHomeVC      ← 车辆调试工具主页（主目标）
//   Common.DebugEntryViewController     ← 通用调试入口
//   Ninebot.FileDebugListViewController ← 文件调试工具
//   Vehicle.DynamicConfigListDebugVC    ← 动态配置调试
//   Vehicle.DynamicDebugSettingListVC   ← 动态调试设置
//   NBRouter.RouteDebugViewController   ← 路由调试
//   Vehicle.BleCommandDebugVC           ← 蓝牙指令调试

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t gLog = NULL;

typedef struct { const char *name; const char *title; } DPCand;

// 顺序即优先级：单击时取第一个可用的
static DPCand kCands[] = {
    {"Vehicle.VehicleDebugToolHomeVC",      "车辆调试工具主页"},
    {"Common.DebugEntryViewController",     "调试入口"},
    {"Ninebot.FileDebugListViewController", "文件调试工具"},
    {"Vehicle.DynamicConfigListDebugVC",    "动态配置调试"},
    {"Vehicle.DynamicDebugSettingListVC",   "动态调试设置"},
    {"NBRouter.RouteDebugViewController",   "路由调试"},
    {"Vehicle.BleCommandDebugVC",           "蓝牙指令调试"},
};
static const int kCandCount = sizeof(kCands) / sizeof(kCands[0]);

static Class DPClass(int i) {
    return NSClassFromString([NSString stringWithUTF8String:kCands[i].name]);
}

// Swift 类通常没有无参 init；逐种方式尝试，全部包在 @try 里
static UIViewController *DPMake(Class cls) {
    if (!cls) return nil;
    @try {
        if ([cls instancesRespondToSelector:@selector(init)]) {
            id o = [[cls alloc] init];
            if ([o isKindOfClass:[UIViewController class]]) return o;
        }
    } @catch (__unused NSException *e) {}
    @try {
        if ([cls instancesRespondToSelector:@selector(initWithNibName:bundle:)]) {
            id o = [[cls alloc] initWithNibName:nil bundle:nil];
            if ([o isKindOfClass:[UIViewController class]]) return o;
        }
    } @catch (__unused NSException *e) {}
    @try {
        if ([cls respondsToSelector:@selector(sharedInstance)]) {
            id o = [cls performSelector:@selector(sharedInstance)];
            if ([o isKindOfClass:[UIViewController class]]) return o;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static UIViewController *DPHost(void) {
    UIViewController *host = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        if (w.isKeyWindow) { host = w.rootViewController; break; }
    }
    if (!host) {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.rootViewController) { host = w.rootViewController; break; }
        }
    }
    while (host.presentedViewController) host = host.presentedViewController;
    return host;
}

static void DPPresent(int idx) {
    UIViewController *vc = DPMake(DPClass(idx));
    if (!vc) {
        os_log(gLog, "[DBG] 无法实例化 %{public}s", kCands[idx].name);
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"打开失败"
            message:[NSString stringWithFormat:@"%s 存在但无法直接实例化（可能需要参数）",
                     kCands[idx].name] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [DPHost() presentViewController:a animated:YES completion:nil];
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    os_log(gLog, "[DBG] 打开 %{public}s", kCands[idx].name);
    [DPHost() presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 穿透窗口

@interface DPWindow : UIWindow
@end
@implementation DPWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

@interface DPLauncher : NSObject
@property (nonatomic, strong) DPWindow *win;
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, assign) CGPoint startCenter;
@property (nonatomic, assign) BOOL dragged;
+ (instancetype)shared;
- (void)install;
@end

@implementation DPLauncher

+ (instancetype)shared {
    static DPLauncher *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DPLauncher new]; });
    return s;
}

- (void)install {
    if (self.win) return;
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            sc.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)sc; break; }
    }
    DPWindow *w = scene ? [[DPWindow alloc] initWithWindowScene:scene]
                        : [[DPWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [UIViewController new];

    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 54, 54);
    b.backgroundColor = [UIColor colorWithRed:0.95 green:0.35 blue:0.15 alpha:0.88];
    [b setTitle:@"调试" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 27;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.35; b.layer.shadowRadius = 4;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    [b addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    lp.minimumPressDuration = 0.6;
    [b addGestureRecognizer:lp];
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [b addGestureRecognizer:pan];

    b.center = CGPointMake(w.bounds.size.width - 46, w.bounds.size.height * 0.7);
    [w.rootViewController.view addSubview:b];
    w.hidden = NO;
    self.win = w; self.btn = b;

    // 启动时把可用性打到 Console，便于后续排查
    for (int i = 0; i < kCandCount; i++) {
        Class c = DPClass(i);
        os_log(gLog, "[DBG] %{public}s = %{public}s", kCands[i].name, c ? "存在" : "缺失");
    }
    os_log(gLog, "[DBG] 悬浮按钮已安装（单击开调试工具，长按选择）");
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.btn.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.startCenter = self.btn.center; self.dragged = NO;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (fabs(t.x) > 4 || fabs(t.y) > 4) self.dragged = YES;
        CGPoint c = CGPointMake(self.startCenter.x + t.x, self.startCenter.y + t.y);
        CGFloat half = self.btn.bounds.size.width / 2;
        c.x = MAX(half, MIN(self.btn.superview.bounds.size.width - half, c.x));
        c.y = MAX(half + 44, MIN(self.btn.superview.bounds.size.height - half, c.y));
        self.btn.center = c;
    } else if (g.state == UIGestureRecognizerStateEnded) {
        CGFloat half = self.btn.bounds.size.width / 2, w = self.btn.superview.bounds.size.width;
        CGPoint c = self.btn.center;
        c.x = (c.x < w / 2) ? half + 4 : w - half - 4;
        [UIView animateWithDuration:0.2 animations:^{ self.btn.center = c; }];
    }
}

- (void)tap {
    if (self.dragged) { self.dragged = NO; return; }
    for (int i = 0; i < kCandCount; i++) {
        if (DPMake(DPClass(i))) { DPPresent(i); return; }
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"未找到调试工具"
        message:@"内置调试类均不可用，请查看 Console 中的 [DBG] 日志" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [DPHost() presentViewController:a animated:YES completion:nil];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择调试页"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (int i = 0; i < kCandCount; i++) {
        Class c = DPClass(i);
        BOOL usable = (c != nil);
        NSString *t = [NSString stringWithFormat:@"%@%@", usable ? @"" : @"✗ ",
                       [NSString stringWithUTF8String:kCands[i].title]];
        UIAlertAction *act = [UIAlertAction actionWithTitle:t
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) { DPPresent(i); }];
        [sheet addAction:act];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.btn;
    sheet.popoverPresentationController.sourceRect = self.btn.bounds;
    [DPHost() presentViewController:sheet animated:YES completion:nil];
}

@end

__attribute__((constructor)) static void DPInit(void) {
    gLog = os_log_create("com.rev.debuglauncher", "general");
    os_log(gLog, "DebugLauncher 1.0 已加载");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [[DPLauncher shared] install]; });
}
