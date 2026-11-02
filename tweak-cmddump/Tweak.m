// CmdDump — 打开「蓝牙指令调试」页时，自动把指令集 dump 成 JSON
//
// 做法：hook _TtC7Vehicle17BleCommandDebugVC 的 viewDidAppear:，
//       延迟 1.5 秒后用运行时反射遍历该 VC 的所有 ivar，
//       递归找出所有 DebugCommandConfigModel / DebugCommandConfigsModel 实例，
//       把每个属性读出来写入 Documents/BleCmdSet.json，并在 Console 打印摘要。
//
// 只在这一个页面出现时执行，频率极低，安全。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t gLog = NULL;
static IMP gOrigViewDidAppear = NULL;

#pragma mark - 反射 dump

static BOOL IsCmdClass(Class c) {
    if (!c) return NO;
    NSString *n = NSStringFromClass(c);
    return [n containsString:@"DebugCommandConfig"] || [n containsString:@"BleCommand"];
}

// 读取一个 ivar 的值（对象或基本类型都尽量转成可序列化值）
static id ReadIvar(id obj, Ivar iv) {
    const char *t = ivar_getTypeEncoding(iv);
    if (!t) return nil;
    if (t[0] == '@') {
        @try { id v = object_getIvar(obj, iv); return v; } @catch (__unused NSException *e) { return nil; }
    }
    ptrdiff_t off = ivar_getOffset(iv);
    void *base = (__bridge void *)obj;
    switch (t[0]) {
        case 'c': return @(*(char *)((char *)base + off));
        case 'B': return @(*(BOOL *)((char *)base + off));
        case 's': return @(*(short *)((char *)base + off));
        case 'i': return @(*(int *)((char *)base + off));
        case 'l': return @(*(long *)((char *)base + off));
        case 'q': return @(*(long long *)((char *)base + off));
        case 'f': return @(*(float *)((char *)base + off));
        case 'd': return @(*(double *)((char *)base + off));
        default: return nil;
    }
}

// 递归收集：遇到命令对象就整条读出，遇到数组/字典就继续往下钻
static void Collect(id obj, NSString *hint, NSMutableArray *out, int depth) {
    if (!obj || depth > 4 || out.count > 3000) return;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)obj;
        for (id e in a) Collect(e, hint, out, depth + 1);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, __unused BOOL *stop) {
            Collect(v, hint, out, depth + 1);
        }];
        return;
    }
    Class cls = object_getClass(obj);
    if (cls && IsCmdClass(cls)) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"_class"] = NSStringFromClass(cls);
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivs[i])] ?: @"?";
            id v = ReadIvar(obj, ivs[i]);
            if (v) {
                if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]])
                    d[name] = v;
                else if ([v isKindOfClass:[NSArray class]])
                    d[name] = @[ @"(array)" , @([(NSArray *)v count]) ];
                else
                    d[name] = [NSString stringWithFormat:@"<%@>", NSStringFromClass(object_getClass(v))];
                // 数组里若也是命令对象，继续钻
                if ([v isKindOfClass:[NSArray class]]) Collect(v, hint, out, depth + 1);
            }
        }
        free(ivs);
        [out addObject:d];
        return;
    }
    // 普通容器对象：继续看它的 ivar
    if (depth < 2) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(ivs[i]);
            if (t && t[0] == '@') Collect(ReadIvar(obj, ivs[i]), hint, out, depth + 1);
        }
        free(ivs);
    }
}

static NSString *DocPath(NSString *name) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:name];
}

static void DumpFromVC(UIViewController *vc) {
    NSMutableArray *out = [NSMutableArray array];
    Collect(vc, @"vc", out, 0);

    if (!out.count) {
        os_log(gLog, "[CMD] 未在页面上找到指令对象（可能尚未加载完成，可再次进入本页）");
        return;
    }
    NSDictionary *wrap = @{@"count": @(out.count), @"items": out,
                           @"dumpedAt": [NSDate date].description ?: @""};
    NSData *json = [NSJSONSerialization dataWithJSONObject:wrap
                     options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSString *path = DocPath(@"BleCmdSet.json");
    [json writeToFile:path atomically:YES];
    os_log(gLog, "[CMD] ✅ 已导出 %lu 条指令 → %{public}s",
           (unsigned long)out.count, path.UTF8String);

    // Console 里也打一份精简清单（alias + 关键字段）
    int shown = 0;
    for (NSDictionary *d in out) {
        if (shown++ >= 40) break;
        NSString *alias = [d[@"alias"] description] ?: @"";
        NSString *mod   = [d[@"sendModuleValue"] description] ?: @"";
        NSString *cmd   = [d[@"sendCMDValue"] description] ?: @"";
        NSString *idx   = [d[@"sendIndexValue"] description] ?: @"";
        NSString *data  = [d[@"sendDataContent"] description] ?: @"";
        os_log(gLog, "[CMD] alias=%{public}s mod=%{public}s cmd=%{public}s idx=%{public}s data=%{public}s",
               alias.UTF8String, mod.UTF8String, cmd.UTF8String,
               idx.UTF8String, data.UTF8String);
    }
}

#pragma mark - hook

static void MyViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) ((void (*)(id, SEL, BOOL))gOrigViewDidAppear)(self, _cmd, animated);
    os_log(gLog, "[CMD] 蓝牙指令调试页已出现，1.5 秒后开始 dump");
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id vc = weakSelf;
        if (vc) DumpFromVC(vc);
    });
}

__attribute__((constructor)) static void CmdDumpInit(void) {
    gLog = os_log_create("com.rev.cmddump", "general");
    os_log(gLog, "CmdDump 1.0 已加载（打开蓝牙指令调试页即自动导出）");

    // 打印模型类结构，便于确认字段
    for (NSString *cn in @[@"_TtC7Vehicle23DebugCommandConfigModel",
                           @"_TtC7Vehicle24DebugCommandConfigsModel",
                           @"_TtC7Vehicle17BleCommandDebugVC"]) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) { os_log(gLog, "[CMD] %{public}s 缺失", cn.UTF8String); continue; }
        NSMutableString *fields = [NSMutableString string];
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            [fields appendFormat:@"%s(%s) ", ivar_getName(ivs[i]), ivar_getTypeEncoding(ivs[i])];
        }
        free(ivs);
        os_log(gLog, "[CMD] %{public}s 字段: %{public}s", cn.UTF8String, fields.UTF8String);
    }

    Class vcCls = objc_getClass("_TtC7Vehicle17BleCommandDebugVC");
    if (vcCls) {
        SEL s = sel_registerName("viewDidAppear:");
        Method m = class_getInstanceMethod(vcCls, s);
        if (m) {
            gOrigViewDidAppear = method_setImplementation(m, (IMP)MyViewDidAppear);
            os_log(gLog, "[CMD] 已 hook BleCommandDebugVC viewDidAppear:");
        } else {
            os_log(gLog, "[CMD] BleCommandDebugVC 无 viewDidAppear:，尝试 viewDidLoad");
            SEL s2 = sel_registerName("viewDidLoad");
            Method m2 = class_getInstanceMethod(vcCls, s2);
            if (m2) {
                static IMP origLoad;
                origLoad = method_setImplementation(m2, imp_implementationWithBlock(^(id self2){
                    ((void (*)(id, SEL))origLoad)(self2, s2);
                    os_log(gLog, "[CMD] 蓝牙指令调试页 viewDidLoad");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ DumpFromVC(self2); });
                }));
            }
        }
    } else {
        os_log(gLog, "[CMD] 未找到 BleCommandDebugVC，可能类名不同");
    }
}
