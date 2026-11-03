// NoYidun — 固化「易盾加密开关」为关闭
//
// 背景：九号 App 正式包里有一组调试开关（VehicleDebugToolHomeVC.swift）：
//     易盾加密开关 ver = 4
//     易盾token开关
// 对应的 UserDefaults 键（从二进制同一字符串池确认，紧邻 ChannelKey/ServiceKey）：
//     network_new_encrypt_decrypt_enabled   ← 易盾加密开关
//     yidun_token_enabled                   ← 易盾token开关
//
// 现象：该开关打开时，请求走易盾签名/加密；重签名后拿不到合法 token，
//       所有业务请求鉴权失败 → 页面一直转圈。
//       手动关闭后立刻正常，但 App 重启会重置为开。
//
// 本 tweak 从三个层面固化：
//   ① 启动时写入 NO（持久化）
//   ② 拦截所有读取，强制返回「关」
//   ③ 拦截写入，禁止再被打开

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t gLog = NULL;

static NSString *const kEncryptKey = @"network_new_encrypt_decrypt_enabled";
static NSString *const kTokenKey   = @"yidun_token_enabled";

// 需要强制关闭的键（易盾加密开关）
static BOOL IsTargetKey(id key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [(NSString *)key isEqualToString:kEncryptKey];
}

#pragma mark - 读取拦截

static BOOL (*gOrigBool)(id, SEL, NSString *) = NULL;
static BOOL MyBoolForKey(id self, SEL _cmd, NSString *key) {
    if (IsTargetKey(key)) {
        os_log(gLog, "[YIDUN] 读取 %{public}s → 强制 NO", key.UTF8String);
        return NO;
    }
    return gOrigBool ? gOrigBool(self, _cmd, key) : NO;
}

static id (*gOrigObject)(id, SEL, NSString *) = NULL;
static id MyObjectForKey(id self, SEL _cmd, NSString *key) {
    if (IsTargetKey(key)) return @NO;
    return gOrigObject ? gOrigObject(self, _cmd, key) : nil;
}

static NSInteger (*gOrigInteger)(id, SEL, NSString *) = NULL;
static NSInteger MyIntegerForKey(id self, SEL _cmd, NSString *key) {
    if (IsTargetKey(key)) return 0;
    return gOrigInteger ? gOrigInteger(self, _cmd, key) : 0;
}

#pragma mark - 写入拦截

static void (*gOrigSetBool)(id, SEL, BOOL, NSString *) = NULL;
static void MySetBool(id self, SEL _cmd, BOOL value, NSString *key) {
    if (IsTargetKey(key)) {
        os_log(gLog, "[YIDUN] 拦截写入 %{public}s=%d（拒绝打开）", key.UTF8String, (int)value);
        if (gOrigSetBool) gOrigSetBool(self, _cmd, NO, key);   // 强制写 NO
        return;
    }
    if (gOrigSetBool) gOrigSetBool(self, _cmd, value, key);
}

static void (*gOrigSetObject)(id, SEL, id, NSString *) = NULL;
static void MySetObject(id self, SEL _cmd, id value, NSString *key) {
    if (IsTargetKey(key)) {
        os_log(gLog, "[YIDUN] 拦截 setObject %{public}s=%@（强制写 NO）", key.UTF8String, value);
        if (gOrigSetObject) gOrigSetObject(self, _cmd, @NO, key);
        return;
    }
    if (gOrigSetObject) gOrigSetObject(self, _cmd, value, key);
}

#pragma mark - 安装

static void Hook(Class cls, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { os_log(gLog, "[YIDUN] 未找到 %{public}s", sel_getName(sel)); return; }
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    os_log(gLog, "[YIDUN] 已挂 %{public}s", sel_getName(sel));
}

// 启动时把值写死为 NO（标准域 + 常见 suite 都写一遍）
static void ForceWriteOff(void) {
    NSArray *domains = @[[NSUserDefaults standardUserDefaults]];
    for (NSUserDefaults *ud in domains) {
        [ud setBool:NO forKey:kEncryptKey];
        [ud synchronize];
    }
    os_log(gLog, "[YIDUN] 启动写入 %{public}s = NO", kEncryptKey.UTF8String);
}

__attribute__((constructor)) static void YidunInit(void) {
    gLog = os_log_create("com.rev.noyidun", "general");
    os_log(gLog, "NoYidun 1.0 已加载（固化易盾加密开关为关）");

    Class c = objc_getClass("NSUserDefaults");
    Hook(c, sel_registerName("boolForKey:"),    (IMP)MyBoolForKey,    (IMP *)&gOrigBool);
    Hook(c, sel_registerName("objectForKey:"),  (IMP)MyObjectForKey,  (IMP *)&gOrigObject);
    Hook(c, sel_registerName("integerForKey:"), (IMP)MyIntegerForKey, (IMP *)&gOrigInteger);
    Hook(c, sel_registerName("setBool:forKey:"),     (IMP)MySetBool,   (IMP *)&gOrigSetBool);
    Hook(c, sel_registerName("setObject:forKey:"),   (IMP)MySetObject, (IMP *)&gOrigSetObject);

    // 稍后写一次（等 App 自己的配置初始化跑完，确保覆盖）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ForceWriteOff();
        BOOL v = [[NSUserDefaults standardUserDefaults] boolForKey:kEncryptKey];
        os_log(gLog, "[YIDUN] 当前读取值 = %d（应为 0）", (int)v);
    });
}
