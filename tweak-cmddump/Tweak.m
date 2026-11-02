// CmdDump 1.1 — 打开「蓝牙指令调试」页时，递归反射导出全部指令集
//
// 1.0 的问题：过滤器把 BleCommandDebugVC 自己也当成指令对象了（类名含 BleCommand），
// 导致只导出 1 条空记录。1.1 修正：
//   * 明确排除 VC / Cell / Manager 等界面类
//   * 递归遍历 ivar 树（深度 4），数组逐元素下钻
//   * 额外打印 VC 的 ivar 结构，便于定位数据到底存在哪
//   * 延迟 2.5 秒（等表格数据加载完）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t gLog = NULL;
static IMP gOrigViewDidAppear = NULL;

#pragma mark - 反射工具

static NSString *ClsName(id o) {
    if (!o) return @"";
    return NSStringFromClass(object_getClass(o));
}

// 是否是「指令配置对象」——必须是数据模型，排除界面类
static BOOL IsCmdModel(Class c) {
    if (!c) return NO;
    NSString *n = NSStringFromClass(c);
    if ([n containsString:@"ViewController"] || [n containsString:@"VC"] ||
        [n containsString:@"Cell"] || [n containsString:@"Manager"] ||
        [n containsString:@"Window"] || [n containsString:@"View"]) return NO;
    return [n containsString:@"Command"] || [n containsString:@"Cmd"];
}

static id ReadIvar(id obj, Ivar iv) {
    const char *t = ivar_getTypeEncoding(iv);
    if (!t) return nil;
    if (t[0] == '@') {
        @try { return object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; }
    }
    ptrdiff_t off = ivar_getOffset(iv);
    char *base = (char *)(__bridge void *)obj;
    switch (t[0]) {
        case 'c': return @(*(char *)(base + off));
        case 'B': return @(*(BOOL *)(base + off));
        case 's': return @(*(short *)(base + off));
        case 'i': return @(*(int *)(base + off));
        case 'l': return @(*(long *)(base + off));
        case 'q': return @(*(long long *)(base + off));
        case 'f': return @(*(float *)(base + off));
        case 'd': return @(*(double *)(base + off));
        default:  return nil;
    }
}

// 打印对象结构（ivar 名 + 类型 + 值摘要），用于定位数据位置
static void Describe(id obj, const char *tag, int depth) {
    if (!obj || depth > 2) return;
    Class cls = object_getClass(obj);
    os_log(gLog, "[CMD] %{public}s <%@> 结构:", tag, NSStringFromClass(cls));
    unsigned int n = 0;
    Ivar *ivs = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n && i < 40; i++) {
        NSString *nm = [NSString stringWithUTF8String:ivar_getName(ivs[i])] ?: @"?";
        const char *te = ivar_getTypeEncoding(ivs[i]);
        id v = ReadIvar(obj, ivs[i]);
        NSString *desc = @"";
        if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) desc = [v description];
        else if ([v isKindOfClass:[NSArray class]]) desc = [NSString stringWithFormat:@"array(%lu)", (unsigned long)[(NSArray *)v count]];
        else if (v) desc = [NSString stringWithFormat:@"<%@>", ClsName(v)];
        os_log(gLog, "[CMD]    %{public}s : %{public}s = %{public}s",
               nm.UTF8String, te ? te : "?", desc.length > 80 ? [[desc substringToIndex:80] UTF8String] : desc.UTF8String);
    }
    free(ivs);
}

static void Collect(id obj, NSMutableArray *out, NSMutableSet *seen, int depth) {
    if (!obj || depth > 4 || out.count > 5000) return;
    if ([seen containsObject:[NSValue valueWithNonretainedObject:obj]]) return;
    [seen addObject:[NSValue valueWithNonretainedObject:obj]];

    if ([obj isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)obj) Collect(e, out, seen, depth + 1);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, __unused BOOL *st) {
            Collect(v, out, seen, depth + 1);
        }];
        return;
    }

    Class cls = object_getClass(obj);
    if (IsCmdModel(cls)) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"_class"] = NSStringFromClass(cls);
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *nm = [NSString stringWithUTF8String:ivar_getName(ivs[i])] ?: @"?";
            id v = ReadIvar(obj, ivs[i]);
            if (!v) continue;
            if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]])
                d[nm] = v;
            else if ([v isKindOfClass:[NSArray class]])
                d[nm] = [NSString stringWithFormat:@"array(%lu)", (unsigned long)[(NSArray *)v count]];
            else
                d[nm] = [NSString stringWithFormat:@"<%@>", ClsName(v)];
        }
        free(ivs);
        [out addObject:d];
        return;   // 已是数据模型，不再向下钻
    }

    // 普通容器：继续看它的对象型 ivar
    if (depth < 3) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(ivs[i]);
            if (t && t[0] == '@') Collect(ReadIvar(obj, ivs[i]), out, seen, depth + 1);
        }
        free(ivs);
    }
}

static NSString *DocPath(NSString *name) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:name];
}

static void DumpFromVC(UIViewController *vc) {
    os_log(gLog, "[CMD] ---- 开始扫描 ----");
    @try {
        id tv = [vc valueForKey:@"tableView"];
        if ([tv isKindOfClass:[UITableView class]])
            os_log(gLog, "[CMD] 表格行数 = %ld", (long)[(UITableView *)tv numberOfRowsInSection:0]);
    } @catch (__unused NSException *e) {}
    Describe(vc, "VC", 0);

    NSMutableArray *out = [NSMutableArray array];
    Collect(vc, out, [NSMutableSet set], 0);

    if (!out.count) {
        os_log(gLog, "[CMD] ❌ 未找到指令模型。请把上面的结构日志发我，我按真实字段改");
        return;
    }
    NSDictionary *wrap = @{@"count": @(out.count), @"items": out};
    NSData *json = [NSJSONSerialization dataWithJSONObject:wrap
                     options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSString *path = DocPath(@"BleCmdSet.json");
    [json writeToFile:path atomically:YES];
    os_log(gLog, "[CMD] ✅ 已导出 %lu 条 → %{public}s", (unsigned long)out.count, path.UTF8String);

    for (NSDictionary *d in out) {
        NSMutableString *line = [NSMutableString string];
        for (NSString *k in [d.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if ([k isEqualToString:@"_class"]) continue;
            [line appendFormat:@"%@=%@  ", k, [d[k] description]];
        }
        os_log(gLog, "[CMD] %{public}s", line.UTF8String);
    }
}

#pragma mark - hook

static void MyViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) ((void (*)(id, SEL, BOOL))gOrigViewDidAppear)(self, _cmd, animated);
    os_log(gLog, "[CMD] 蓝牙指令调试页已出现，2.5 秒后扫描");
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id vc = weakSelf;
        if (vc) DumpFromVC(vc);
    });
}

__attribute__((constructor)) static void CmdDumpInit(void) {
    gLog = os_log_create("com.rev.cmddump", "general");
    os_log(gLog, "CmdDump 1.1 已加载");
    Class vcCls = objc_getClass("_TtC7Vehicle17BleCommandDebugVC");
    if (!vcCls) { os_log(gLog, "[CMD] ❌ 未找到 BleCommandDebugVC"); return; }
    Method m = class_getInstanceMethod(vcCls, sel_registerName("viewDidAppear:"));
    if (m) {
        gOrigViewDidAppear = method_setImplementation(m, (IMP)MyViewDidAppear);
        os_log(gLog, "[CMD] 已 hook viewDidAppear:");
    } else {
        os_log(gLog, "[CMD] ❌ 无 viewDidAppear:");
    }
}
