// AppGroupShim — 修复重签名后 App Group / Keychain / UserDefaults 失效
//
// 依据 REPORT_无法联网根因分析.md：
//   原包 entitlements 有 com.apple.security.application-groups = [group.cn.ninebot.segway]
//   重签 profile 没有这个组 → containerURLForSecurityApplicationGroupIdentifier 返回 nil
//   → App 读不到登录态/共享配置 → 每个请求都没有有效身份 → 页面一直转圈
//
// 本 tweak 做三件事：
//   ① 把 group.cn.ninebot.segway 的容器目录重定向到沙盒 Documents/AppGroupShim
//   ② 把该组名的 NSUserDefaults suite 换成 shim 专属 suite（可持久化）
//   ③ 剥掉 Keychain 查询里的 kSecAttrAccessGroup，让凭证落到本包默认访问组
//
// 注意：Keychain 访问组变了，安装后需要重新登录一次，之后可跨重启保持。

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t gLog = NULL;
static NSString *const kGroup    = @"group.cn.ninebot.segway";
static NSString *const kShimSuite = @"nb.shim.groupsuite";
static NSString *const kShimDir   = @"AppGroupShim";
static int gGroupHit = 0, gSuiteHit = 0, gKeychainHit = 0;

#pragma mark - ① App Group 容器目录

static NSURL *(*gOrigContainerURL)(id, SEL, NSString *) = NULL;

static NSURL *MyContainerURL(id self, SEL _cmd, NSString *gid) {
    if ([gid isEqualToString:kGroup]) {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *dir = [docs stringByAppendingPathComponent:kShimDir];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if (gGroupHit++ < 5)
            os_log(gLog, "[AGS] ① App Group 重定向 %{public}s → 沙盒 AppGroupShim", gid.UTF8String);
        return [NSURL fileURLWithPath:dir isDirectory:YES];
    }
    return gOrigContainerURL ? gOrigContainerURL(self, _cmd, gid) : nil;
}

#pragma mark - ② NSUserDefaults suite

static id (*gOrigInitSuite)(id, SEL, NSString *) = NULL;

static id MyInitSuite(id self, SEL _cmd, NSString *suite) {
    if (suite && [suite isEqualToString:kGroup]) {
        if (gSuiteHit++ < 5)
            os_log(gLog, "[AGS] ② UserDefaults suite 替换 %{public}s → %{public}s",
                   suite.UTF8String, kShimSuite.UTF8String);
        return gOrigInitSuite(self, _cmd, kShimSuite);
    }
    return gOrigInitSuite(self, _cmd, suite);
}

#pragma mark - ③ Keychain 访问组

// 复制查询字典并去掉 kSecAttrAccessGroup；调用方负责 CFRelease
static CFDictionaryRef StripAccessGroup(CFDictionaryRef q) {
    if (!q) return NULL;
    if (!CFDictionaryContainsKey(q, kSecAttrAccessGroup)) return (CFDictionaryRef)CFRetain(q);
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, q);
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    return m;
}

typedef OSStatus (*SecItemFn)(CFDictionaryRef, ...);
extern OSStatus SecItemAdd(CFDictionaryRef, CFTypeRef *);
extern OSStatus SecItemCopyMatching(CFDictionaryRef, CFTypeRef *);
extern OSStatus SecItemUpdate(CFDictionaryRef, CFDictionaryRef);
extern OSStatus SecItemDelete(CFDictionaryRef);

static OSStatus MySecItemAdd(CFDictionaryRef attrs, CFTypeRef *result) {
    CFDictionaryRef q = StripAccessGroup(attrs);
    if (gKeychainHit++ < 5) os_log(gLog, "[AGS] ③ Keychain Add 已剥离 accessGroup");
    OSStatus st = SecItemAdd(q, result);
    if (q) CFRelease(q);
    return st;
}
static OSStatus MySecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef q = StripAccessGroup(query);
    OSStatus st = SecItemCopyMatching(q, result);
    if (q) CFRelease(q);
    return st;
}
static OSStatus MySecItemUpdate(CFDictionaryRef query, CFDictionaryRef attrs) {
    CFDictionaryRef q = StripAccessGroup(query);
    OSStatus st = SecItemUpdate(q, attrs);
    if (q) CFRelease(q);
    return st;
}
static OSStatus MySecItemDelete(CFDictionaryRef query) {
    CFDictionaryRef q = StripAccessGroup(query);
    OSStatus st = SecItemDelete(q);
    if (q) CFRelease(q);
    return st;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)MySecItemAdd,          (const void *)SecItemAdd },
    { (const void *)MySecItemCopyMatching, (const void *)SecItemCopyMatching },
    { (const void *)MySecItemUpdate,       (const void *)SecItemUpdate },
    { (const void *)MySecItemDelete,       (const void *)SecItemDelete },
};

#pragma mark - 安装

__attribute__((constructor)) static void AGSInit(void) {
    gLog = os_log_create("com.rev.agshim", "general");
    os_log(gLog, "AppGroupShim 1.0 已加载（group=%{public}s）", kGroup.UTF8String);

    Class fmc = objc_getClass("NSFileManager");
    SEL cs = sel_registerName("containerURLForSecurityApplicationGroupIdentifier:");
    Method cm = class_getInstanceMethod(fmc, cs);
    if (cm) {
        gOrigContainerURL = (NSURL *(*)(id, SEL, NSString *))method_getImplementation(cm);
        method_setImplementation(cm, (IMP)MyContainerURL);
        os_log(gLog, "[AGS] 已挂 containerURLForSecurityApplicationGroupIdentifier:");
    } else {
        os_log(gLog, "[AGS] ❌ 未找到 containerURLForSecurityApplicationGroupIdentifier:");
    }

    Class udc = objc_getClass("NSUserDefaults");
    SEL us = sel_registerName("initWithSuiteName:");
    Method um = class_getInstanceMethod(udc, us);
    if (um) {
        gOrigInitSuite = (id (*)(id, SEL, NSString *))method_getImplementation(um);
        method_setImplementation(um, (IMP)MyInitSuite);
        os_log(gLog, "[AGS] 已挂 initWithSuiteName:");
    } else {
        os_log(gLog, "[AGS] ❌ 未找到 initWithSuiteName:");
    }
}
