// DebugLauncher 2.0 — 点击首页「拥有爱车 第x天」文字，弹出 App 内置调试工具
//
// 零钩子：不使用 %hook。
//   1. 定时在视图树里找包含「拥有爱车」的 UILabel
//   2. 给该 label 挂 UITapGestureRecognizer（单击=打开调试工具主页，长按=选择其它调试页）
// 不建窗口、不挡触摸，只在 label 上附加手势。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t gLog = NULL;
static const NSInteger kDPTag = 0x44504247;   // 标记已挂载

#pragma mark - 调试页候选

typedef struct { const char *name; const char *title; } DPCand;

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

// Swift VC 通常没有无参 init；逐种方式尝试，全部包在 @try 里
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

static UIWindow *DPKeyWindow(void) {
    UIWindow *best = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        if (w.isKeyWindow) return w;
        if (!best && w.rootViewController) best = w;
    }
    return best;
}

static UIViewController *DPHost(void) {
    UIViewController *host = DPKeyWindow().rootViewController;
    while (host.presentedViewController) host = host.presentedViewController;
    return host;
}

static void DPPresentVC(UIViewController *vc, const char *name) {
    UIViewController *host = DPHost();
    if (!host) return;
    if (!vc) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"打开失败"
            message:@"该类存在但无法直接实例化（可能需要构造参数）"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    os_log(gLog, "[DBG] 打开 %{public}s", name);
    [host presentViewController:nav animated:YES completion:nil];
}

static void DPOpen(int idx) {
    Class c = DPClass(idx);
    if (!c) { os_log(gLog, "[DBG] 类缺失 %{public}s", kCands[idx].name); return; }
    UIViewController *vc = DPMake(c);
    if (!vc) os_log(gLog, "[DBG] 无法实例化 %{public}s", kCands[idx].name);
    DPPresentVC(vc, kCands[idx].name);
}

// 单击：取第一个可用的调试页
static void DPOpenFirstAvailable(void) {
    for (int i = 0; i < kCandCount; i++) {
        if (!DPClass(i)) continue;
        UIViewController *vc = DPMake(DPClass(i));
        if (vc) { DPPresentVC(vc, kCands[i].name); return; }
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"未找到调试工具"
        message:@"内置调试类均不可用，请查看 Console 中的 [DBG] 日志"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [DPHost() presentViewController:a animated:YES completion:nil];
}

#pragma mark - 手势目标

@interface DPTarget : NSObject
+ (instancetype)shared;
- (void)onTap:(UITapGestureRecognizer *)g;
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation DPTarget
+ (instancetype)shared {
    static DPTarget *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DPTarget new]; });
    return s;
}

- (void)onTap:(UITapGestureRecognizer *)g {
    os_log(gLog, "[DBG] 命中「拥有爱车」标签（单击）");
    DPOpenFirstAvailable();
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    os_log(gLog, "[DBG] 命中「拥有爱车」标签（长按）");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择调试页"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (int i = 0; i < kCandCount; i++) {
        BOOL usable = (DPClass(i) != nil);
        NSString *t = [NSString stringWithFormat:@"%@%@", usable ? @"" : @"✗ ",
                       [NSString stringWithUTF8String:kCands[i].title]];
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *x) { DPOpen(i); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = g.view;
    sheet.popoverPresentationController.sourceRect = g.view.bounds;
    [DPHost() presentViewController:sheet animated:YES completion:nil];
}
@end

#pragma mark - 视图树查找

static UILabel *DPFindLabel(UIView *view, NSString *needle, int depth) {
    if (!view || depth > 40) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)view;
        if (l.text.length && [l.text containsString:needle]) return l;
    }
    for (UIView *sv in view.subviews) {
        UILabel *hit = DPFindLabel(sv, needle, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static void DPInstallOnLabel(void) {
    UIWindow *w = DPKeyWindow();
    UIViewController *root = w.rootViewController;
    if (!root || !root.view) return;

    UILabel *l = DPFindLabel(root.view, @"拥有爱车", 0);
    if (!l) l = DPFindLabel(root.view, @"爱车", 0);
    if (!l) return;
    if (l.tag == kDPTag) return;         // 已挂载（含复用后的重复检测）

    l.tag = kDPTag;
    l.userInteractionEnabled = YES;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:[DPTarget shared] action:@selector(onTap:)];
    [l addGestureRecognizer:tap];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[DPTarget shared] action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.6;
    [l addGestureRecognizer:lp];

    os_log(gLog, "[DBG] ✅ 已挂载点击手势，label.text=「%{public}s」", l.text.UTF8String);
}

__attribute__((constructor)) static void DPInit(void) {
    gLog = os_log_create("com.rev.debuglauncher", "general");
    os_log(gLog, "DebugLauncher 2.0 已加载（点击「拥有爱车 第x天」打开调试工具）");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 启动时打印候选类可用性
        for (int i = 0; i < kCandCount; i++)
            os_log(gLog, "[DBG] %{public}s = %{public}s", kCands[i].name, DPClass(i) ? "存在" : "缺失");

        // 前 40 次（约 60 秒）每 1.5 秒扫一次，等 RN 首页渲染完；
        // 之后每 7 个 tick（约 10 秒）兜底一次，避免长期高频遍历视图树。
        __block int n = 0;
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES
                                                    block:^(__unused NSTimer *tm) {
            n++;
            if (n <= 40 || (n % 7) == 0) DPInstallOnLabel();
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    });
}
