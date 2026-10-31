// CachePeek — 只读方式获取 tft_v / tft_pn 等真实部件值
//
// 思路：不钩任何热路径。
//   1) 启动后读一次 NSUserDefaults 全量键值，打印含 tft/mcu/wnumber/ecu 的项
//   2) 扫描 Documents / Library/Caches 里名字可疑的文件，打印其内容中的相关键
//   3) 只给 NSUserDefaults 的“写入”加一个窄钩子：键名含 tft 才输出
// 风险：几乎为零（无高频钩子、无大数据处理）。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static const char *kKeys[] = {"tft", "mcu", "ecu", "absf", "dis_", "wnumber", "flapl", "bms", "bfg"};

static BOOL Interesting(NSString *k) {
    if (![k isKindOfClass:[NSString class]] || !k.length) return NO;
    NSString *low = k.lowercaseString;
    for (size_t i = 0; i < sizeof(kKeys)/sizeof(kKeys[0]); i++)
        if ([low containsString:@(kKeys[i])]) return YES;
    return NO;
}

static NSString *Short(id v) {
    NSString *s = [v isKindOfClass:[NSString class]] ? v : [v description];
    if (![s isKindOfClass:[NSString class]]) return @"?";
    return s.length > 120 ? [[s substringToIndex:120] stringByAppendingString:@"…"] : s;
}

static void DumpDefaults(const char *why) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    os_log(gLog, "[PEEK] ---- NSUserDefaults (%{public}s) 共 %lu 键 ----",
           why, (unsigned long)d.count);
    int n = 0;
    for (NSString *k in d) {
        if (!Interesting(k)) continue;
        os_log(gLog, "[PEEK]   %{public}s = %{public}s", k.UTF8String, Short(d[k]).UTF8String);
        if (++n > 40) break;
    }
    if (n == 0) os_log(gLog, "[PEEK]   （未发现部件相关键）");
}

static void PeekFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length || data.length > 2*1024*1024) return;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s.length) return;
    NSString *low = s.lowercaseString;
    BOOL hit = NO;
    for (size_t i = 0; i < sizeof(kKeys)/sizeof(kKeys[0]); i++)
        if ([low containsString:@(kKeys[i])]) { hit = YES; break; }
    if (!hit) return;
    os_log(gLog, "[PEEK] 命中文件 %{public}s (%luB)", path.UTF8String, (unsigned long)data.length);
    // 只打含关键字的短片段，避免刷屏
    NSArray *lines = [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    int n = 0;
    for (NSString *ln in lines) {
        NSString *l = ln.lowercaseString;
        for (size_t i = 0; i < sizeof(kKeys)/sizeof(kKeys[0]); i++) {
            if ([l containsString:@(kKeys[i])]) {
                os_log(gLog, "[PEEK]     %{public}s",
                       (ln.length > 160 ? [[ln substringToIndex:160] UTF8String] : ln.UTF8String));
                n++; break;
            }
        }
        if (n > 25) break;
    }
}

static void ScanDirs(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSMutableArray *roots = [NSMutableArray array];
    if (dirs.count) [roots addObject:dirs[0]];
    NSString *lib = [dirs.count ? dirs[0] : @"" stringByDeletingLastPathComponent];
    if (lib.length) {
        [roots addObject:[lib stringByAppendingPathComponent:@"Library/Caches"]];
        [roots addObject:[lib stringByAppendingPathComponent:@"Library/Preferences"]];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in roots) {
        NSArray *items = [fm contentsOfDirectoryAtPath:root error:nil];
        os_log(gLog, "[PEEK] 目录 %{public}s：%lu 项", root.UTF8String, (unsigned long)items.count);
        int scanned = 0;
        for (NSString *it in items) {
            NSString *low = it.lowercaseString;
            BOOL nameHit = [low containsString:@"cache"] || [low containsString:@"dynamic"]
                        || [low containsString:@"device"] || [low containsString:@"config"]
                        || [low containsString:@"plist"];
            if (!nameHit) continue;
            PeekFile([root stringByAppendingPathComponent:it]);
            if (++scanned > 12) break;
        }
    }
}

%hook NSUserDefaults

- (void)setObject:(id)value forKey:(id)key {
    if (Interesting((NSString *)key))
        os_log(gLog, "[SET ] %{public}s = %{public}s",
               ((NSString *)key).UTF8String, Short(value).UTF8String);
    %orig;
}

%end

%ctor {
    gLog = os_log_create("com.rev.cachepeek", "general");
    os_log(gLog, "CachePeek 1.0 已加载（只读探查部件值缓存）");

    for (int i = 1; i <= 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ DumpDefaults("定时"); });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ScanDirs(); });
}
