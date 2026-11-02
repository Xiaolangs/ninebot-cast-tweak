// CmdDump 1.2 — 从 DynamicTool 单例 / 管理器 里取指令集
//
// 1.1 发现：BleCommandDebugVC 自身没有任何 ivar，数据不在 VC 上。
// 二进制证据：NBDynamicModule.DynamicTool 的字段里有
//     deviceCommands · commandDict · deviceConfig · deviceEvents · serverResouce
// 所以从 DynamicTool 单例（或任何持有它的对象）取。
//
// 触发：进入「蓝牙指令调试」页 → 2.5 秒后扫描
// 产出：Documents/BleCmdDump.json + Console 摘要

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

static os_log_t gLog = NULL;
static IMP gOrigViewDidAppear = NULL;

#pragma mark - 序列化

static id ReadIvar(id obj, Ivar iv) {
    const char *t = ivar_getTypeEncoding(iv);
    if (!t) return nil;
    if (t[0] == '@') { @try { return object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; } }
    ptrdiff_t off = ivar_getOffset(iv);
    char *base = (char *)(__bridge void *)obj;
    switch (t[0]) {
        case 'c': return @(*(char *)(base+off));
        case 'B': return @(*(BOOL *)(base+off));
        case 's': return @(*(short *)(base+off));
        case 'i': return @(*(int *)(base+off));
        case 'l': return @(*(long *)(base+off));
        case 'q': return @(*(long long *)(base+off));
        case 'f': return @(*(float *)(base+off));
        case 'd': return @(*(double *)(base+off));
        default:  return nil;
    }
}

static NSString *CN(id o) { return o ? NSStringFromClass(object_getClass(o)) : @""; }

// 递归序列化任意对象（限深、防环）
static id Ser(id obj, int depth, NSMutableSet *seen) {
    if (!obj || depth > 4) return nil;
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) return obj;
    if ([obj isKindOfClass:[NSNull class]]) return [NSNull null];
    if ([seen containsObject:[NSValue valueWithNonretainedObject:obj]]) return @"(cycle)";
    [seen addObject:[NSValue valueWithNonretainedObject:obj]];

    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id e in (NSArray *)obj) [a addObject:Ser(e, depth+1, seen) ?: [NSNull null]];
        return a;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, __unused BOOL *s) {
            d[[k description]] = Ser(v, depth+1, seen) ?: [NSNull null];
        }];
        return d;
    }
    if ([obj isKindOfClass:[NSData class]]) {
        return [NSString stringWithFormat:@"<NSData %luB>", (unsigned long)[(NSData *)obj length]];
    }
    // 自定义对象：读它的 ivar
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"_class"] = CN(obj);
    unsigned int n = 0;
    Ivar *ivs = class_copyIvarList(object_getClass(obj), &n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *nm = [NSString stringWithUTF8String:ivar_getName(ivs[i])] ?: @"?";
        id v = ReadIvar(obj, ivs[i]);
        if (!v) continue;
        id s = Ser(v, depth+1, seen);
        if (s) d[nm] = s;
    }
    free(ivs);
    return d;
}

#pragma mark - 单例探测

static NSArray<NSString *> *SingletonSelectors(void) {
    return @[@"shared", @"sharedInstance", @"defaultManager", @"standard", @"instance",
             @"manager", @"current", @"default", @"sharedManager", @"singleton"];
}

static id TrySingleton(Class cls) {
    if (!cls) return nil;
    for (NSString *selName in SingletonSelectors()) {
        SEL s = NSSelectorFromString(selName);
        if (![cls respondsToSelector:s]) continue;
        @try {
            id o = ((id (*)(id, SEL))objc_msgSend)(cls, s);
            if (o) return o;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// 在对象 ivar 里递归找持有 deviceCommands/commandDict 的对象
static id FindCommandsHolder(id obj, int depth, NSMutableSet *seen) {
    if (!obj || depth > 3) return nil;
    if ([seen containsObject:[NSValue valueWithNonretainedObject:obj]]) return nil;
    [seen addObject:[NSValue valueWithNonretainedObject:obj]];

    NSArray *want = @[@"deviceCommands", @"commandDict", @"commands"];
    unsigned int n = 0;
    Ivar *ivs = class_copyIvarList(object_getClass(obj), &n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *nm = [NSString stringWithUTF8String:ivar_getName(ivs[i])] ?: @"";
        if ([want containsObject:nm]) {
            id v = ReadIvar(obj, ivs[i]);
            if (v) { free(ivs); return obj; }
        }
    }
    // 再往下钻一层
    for (unsigned int i = 0; i < n; i++) {
        const char *t = ivar_getTypeEncoding(ivs[i]);
        if (!t || t[0] != '@') continue;
        id v = ReadIvar(obj, ivs[i]);
        if (!v) continue;
        id hit = FindCommandsHolder(v, depth+1, seen);
        if (hit) { free(ivs); return hit; }
    }
    free(ivs);
    return nil;
}

#pragma mark - 主流程

static NSString *DocPath(NSString *name) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:name];
}

static void DumpFromVC(UIViewController *vc) {
    os_log(gLog, "[CMD] ---- 开始扫描 ----");
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    NSMutableSet *seen = [NSMutableSet set];

    // 1) DynamicTool 单例
    NSArray *candClasses = @[@"_TtC15NBDynamicModule11DynamicTool",
                             @"_TtC15NBDynamicModule19DynamicDebugManager",
                             @"_TtC7Vehicle22BleCommandDebugManager",
                             @"_TtC17NBBluetoothModule9DebugTool"];
    for (NSString *cn in candClasses) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) { os_log(gLog, "[CMD] 类缺失: %{public}s", cn.UTF8String); continue; }
        id inst = TrySingleton(c);
        os_log(gLog, "[CMD] %{public}s 单例=%{public}s", cn.UTF8String, inst ? "有" : "无");
        if (!inst) continue;
        id holder = FindCommandsHolder(inst, 0, seen);
        os_log(gLog, "[CMD]   持有指令字段的对象=%{public}s", holder ? CN(holder).UTF8String : "(无)");
        if (holder) {
            report[cn] = Ser(holder, 0, [NSMutableSet set]) ?: @{};
        }
    }

    // 2) 兜底：读表格可见 cell 的文案
    NSMutableArray *cells = [NSMutableArray array];
    @try {
        id tv = [vc valueForKey:@"tableView"];
        if (![tv isKindOfClass:[UITableView class]]) tv = nil;
        if (!tv) {
            for (UIView *v in vc.view.subviews) if ([v isKindOfClass:[UITableView class]]) { tv = v; break; }
        }
        if (tv) {
            os_log(gLog, "[CMD] 表格行数 = %ld", (long)[(UITableView *)tv numberOfRowsInSection:0]);
            for (UITableViewCell *cell in [(UITableView *)tv visibleCells]) {
                NSMutableArray *texts = [NSMutableArray array];
                for (UIView *sub in cell.contentView.subviews) {
                    if ([sub isKindOfClass:[UILabel class]] && ((UILabel *)sub).text.length)
                        [texts addObject:((UILabel *)sub).text];
                }
                if (texts.count) [cells addObject:[texts componentsJoinedByString:@" | "]];
            }
        }
    } @catch (__unused NSException *e) {}
    if (cells.count) {
        report[@"_visibleCells"] = cells;
        os_log(gLog, "[CMD] 可见 cell 文案 %lu 条", (unsigned long)cells.count);
        for (NSString *s in cells) os_log(gLog, "[CMD]   %{public}s", s.UTF8String);
    }

    if (!report.count) { os_log(gLog, "[CMD] ❌ 什么都没有拿到"); return; }

    NSData *json = [NSJSONSerialization dataWithJSONObject:report
                    options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSString *path = DocPath(@"BleCmdDump.json");
    if (json) {
        [json writeToFile:path atomically:YES];
        os_log(gLog, "[CMD] ✅ 已写入 %{public}s (%lu B)", path.UTF8String, (unsigned long)json.length);
    } else {
        os_log(gLog, "[CMD] ❌ JSON 序列化失败（可能含非字符串键）");
    }
}

static void MyViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) ((void (*)(id, SEL, BOOL))gOrigViewDidAppear)(self, _cmd, animated);
    os_log(gLog, "[CMD] 已进入蓝牙指令调试页，2.5 秒后扫描");
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id vc = weakSelf;
        if (vc) DumpFromVC(vc);
    });
}

__attribute__((constructor)) static void CmdDumpInit(void) {
    gLog = os_log_create("com.rev.cmddump", "general");
    os_log(gLog, "CmdDump 1.2 已加载");
    Class vcCls = objc_getClass("_TtC7Vehicle17BleCommandDebugVC");
    if (!vcCls) { os_log(gLog, "[CMD] ❌ 未找到 VC 类"); return; }
    Method m = class_getInstanceMethod(vcCls, sel_registerName("viewDidAppear:"));
    if (m) { gOrigViewDidAppear = method_setImplementation(m, (IMP)MyViewDidAppear);
             os_log(gLog, "[CMD] 已 hook viewDidAppear:"); }
}
