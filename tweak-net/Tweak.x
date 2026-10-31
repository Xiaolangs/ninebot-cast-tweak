// NetPlainLog 1.2 — 接口明文**完整**打印
//
// 与 1.1 的区别：不再截断/跳过大包，改为「分段输出」，每段 700 字符并标注 [k/n]，
// 因此一条 10KB 的响应会输出约 15 行，内容一个字都不丢。
//
// 完整性的三重保障：
//   1) 内容不截断，只分段（os_log 单条有长度限制，所以必须分段）
//   2) 大包上限放宽到 512KB
//   3) 可选落文件（POFileDump=YES）→ 明文写进 Documents/NetLog/，不受日志系统丢包影响
//
// 防卡死：令牌桶限流（默认 20 行/秒），超出部分明确标注「已丢弃 N 段」，不静默。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <substrate.h>

static os_log_t gLog = NULL;

#define NL_CHUNK       700      // 每段字符数（os_log 单条安全长度）
#define NL_MAX_BYTES   (512*1024)
#define NL_MAX_LINES   40000    // 分段后的总行数上限
#define NL_RATE_PER_SEC 300.0   // 命中主题关键字后基本不限流
#define NL_BURST       600.0    // 突发额度

static int          gLines = 0;
static double       gTokens = NL_BURST;
static CFAbsoluteTime gLastRefill = 0;
static volatile int gInHook = 0;

static BOOL RateOK(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gLastRefill == 0) gLastRefill = now;
    gTokens += (now - gLastRefill) * NL_RATE_PER_SEC;
    if (gTokens > NL_BURST) gTokens = NL_BURST;
    gLastRefill = now;
    if (gTokens < 1.0) return NO;
    gTokens -= 1.0;
    return YES;
}

static void DumpToFile(const char *tag, NSString *text) {
    id flag = [[NSUserDefaults standardUserDefaults] objectForKey:@"POFileDump"];
    if (!flag || ![flag boolValue]) return;
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!docs.count) return;
    NSString *dir = [docs[0] stringByAppendingPathComponent:@"NetLog"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    static int idx = 0;
    NSString *name = [NSString stringWithFormat:@"%04d_%s.txt", ++idx, tag];
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSString *body = [NSString stringWithFormat:@"===== %s =====\n%@\n", tag, text];
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 完整输出：分段，不截断
static void EmitFull(const char *tag, NSString *text) {
    if (!text || text.length == 0) return;
    if (gInHook) return;
    gInHook = 1;

    DumpToFile(tag, text);

    NSUInteger total = (text.length + NL_CHUNK - 1) / NL_CHUNK;
    if (total == 0) total = 1;
    NSUInteger dropped = 0;
    for (NSUInteger i = 0; i < total; i++) {
        if (gLines >= NL_MAX_LINES) { dropped = total - i; break; }
        if (!RateOK())               { dropped = total - i; break; }
        NSUInteger loc = i * NL_CHUNK;
        NSUInteger len = MIN((NSUInteger)NL_CHUNK, text.length - loc);
        NSString *part = [text substringWithRange:NSMakeRange(loc, len)];
        gLines++;
        os_log(gLog, "%{public}s[%lu/%lu] %{public}s", tag,
               (unsigned long)(i + 1), (unsigned long)total, part.UTF8String);
    }
    if (dropped > 0) {
        os_log(gLog, "%{public}s ⚠️ 限流丢弃 %lu/%lu 段（可调高 NL_RATE_PER_SEC 或开 POFileDump）",
               tag, (unsigned long)dropped, (unsigned long)total);
    }
    gInHook = 0;
}


// ===== 关键字过滤：只有命中主题相关才输出 =====
// 直接在原始字节上匹配 ASCII 关键字，不预先解码，开销极小
static const char *kKeywords[] = {
    "app-api/theme", "resourceCode", "resourceList", "dashSkin", "DashSkin",
    "themeSkin", "ThemeSkin", "get-new-version", "batch-show-config",
    "skinId", "skinName", "resourceName"
};

static BOOL BytesContain(const void *hay, size_t hlen, const char *needle) {
    size_t nlen = strlen(needle);
    if (hlen < nlen) return NO;
    return memmem(hay, hlen, needle, nlen) != NULL;
}

static BOOL DataHasKeyword(NSData *d) {
    if (![d isKindOfClass:[NSData class]]) return NO;
    if (d.length < 8 || d.length > NL_MAX_BYTES) return NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"PONetLogAll"]) return YES;
    for (size_t i = 0; i < sizeof(kKeywords)/sizeof(kKeywords[0]); i++) {
        if (BytesContain(d.bytes, d.length, kKeywords[i])) return YES;
    }
    return NO;
}

static BOOL StringHasKeyword(NSString *s) {
    if (!s.length) return NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"PONetLogAll"]) return YES;
    if ([s containsString:@"app-api/theme"]) return YES;
    if ([s containsString:@"theme"]) return YES;
    return NO;
}

// 只在内容像 JSON 时才处理：API 载荷是 JSON，BLE 指令是二进制 → 天然避开热点
static BOOL LooksJSON(NSData *d) {
    if (![d isKindOfClass:[NSData class]]) return NO;
    if (d.length < 8 || d.length > NL_MAX_BYTES) return NO;
    const unsigned char *b = (const unsigned char *)d.bytes;
    NSUInteger i = 0;
    while (i < d.length && (b[i] == ' ' || b[i] == '\n' || b[i] == '\r' || b[i] == '\t')) i++;
    if (i >= d.length) return NO;
    return (b[i] == '{' || b[i] == '[');
}

static NSString *Plain(id data) {
    if (![data isKindOfClass:[NSData class]]) return nil;
    NSData *d = (NSData *)data;
    if (d.length == 0 || d.length > NL_MAX_BYTES) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s.length ? s : nil;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(id)data options:(unsigned long)opt error:(id *)err {
    id r = %orig;
    if (LooksJSON(data) && DataHasKeyword((NSData *)data)) EmitFull("[RESP]", Plain(data));
    return r;
}

+ (id)dataWithJSONObject:(id)obj options:(unsigned long)opt error:(id *)err {
    id r = %orig;
    if (LooksJSON(r) && DataHasKeyword((NSData *)r)) EmitFull("[REQ]", Plain(r));
    return r;
}

%end

%hook NSMutableURLRequest

- (void)setHTTPBody:(id)body {
    if (LooksJSON(body) && DataHasKeyword((NSData *)body)) EmitFull("[REQ]", Plain(body));
    %orig;
}

%end

%hook JCOREDataSecurity

+ (id)encrypt:(id)plain aesKey:(id)key {
    if (LooksJSON(plain) && DataHasKeyword((NSData *)plain)) EmitFull("[REQ*]", Plain(plain));
    return %orig;
}
- (id)encrypt:(id)plain aesKey:(id)key {
    if (LooksJSON(plain) && DataHasKeyword((NSData *)plain)) EmitFull("[REQ*]", Plain(plain));
    return %orig;
}
+ (id)AES256EncryptData:(id)plain withKey:(id)key {
    if (LooksJSON(plain) && DataHasKeyword((NSData *)plain)) EmitFull("[REQ*]", Plain(plain));
    return %orig;
}
- (id)AES256EncryptData:(id)plain withKey:(id)key {
    if (LooksJSON(plain) && DataHasKeyword((NSData *)plain)) EmitFull("[REQ*]", Plain(plain));
    return %orig;
}

%end

%hook NSURLSession

- (id)dataTaskWithRequest:(id)req {
    id url = ((id (*)(id, SEL))objc_msgSend)(req, NSSelectorFromString(@"URL"));
    id s = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
    if ([s isKindOfClass:[NSString class]] && StringHasKeyword(s)) EmitFull("[URL]", s);
    return %orig;
}

- (id)downloadTaskWithRequest:(id)req {
    id url = ((id (*)(id, SEL))objc_msgSend)(req, NSSelectorFromString(@"URL"));
    id s = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
    if ([s isKindOfClass:[NSString class]] && ([s containsString:@".zip"] || StringHasKeyword(s))) EmitFull("[DL]", s);
    return %orig;
}

%end

%ctor {
    gLog = os_log_create("com.rev.netplainlog", "general");
    os_log(gLog, "NetPlainLog 1.3 已加载（仅 app-api/theme 相关，完整明文，分段=%d字符，上限=%d行）", NL_CHUNK, NL_MAX_LINES);
}
