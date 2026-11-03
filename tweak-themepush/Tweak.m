// ThemePush — 选本地 .rfs 皮肤文件，走官方两步：fileTransfer → fileSet 激活
//
// iOS 与 Android 完全对齐（已从二进制确认）：
//   Vehicle.RNFileManagerModule.fileTransfer:            ← 传文件（参数 JSON）
//   Vehicle.RNBleModule.writeBleModuleCmdResponse:       ← 发 BLE 命令（fileSet 激活）
//   startUpload(binContent:index:module:fileCode:fileVersion:channel:transferProtocol:customLength:instrumentType:)
//   事件名 crcCheckUpdateChanged / fileTransUpdateChanged 同样存在
//
// 用法：
//   点「皮肤」按钮 → 选 .rfs（或含 .rfs 的 zip）→ 自动发起 fileTransfer
//   长按按钮 → 「发送 fileSet 激活」/「设置参数」

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

static os_log_t gLog = NULL;
static id gFileModule = nil;      // RNFileManagerModule 实例（保活）
static id gBleModule  = nil;      // RNBleModule 实例（保活）

// 默认参数（对应 F43 仪表主题：resourceCode=0x16B, resourceVersion=0x371）
static NSInteger gFileCode    = 0x16B;
static NSInteger gFileVersion = 0x371;
static NSInteger gIndex       = 1;      // 资源域：仪表=1
static NSInteger gChannel     = 1;      // 1=BLE 2=WiFi
static NSInteger gProtocol    = 1;
static NSInteger gInstrument  = 2;
static NSString *gModuleName  = @"tft";

#pragma mark - 基础

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
    UIViewController *h = KeyWindow().rootViewController;
    while (h.presentedViewController) h = h.presentedViewController;
    return h;
}
static NSString *Docs(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

// RN 模块实例：只使用「RN 自己创建的真实实例」。
// 绝不能自建 —— Swift RN 模块依赖 bridge 注入，alloc/init 出来的空壳一调用必崩。
static id gCapturedFileModule = nil;
static id gCapturedBleModule  = nil;

static void CaptureInit(Class cls, BOOL isBle) {
    if (!cls) return;
    SEL initSel = sel_registerName("init");
    Method m = class_getInstanceMethod(cls, initSel);
    if (!m) { os_log(gLog, "[TP] %{public}s 无 -init", class_getName(cls)); return; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^id(id self) {
        id r = ((id (*)(id, SEL))orig)(self, initSel);
        if (r) {
            if (isBle) gCapturedBleModule = r; else gCapturedFileModule = r;
            os_log(gLog, "[TP] ✅ 捕获真实 RN 模块 %{public}s", class_getName(object_getClass(r)));
        }
        return r;
    }));
    os_log(gLog, "[TP] 已挂 -init 捕获 %{public}s", class_getName(cls));
}

static id FindRNModule(NSString *clsName, BOOL isBle) {
    id cap = isBle ? gCapturedBleModule : gCapturedFileModule;
    if (cap) return cap;

    Class c = NSClassFromString(clsName);
    Class bcls = NSClassFromString(@"RCTBridge");
    if (c && bcls) {
        SEL cur = NSSelectorFromString(@"currentBridge");
        if ([bcls respondsToSelector:cur]) {
            @try {
                id bridge = ((id(*)(id,SEL))objc_msgSend)(bcls, cur);
                if (bridge) {
                    for (NSString *selName in @[@"moduleForClass:", @"moduleForName:"]) {
                        SEL m = NSSelectorFromString(selName);
                        if (![bridge respondsToSelector:m]) continue;
                        id o = [selName isEqualToString:@"moduleForClass:"]
                             ? ((id(*)(id,SEL,Class))objc_msgSend)(bridge, m, c)
                             : ((id(*)(id,SEL,id))objc_msgSend)(bridge, m, clsName);
                        if (o) {
                            if (isBle) gCapturedBleModule = o; else gCapturedFileModule = o;
                            os_log(gLog, "[TP] 从 bridge 取到 %{public}s", clsName.UTF8String);
                            return o;
                        }
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return nil;
}

#pragma mark - 安全调用（RN 模块必须在其 methodQueue 上调用）

static void RunOnModuleQueue(id module, dispatch_block_t block) {
    dispatch_queue_t q = nil;
    SEL sel = NSSelectorFromString(@"methodQueue");
    if (module && [module respondsToSelector:sel]) {
        @try { q = ((dispatch_queue_t (*)(id, SEL))objc_msgSend)(module, sel); } @catch (__unused NSException *e) {}
    }
    if (q) {
        os_log(gLog, "[TP] 在模块 methodQueue 上执行");
        dispatch_async(q, block);
    } else {
        os_log(gLog, "[TP] 无 methodQueue，退回主线程");
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

// 文件体检：大小 + 头部十六进制，过小直接拦下（避免 Swift 强解包崩溃）
static BOOL InspectFile(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) { os_log(gLog, "[TP] ❌ 读不到文件"); return NO; }
    NSUInteger n = d.length;
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < MIN((NSUInteger)24, n); i++) [hex appendFormat:@"%02x", b[i]];
    os_log(gLog, "[TP] 文件 %lu B  头部=%{public}s", (unsigned long)n, hex.UTF8String);
    if (n < 64) {
        os_log(gLog, "[TP] ❌ 文件仅 %lu 字节，不可能是有效 .rfs，已中止", (unsigned long)n);
        return NO;
    }
    return YES;
}

#pragma mark - 两步

static void SendFileSet(void) {
    gBleModule = FindRNModule(@"_TtC7Vehicle11RNBleModule", YES);
    if (!gBleModule) gBleModule = FindRNModule(@"Vehicle.RNBleModule", YES);
    if (!gBleModule) {
        os_log(gLog, "[TP] ❌ 尚未捕获到 RNBleModule 实例");
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"模块未就绪"
            message:@"请先打开一次「皮肤商店 / 主题中心」让 RN 创建模块，再重试"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [TopVC() presentViewController:a animated:YES completion:nil];
        return;
    }

    // data = [code u32 LE] + [ver u16 LE]
    uint32_t code = (uint32_t)gFileCode;
    uint16_t ver  = (uint16_t)gFileVersion;
    NSMutableArray *data = [NSMutableArray array];
    for (int i = 0; i < 4; i++) [data addObject:@((code >> (i*8)) & 0xFF)];
    for (int i = 0; i < 2; i++) [data addObject:@((ver  >> (i*8)) & 0xFF)];

    // CSV 799: dis,fileSet,write,s_index=1,s_cmd=139,r_cmd=139,proto=5AA5,timeout=5000
    NSDictionary *p = @{@"moduleName": gModuleName,
                        @"cmd": @"fileSet",
                        @"index": [NSString stringWithFormat:@"%ld", (long)gIndex],
                        @"data": data,
                        @"timeOut": @5000};
    NSData *j = [NSJSONSerialization dataWithJSONObject:p options:0 error:nil];
    NSString *s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    os_log(gLog, "[TP] → fileSet %{public}s", s.UTF8String);

    SEL sel = NSSelectorFromString(@"writeBleModuleCmdResponse:");
    if (![gBleModule respondsToSelector:sel]) { os_log(gLog, "[TP] ❌ 无 writeBleModuleCmdResponse:"); return; }
    id mod = gBleModule; NSString *payload = s;
    RunOnModuleQueue(mod, ^{
        @try { ((void(*)(id,SEL,id))objc_msgSend)(mod, sel, payload); }
        @catch (NSException *e) { os_log(gLog, "[TP] fileSet 异常: %{public}s", e.reason.UTF8String); }
    });
}

static void SendFileTransfer(NSString *localPath) {
    if (!InspectFile(localPath)) return;
    gFileModule = FindRNModule(@"_TtC7Vehicle19RNFileManagerModule", NO);
    if (!gFileModule) gFileModule = FindRNModule(@"Vehicle.RNFileManagerModule", NO);
    if (!gFileModule) {
        os_log(gLog, "[TP] ❌ 尚未捕获到 RNFileManagerModule 实例（拒绝自建，避免闪退）");
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"模块未就绪"
            message:@"请先进入「主题中心」浏览一次，让 RN 创建文件传输模块后重试"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [TopVC() presentViewController:a animated:YES completion:nil];
        return;
    }

    // iOS 的 RNFileManagerModule 第一参数是 binContent（安卓才是 localUrl），
    // 两个都给，读哪个都能拿到。
    NSData *fileData = [NSData dataWithContentsOfFile:localPath];
    NSString *b64 = [fileData base64EncodedStringWithOptions:0] ?: @"";
    os_log(gLog, "[TP] binContent base64 长度 %lu（原始 %lu B）",
           (unsigned long)b64.length, (unsigned long)fileData.length);

    NSDictionary *p = @{@"localUrl": localPath,
                        @"binContent": b64,
                        @"index": @(gIndex),
                        @"module": gModuleName,
                        @"fileCode": @(gFileCode),
                        @"fileVersion": @(gFileVersion),
                        @"addHeader": @NO,
                        @"transferProtocol": @(gProtocol),
                        @"channel": @(gChannel),
                        @"instrumentType": @(gInstrument),
                        @"customLength": @(-1)};
    NSData *j = [NSJSONSerialization dataWithJSONObject:p options:0 error:nil];
    NSString *s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    os_log(gLog, "[TP] → fileSet %{public}s", s.UTF8String);

    SEL sel = NSSelectorFromString(@"writeBleModuleCmdResponse:");
    if (![gBleModule respondsToSelector:sel]) { os_log(gLog, "[TP] ❌ 无 writeBleModuleCmdResponse:"); return; }
    id mod = gBleModule; NSString *payload = s;
    RunOnModuleQueue(mod, ^{
        @try { ((void(*)(id,SEL,id))objc_msgSend)(mod, sel, payload); }
        @catch (NSException *e) { os_log(gLog, "[TP] fileSet 异常: %{public}s", e.reason.UTF8String); }
    });
}

static void SendFileTransfer(NSString *localPath) {
    if (!InspectFile(localPath)) return;
    gFileModule = FindRNModule(@"_TtC7Vehicle19RNFileManagerModule", NO);
    if (!gFileModule) gFileModule = FindRNModule(@"Vehicle.RNFileManagerModule", NO);
    if (!gFileModule) {
        os_log(gLog, "[TP] ❌ 尚未捕获到 RNFileManagerModule 实例（拒绝自建，避免闪退）");
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"模块未就绪"
            message:@"请先进入「主题中心」浏览一次，让 RN 创建文件传输模块后重试"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [TopVC() presentViewController:a animated:YES completion:nil];
        return;
    }

    NSDictionary *p = @{@"localUrl": localPath,
                        @"index": @(gIndex),
                        @"module": gModuleName,
                        @"fileCode": @(gFileCode),
                        @"fileVersion": @(gFileVersion),
                        @"addHeader": @NO,
                        @"transferProtocol": @(gProtocol),
                        @"channel": @(gChannel),
                        @"instrumentType": @(gInstrument),
                        @"customLength": @(-1)};
    NSData *j = [NSJSONSerialization dataWithJSONObject:p options:0 error:nil];
    NSString *s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    os_log(gLog, "[TP] → fileTransfer %{public}s", s.UTF8String);

    SEL sel = NSSelectorFromString(@"fileTransfer:");
    if (![gFileModule respondsToSelector:sel]) { os_log(gLog, "[TP] ❌ 无 fileTransfer:"); return; }
    id mod = gFileModule; NSString *payload = s;
    RunOnModuleQueue(mod, ^{
        @try { ((void(*)(id,SEL,id))objc_msgSend)(mod, sel, payload); }
        @catch (NSException *e) { os_log(gLog, "[TP] fileTransfer 异常: %{public}s", e.reason.UTF8String); }
    });
}

#pragma mark - 从文件名解析资源码/版本

// 主题包内 .rfs 命名规范：<资源码8位HEX>_<版本4位HEX>.rfs
// 例：0000016b_0371.rfs  →  fileCode=0x16B(363)  fileVersion=0x371(881)
static BOOL ParseRFSName(NSString *fileName, NSInteger *code, NSInteger *ver) {
    NSString *base = fileName.stringByDeletingPathExtension;
    NSArray *parts = [base componentsSeparatedByString:@"_"];
    if (parts.count < 2) return NO;
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSString *a = parts[0], *b = parts[1];
    if (a.length == 0 || b.length == 0) return NO;
    if ([a stringByTrimmingCharactersInSet:hexSet].length) return NO;
    if ([b stringByTrimmingCharactersInSet:hexSet].length) return NO;
    unsigned long long c = 0, v = 0;
    if (![[NSScanner scannerWithString:a] scanHexLongLong:&c]) return NO;
    if (![[NSScanner scannerWithString:b] scanHexLongLong:&v]) return NO;
    *code = (NSInteger)c; *ver = (NSInteger)v;
    return YES;
}

// 解析不出来时，让用户手填（预填当前值）
static void AskParamsThenSend(NSString *path) {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"填写资源信息"
        message:[NSString stringWithFormat:@"文件名无法解析：%@\n请输入十六进制资源码与版本", path.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"fileCode (HEX)";
        t.text = [NSString stringWithFormat:@"%lX", (long)gFileCode];
        t.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"fileVersion (HEX)";
        t.text = [NSString stringWithFormat:@"%lX", (long)gFileVersion];
        t.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        NSInteger c = 0, v = 0;
        [[NSScanner scannerWithString:a.textFields[0].text] scanHexLongLong:(unsigned long long *)&c];
        [[NSScanner scannerWithString:a.textFields[1].text] scanHexLongLong:(unsigned long long *)&v];
        gFileCode = c; gFileVersion = v;
        os_log(gLog, "[TP] 手动设定 code=0x%lX(%ld) ver=0x%lX(%ld)",
               (long)gFileCode, (long)gFileCode, (long)gFileVersion, (long)gFileVersion);
        SendFileTransfer(path);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [TopVC() presentViewController:a animated:YES completion:nil];
}

#pragma mark - 解压（zip 里找 .rfs）

static NSString *FindRFSInDir(NSString *dir) {
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:dir];
    NSString *rel;
    while ((rel = [e nextObject])) {
        if ([rel.pathExtension.lowercaseString isEqualToString:@"rfs"])
            return [dir stringByAppendingPathComponent:rel];
    }
    return nil;
}

#pragma mark - 文件选择

@interface TPProvider : NSObject <UIDocumentPickerDelegate>
+ (instancetype)shared;
- (void)pick;
@end

@implementation TPProvider
+ (instancetype)shared {
    static TPProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TPProvider new]; });
    return s;
}
- (void)pick {
    UIDocumentPickerViewController *vc =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item", @"public.data", @"public.zip-archive"]
                                                               inMode:UIDocumentPickerModeImport];
    vc.delegate = self; vc.allowsMultipleSelection = NO;
    [TopVC() presentViewController:vc animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject; if (!u) return;
    NSString *dir = [Docs() stringByAppendingPathComponent:@"ThemePush"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:u.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    BOOL scoped = [u startAccessingSecurityScopedResource];
    NSError *err = nil;
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:&err];
    if (scoped) [u stopAccessingSecurityScopedResource];
    if (!ok) { os_log(gLog, "[TP] ❌ 拷贝失败 %{public}s", err.localizedDescription.UTF8String); return; }

    os_log(gLog, "[TP] 已保存 %{public}s", dst.lastPathComponent.UTF8String);

    // 选中的不是 .rfs 时，尝试在 ThemePush 目录里找现成的 .rfs
    NSString *target = dst;
    if (![dst.pathExtension.lowercaseString isEqualToString:@"rfs"]) {
        NSString *found = FindRFSInDir(dir);
        if (found) {
            os_log(gLog, "[TP] 选中非 .rfs，改用已存在的 %{public}s", found.lastPathComponent.UTF8String);
            target = found;
        } else {
            os_log(gLog, "[TP] ⚠️ 只接受 .rfs。请把主题包解压后选其中的 .rfs（iOS 不内置解压）");
        }
    }
    // 从文件名自动取资源码/版本（文件名本身就是 <code>_<ver>.rfs）
    NSInteger rc = 0, rv = 0;
    if (ParseRFSName(target.lastPathComponent, &rc, &rv)) {
        gFileCode = rc; gFileVersion = rv;
        os_log(gLog, "[TP] 自动识别 code=0x%lX(%ld) ver=0x%lX(%ld)  来自文件名 %{public}s",
               (long)rc, (long)rc, (long)rv, (long)rv, target.lastPathComponent.UTF8String);
    } else {
        os_log(gLog, "[TP] ⚠️ 文件名不符合 <code>_<ver>.rfs，改为手动填写");
        AskParamsThenSend(target);
        return;
    }
    SendFileTransfer(target);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c { os_log(gLog, "[TP] 已取消"); }
@end

#pragma mark - 按钮

@interface TPButton : NSObject
@property (nonatomic, strong) UIButton *btn;
+ (instancetype)shared;
- (void)install; - (void)keepAlive;
@end

@implementation TPButton
+ (instancetype)shared {
    static TPButton *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TPButton new]; });
    return s;
}
- (void)install {
    if (self.btn && self.btn.superview) return;
    UIWindow *w = KeyWindow(); if (!w) return;
    if (!self.btn) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, 54, 54);
        b.backgroundColor = [UIColor colorWithRed:0.95 green:0.55 blue:0.15 alpha:0.9];
        [b setTitle:@"皮肤" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.layer.cornerRadius = 27;
        b.layer.shadowColor = UIColor.blackColor.CGColor;
        b.layer.shadowOpacity = 0.3; b.layer.shadowRadius = 4;
        b.layer.shadowOffset = CGSizeMake(0, 2);
        [b addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
        lp.minimumPressDuration = 0.6;
        [b addGestureRecognizer:lp];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [b addGestureRecognizer:pan];
        b.center = CGPointMake(w.bounds.size.width - 48, w.bounds.size.height * 0.5);
        self.btn = b;
    }
    [w addSubview:self.btn]; [w bringSubviewToFront:self.btn];
}
- (void)keepAlive { if (!self.btn || !self.btn.superview) [self install]; }
- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.btn.superview];
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint c = CGPointMake(self.btn.center.x + t.x, self.btn.center.y + t.y);
        c.x = MAX(27, MIN(self.btn.superview.bounds.size.width - 27, c.x));
        c.y = MAX(71, MIN(self.btn.superview.bounds.size.height - 27, c.y));
        self.btn.center = c;
        [g setTranslation:CGPointZero inView:self.btn.superview];
    }
}
- (void)tap { [[TPProvider shared] pick]; }
- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"皮肤推送"
        message:[NSString stringWithFormat:@"module=%@ index=%ld code=0x%lX ver=0x%lX channel=%ld",
                 gModuleName, (long)gIndex, (long)gFileCode, (long)gFileVersion, (long)gChannel]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"发送 fileSet（激活）" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *x) { SendFileSet(); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"修改 fileCode / fileVersion" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *x) { [self editParams]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.btn;
    a.popoverPresentationController.sourceRect = self.btn.bounds;
    [TopVC() presentViewController:a animated:YES completion:nil];
}
- (void)editParams {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"参数"
        message:@"fileCode(十进制) / fileVersion(十进制)" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"fileCode"; t.text = [NSString stringWithFormat:@"%ld", (long)gFileCode];
        t.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"fileVersion"; t.text = [NSString stringWithFormat:@"%ld", (long)gFileVersion];
        t.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        gFileCode = [a.textFields[0].text integerValue];
        gFileVersion = [a.textFields[1].text integerValue];
        os_log(gLog, "[TP] 参数已更新 code=%ld ver=%ld", (long)gFileCode, (long)gFileVersion);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [TopVC() presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - 录制 App 自身的调用（用于比对我们下发的参数）

static IMP gOrigFT = NULL;
static IMP gOrigBle = NULL;

static void MyFileTransfer(id self, SEL _cmd, id params) {
    os_log(gLog, "[TP] 📥 App 自身调用 fileTransfer: %{public}s", [[params description] UTF8String]);
    if (gOrigFT) ((void (*)(id, SEL, id))gOrigFT)(self, _cmd, params);
}
static void MyBleCmdResponse(id self, SEL _cmd, id params) {
    os_log(gLog, "[TP] 📥 App 自身调用 writeBleModuleCmdResponse: %{public}s", [[params description] UTF8String]);
    if (gOrigBle) ((void (*)(id, SEL, id))gOrigBle)(self, _cmd, params);
}

static void InstallRecorders(void) {
    for (NSString *cn in @[@"_TtC7Vehicle19RNFileManagerModule", @"Vehicle.RNFileManagerModule"]) {
        Class c = NSClassFromString(cn); if (!c) continue;
        Method m = class_getInstanceMethod(c, sel_registerName("fileTransfer:"));
        if (m && !gOrigFT) { gOrigFT = method_setImplementation(m, (IMP)MyFileTransfer);
            os_log(gLog, "[TP] 已挂 fileTransfer: 录制"); break; }
    }
    for (NSString *cn in @[@"_TtC7Vehicle11RNBleModule", @"Vehicle.RNBleModule"]) {
        Class c = NSClassFromString(cn); if (!c) continue;
        Method m = class_getInstanceMethod(c, sel_registerName("writeBleModuleCmdResponse:"));
        if (m && !gOrigBle) { gOrigBle = method_setImplementation(m, (IMP)MyBleCmdResponse);
            os_log(gLog, "[TP] 已挂 writeBleModuleCmdResponse: 录制"); break; }
    }
}

__attribute__((constructor)) static void TPInit(void) {
    gLog = os_log_create("com.rev.themepush", "general");
    os_log(gLog, "ThemePush 1.6 已加载（改用 binContent 传文件内容）");
    // 立刻挂捕获钩子 —— 必须早于 RN bridge 创建模块
    CaptureInit(NSClassFromString(@"_TtC7Vehicle19RNFileManagerModule"), NO);
    CaptureInit(NSClassFromString(@"Vehicle.RNFileManagerModule"), NO);
    CaptureInit(NSClassFromString(@"_TtC7Vehicle11RNBleModule"), YES);
    CaptureInit(NSClassFromString(@"Vehicle.RNBleModule"), YES);
    InstallRecorders();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class fm = NSClassFromString(@"_TtC7Vehicle19RNFileManagerModule");
        Class bm = NSClassFromString(@"_TtC7Vehicle11RNBleModule");
        if (fm) {
            unsigned int n = 0; Method *ms = class_copyMethodList(fm, &n);
            NSMutableString *ml = [NSMutableString string];
            for (unsigned int i = 0; i < n; i++) [ml appendFormat:@"%s  ", sel_getName(method_getName(ms[i]))];
            free(ms);
            os_log(gLog, "[TP] RNFileManagerModule 方法(%u): %{public}s", n, ml.UTF8String);
        }
        os_log(gLog, "[TP] RNFileManagerModule=%{public}s RNBleModule=%{public}s",
               fm ? "有" : "无", bm ? "有" : "无");
        [[TPButton shared] install];
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
            block:^(__unused NSTimer *tm){ [[TPButton shared] keepAlive]; }];
        [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    });
}
