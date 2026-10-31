// ThemeProbe — 主题/皮肤专用探针（三合一）
//
// 1) [URL]/[RESP]  只打 app-api/theme 相关接口（关键字过滤，命中才输出）
// 2) [BIG]         只抓 >32KB 的解密调用 → 皮肤包解密时的 key 与明文魔数
// 3) [KEY]         seed → key 的派生（判断密钥是否退化）
//
// 安全设计：小包解密不碰（避开 BLE 热点）、非主题 JSON 不碰、带限流与总行上限。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static int gLines = 0;
static double gTokens = 400.0;
static CFAbsoluteTime gRefill = 0;

#define TP_CHUNK      700
#define TP_MAX_BYTES  (512*1024)
#define TP_MAX_LINES  20000
#define TP_RATE       200.0
#define TP_BURST      400.0
#define TP_BIG        32768     // 只抓超过 32KB 的解密

static BOOL RateOK(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gRefill == 0) gRefill = now;
    gTokens += (now - gRefill) * TP_RATE;
    if (gTokens > TP_BURST) gTokens = TP_BURST;
    gRefill = now;
    if (gTokens < 1.0) return NO;
    gTokens -= 1.0;
    return YES;
}

static NSString *Describe(id o, NSUInteger maxLen) {
    if (!o) return @"(nil)";
    if ([o isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)o;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s.length) return s.length > maxLen ? [s substringToIndex:maxLen] : s;
        return [NSString stringWithFormat:@"(%luB)", (unsigned long)d.length];
    }
    NSString *s = [o isKindOfClass:[NSString class]] ? (NSString *)o : [o description];
    if (![s isKindOfClass:[NSString class]]) return @"?";
    return s.length > maxLen ? [s substringToIndex:maxLen] : s;
}

static NSString *Magic(id o) {
    if (![o isKindOfClass:[NSData class]]) return @"(非Data)";
    NSData *d = (NSData *)o;
    if (d.length < 4) return @"(太短)";
    const unsigned char *b = (const unsigned char *)d.bytes;
    char hex[24] = {0}, asc[10] = {0};
    for (int i = 0; i < 8 && i < (int)d.length; i++) {
        snprintf(hex + i*2, 3, "%02x", b[i]);
        asc[i] = (b[i] >= 32 && b[i] < 127) ? (char)b[i] : '.';
    }
    return [NSString stringWithFormat:@"len=%lu magic=%s '%s'",
            (unsigned long)d.length, hex, asc];
}

// 分段完整输出
static void EmitFull(const char *tag, NSString *text) {
    if (!text.length) return;
    NSUInteger total = (text.length + TP_CHUNK - 1) / TP_CHUNK;
    NSUInteger dropped = 0;
    for (NSUInteger i = 0; i < total; i++) {
        if (gLines >= TP_MAX_LINES || !RateOK()) { dropped = total - i; break; }
        NSUInteger loc = i * TP_CHUNK;
        NSUInteger len = MIN((NSUInteger)TP_CHUNK, text.length - loc);
        gLines++;
        os_log(gLog, "%{public}s[%lu/%lu] %{public}s", tag,
               (unsigned long)(i+1), (unsigned long)total,
               [text substringWithRange:NSMakeRange(loc, len)].UTF8String);
    }
    if (dropped) os_log(gLog, "%{public}s ⚠️ 限流丢弃 %lu 段", tag, (unsigned long)dropped);
}

static void Emit(const char *tag, const char *fmt, ...) {
    if (gLines >= TP_MAX_LINES || !RateOK()) return;
    char buf[2048];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    gLines++;
    os_log(gLog, "%{public}s %{public}s", tag, buf);
}

// ===== 主题关键字过滤 =====
static const char *kKW[] = {
    "app-api/theme", "resourceCode", "resourceList", "dashSkin", "DashSkin",
    "themeSkin", "ThemeSkin", "get-new-version", "batch-show-config",
    "skinId", "skinName", "resourceName", "system_skin_show"
};
static BOOL DataHasKW(NSData *d) {
    if (![d isKindOfClass:[NSData class]]) return NO;
    if (d.length < 8 || d.length > TP_MAX_BYTES) return NO;
    for (size_t i = 0; i < sizeof(kKW)/sizeof(kKW[0]); i++) {
        if (memmem(d.bytes, d.length, kKW[i], strlen(kKW[i]))) return YES;
    }
    return NO;
}
static BOOL LooksJSON(NSData *d) {
    if (![d isKindOfClass:[NSData class]] || d.length < 8 || d.length > TP_MAX_BYTES) return NO;
    const unsigned char *b = (const unsigned char *)d.bytes;
    NSUInteger i = 0;
    while (i < d.length && (b[i]==' '||b[i]=='\n'||b[i]=='\r'||b[i]=='\t')) i++;
    return i < d.length && (b[i] == '{' || b[i] == '[');
}
static NSString *Plain(id d) {
    if (![d isKindOfClass:[NSData class]]) return nil;
    NSData *x = (NSData *)d;
    if (!x.length || x.length > TP_MAX_BYTES) return nil;
    return [[NSString alloc] initWithData:x encoding:NSUTF8StringEncoding];
}

static void SavePlain(const char *tag, id plain) {
    id flag = [[NSUserDefaults standardUserDefaults] objectForKey:@"POSavePlain"];
    if (!flag || ![flag boolValue]) return;
    if (![plain isKindOfClass:[NSData class]]) return;
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!docs.count) return;
    NSString *dir = [docs[0] stringByAppendingPathComponent:@"POSkin"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    static int n = 0;
    NSString *name = [NSString stringWithFormat:@"%03d_%s.bin", ++n, tag];
    NSString *path = [dir stringByAppendingPathComponent:name];
    [(NSData *)plain writeToFile:path atomically:YES];
    Emit("[BIG] 已保存明文", "%s", path.UTF8String);
}

static void LogBig(const char *tag, id inData, id key, id outData) {
    if (![inData isKindOfClass:[NSData class]]) return;
    if (((NSData *)inData).length < TP_BIG) return;   // 小包不碰
    Emit("[BIG] 解密", "%s key=%s", tag, Describe(key, 80).UTF8String);
    Emit("[BIG]      in ", "%s", Magic(inData).UTF8String);
    Emit("[BIG]      out", "%s", Magic(outData).UTF8String);
    SavePlain(tag, outData);
}

// ===== 接口层 =====

// ===== 解压转储：绕过加密，直接把明文 zip 捞出来 =====
// 皮肤包流程：加密bin → 内存解密 → 写 tmp/xxx（此时已是合法 zip）→ SSZipArchive 解压
// 我们在解压前把源文件复制到 Documents/POSkinDump/，于是无需任何密钥即可拿到明文包。
// 前置声明（定义在后面，避免顺序问题）
static volatile int gInDump = 0;
static BOOL PathInteresting(NSString *p);
static BOOL RawWrite(NSData *d, NSString *path);

static void DumpArchive(NSString *path, const char *how) {
    if (gInDump) return;
    if (!path || ![path isKindOfClass:[NSString class]]) return;
    if (!PathInteresting(path)) return;
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d.length) { Emit("[ZIP] 读取失败", "%s path=%s", how, path.UTF8String); return; }
    const unsigned char *b = (const unsigned char *)d.bytes;
    BOOL isZip = (d.length >= 4 && b[0]=='P' && b[1]=='K' && (b[2]==3||b[2]==5) && (b[3]==4||b[3]==6));
    if (!isZip) {
        char hex[24] = {0}, asc[10] = {0};
        for (int i = 0; i < 8 && i < (int)d.length; i++) {
            snprintf(hex + i*2, 3, "%02x", b[i]);
            asc[i] = (b[i] >= 32 && b[i] < 127) ? (char)b[i] : '.';
        }
        Emit("[ZIP] 非zip源", "%s size=%lu magic=%s '%s' path=%s", how,
             (unsigned long)d.length, hex, asc, path.UTF8String);
    }
    Emit("[ZIP] 解压源", "%s size=%lu isZip=%s path=%s", how,
         (unsigned long)d.length, isZip ? "YES" : "NO", path.UTF8String);

    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!docs.count) return;
    NSString *dir = [docs[0] stringByAppendingPathComponent:@"POSkinDump"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    static int n = 0;
    NSString *base = [path lastPathComponent];
    NSString *name = [NSString stringWithFormat:@"%03d_%@.zip", ++n, base];
    NSString *dst = [dir stringByAppendingPathComponent:name];
    gInDump = 1;
    BOOL ok = RawWrite(d, dst);
    gInDump = 0;
    Emit("[ZIP] 已转储", "%s (%s)", dst.UTF8String, ok ? "ok" : "fail");
}

%hook NSJSONSerialization
+ (id)JSONObjectWithData:(id)data options:(unsigned long)opt error:(id *)err {
    id r = %orig;
    if (LooksJSON(data) && DataHasKW((NSData *)data)) EmitFull("[RESP]", Plain(data));
    return r;
}
+ (id)dataWithJSONObject:(id)obj options:(unsigned long)opt error:(id *)err {
    id r = %orig;
    if (LooksJSON(r) && DataHasKW((NSData *)r)) EmitFull("[REQ]", Plain(r));
    return r;
}
%end

%hook NSMutableURLRequest
- (void)setHTTPBody:(id)body {
    if (LooksJSON(body) && DataHasKW((NSData *)body)) EmitFull("[REQ]", Plain(body));
    %orig;
}
%end

%hook NSURLSession
- (id)dataTaskWithRequest:(id)req {
    id url = ((id (*)(id, SEL))objc_msgSend)(req, NSSelectorFromString(@"URL"));
    id s = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
    if ([s isKindOfClass:[NSString class]] &&
        ([s containsString:@"app-api/theme"] || [s containsString:@"theme"]))
        EmitFull("[URL]", s);
    return %orig;
}
- (id)downloadTaskWithRequest:(id)req {
    id url = ((id (*)(id, SEL))objc_msgSend)(req, NSSelectorFromString(@"URL"));
    id s = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
    if ([s isKindOfClass:[NSString class]] &&
        ([s containsString:@"theme"] || [s containsString:@".zip"]))
        EmitFull("[DL]", s);
    return %orig;
}
%end

// ===== 加密层（合并到一个 hook 块里）=====
%hook JCOREDataSecurity

+ (id)generateSeedKey:(unsigned long long)seed {
    id r = %orig;
    Emit("[KEY] generateSeedKey", "seed=%llu -> key=%s", seed, Describe(r, 64).UTF8String);
    return r;
}
+ (id)encryptKeyWithSeed:(unsigned long long)seed {
    id r = %orig;
    Emit("[KEY] keyWithSeed", "seed=%llu key=%s", seed, Describe(r, 64).UTF8String);
    return r;
}
- (id)encryptKeyWithSeed:(unsigned long long)seed {
    id r = %orig;
    Emit("[KEY] keyWithSeed(-)", "seed=%llu key=%s", seed, Describe(r, 64).UTF8String);
    return r;
}
+ (id)encryptKeyForHttp:(void *)out {
    id r = %orig;
    Emit("[KEY] keyForHttp", "key=%s", Describe(r, 64).UTF8String);
    return r;
}
- (id)encryptKeyForHttp:(void *)out {
    id r = %orig;
    Emit("[KEY] keyForHttp(-)", "key=%s", Describe(r, 64).UTF8String);
    return r;
}
+ (id)encrypt:(id)plain aesKey:(id)key {
    Emit("[KEY] encrypt", "key=%s plainLen=%lu", Describe(key, 64).UTF8String,
         (unsigned long)([plain isKindOfClass:[NSData class]] ? ((NSData *)plain).length : 0));
    return %orig;
}
- (id)encrypt:(id)plain aesKey:(id)key {
    Emit("[KEY] encrypt(-)", "key=%s plainLen=%lu", Describe(key, 64).UTF8String,
         (unsigned long)([plain isKindOfClass:[NSData class]] ? ((NSData *)plain).length : 0));
    return %orig;
}
+ (id)aes256DecryptData:(id)d withKey:(id)k { id r = %orig; LogBig("+aes256", d, k, r); return r; }
- (id)aes256DecryptData:(id)d withKey:(id)k { id r = %orig; LogBig("-aes256", d, k, r); return r; }
+ (id)decrypt:(id)d aesKey:(id)k { id r = %orig; LogBig("+decrypt", d, k, r); return r; }
- (id)decrypt:(id)d aesKey:(id)k { id r = %orig; LogBig("-decrypt", d, k, r); return r; }
+ (id)sm4ECBDecryptData:(id)d withKey:(id)k { id r = %orig; LogBig("+sm4ecb", d, k, r); return r; }
- (id)sm4ECBDecryptData:(id)d withKey:(id)k { id r = %orig; LogBig("-sm4ecb", d, k, r); return r; }

%end




// 只关心皮肤/主题相关路径，其它一律放过（启动时 RN 包/图片缓存太多，全拦会拖垮 App）
static BOOL PathInteresting(NSString *p) {
    if (!p.length) return NO;
    NSString *low = p.lowercaseString;
    static NSString *bad[] = {@"sdimagecache", @"/library/caches/com.", @"rct", @"jsbundle",
                              @"node_modules", @".png", @".jpg", @".jpeg", @".webp",
                              @".gif", @".mp3", @".ttf", @".otf"};
    for (size_t i = 0; i < sizeof(bad)/sizeof(bad[0]); i++)
        if ([low containsString:bad[i]]) return NO;
    static NSString *good[] = {@"themeskin", @"dashskin", @"skin", @"theme", @"artist"};
    for (size_t i = 0; i < sizeof(good)/sizeof(good[0]); i++)
        if ([low containsString:good[i]]) return YES;
    return NO;
}

// 低层写文件，绕开所有 ObjC 钩子（关键：避免 writeToFile 钩子自我递归）
static BOOL RawWrite(NSData *d, NSString *path) {
    const char *c = path.fileSystemRepresentation;
    if (!c) return NO;
    FILE *f = fopen(c, "wb");
    if (!f) return NO;
    size_t n = fwrite(d.bytes, 1, d.length, f);
    fclose(f);
    return n == d.length;
}

// 直接转储内存数据（注意：writeToFile 钩子里文件还没落盘，不能回读 path —— 那是之前的 bug）
static void DumpData(id data, NSString *hint, const char *how) {
    if (gInDump) return;                       // 递归保护
    if (![data isKindOfClass:[NSData class]]) return;
    NSData *d = (NSData *)data;
    if (d.length < 204800) return;             // 阈值提高到 200KB，避开小包
    if (!PathInteresting(hint)) return;        // 只处理皮肤/主题路径
    const unsigned char *b = (const unsigned char *)d.bytes;
    BOOL isZip = (d.length >= 4 && b[0]=='P' && b[1]=='K' && (b[2]==3||b[2]==5) && (b[3]==4||b[3]==6));
    char hex[24] = {0}, asc[10] = {0};
    for (int i = 0; i < 8 && i < (int)d.length; i++) {
        snprintf(hex + i*2, 3, "%02x", b[i]);
        asc[i] = (b[i] >= 32 && b[i] < 127) ? (char)b[i] : '.';
    }
    Emit("[DATA] 大文件写入", "%s size=%lu zip=%s magic=%s '%s' -> %s", how,
         (unsigned long)d.length, isZip ? "YES" : "NO", hex, asc,
         hint.length > 90 ? [[hint substringToIndex:90] UTF8String] : hint.UTF8String);
    if (!isZip) return;
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!docs.count) return;
    NSString *dir = [docs[0] stringByAppendingPathComponent:@"POSkinDump"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    static int n = 0;
    NSString *base = [hint lastPathComponent];
    if (!base.length) base = @"data";
    gInDump = 1;
    NSString *dst = [dir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%03d_%@.zip", ++n, base]];
    BOOL ok = RawWrite(d, dst);
    gInDump = 0;
    Emit("[DATA] 已转储", "%s (%s)", dst.UTF8String, ok ? "ok" : "fail");
}

// ===== SSZipArchive 解压入口：8 个变体全挂 =====
%hook SSZipArchive

+ (BOOL)unzipFileAtPath:(id)p toDestination:(id)d { DumpArchive(p, "+v1"); return %orig; }
- (BOOL)unzipFileAtPath:(id)p toDestination:(id)d { DumpArchive(p, "-v1"); return %orig; }

+ (BOOL)unzipFileAtPath:(id)p toDestination:(id)d overwrite:(BOOL)o password:(id)pw error:(id *)e {
    DumpArchive(p, "+v2"); return %orig; }
- (BOOL)unzipFileAtPath:(id)p toDestination:(id)d overwrite:(BOOL)o password:(id)pw error:(id *)e {
    DumpArchive(p, "-v2"); return %orig; }

+ (BOOL)unzipFileAtPath:(id)p toDestination:(id)d delegate:(id)dl { DumpArchive(p, "+v3"); return %orig; }
- (BOOL)unzipFileAtPath:(id)p toDestination:(id)d delegate:(id)dl { DumpArchive(p, "-v3"); return %orig; }

+ (BOOL)unzipFileAtPath:(id)p toDestination:(id)d overwrite:(BOOL)o password:(id)pw error:(id *)e delegate:(id)dl {
    DumpArchive(p, "+v4"); return %orig; }

+ (BOOL)unzipFileAtPath:(id)p toDestination:(id)d overwrite:(BOOL)o password:(id)pw progressHandler:(id)ph completionHandler:(id)ch {
    DumpArchive(p, "+v5"); return %orig; }

+ (BOOL)unzipFileAtPath:(id)p toDestination:(id)d progressHandler:(id)ph completionHandler:(id)ch {
    DumpArchive(p, "+v6"); return %orig; }

+ (BOOL)unzipFileAtPath:(id)p toDestination:(id)d preserveAttributes:(BOOL)pa overwrite:(BOOL)o password:(id)pw error:(id *)e {
    DumpArchive(p, "+v7"); return %orig; }

+ (BOOL)unzipFileAtPath:(id)p toDestination:(id)d preserveAttributes:(BOOL)pa overwrite:(BOOL)o password:(id)pw error:(id *)e delegate:(id)dl nestedZipLevel:(long)nz {
    DumpArchive(p, "+v8"); return %orig; }

%end

// 兜底：任何 >50KB 的写盘都记录（PK 开头则转储）
%hook NSData

- (BOOL)writeToFile:(id)path atomically:(BOOL)atom {
    DumpData(self, (NSString *)path, "write:atom");
    return %orig;
}
- (BOOL)writeToFile:(id)path options:(unsigned long)opt error:(id *)err {
    DumpData(self, (NSString *)path, "write:opt");
    return %orig;
}

%end


%hook NSFileManager

- (BOOL)createFileAtPath:(id)path contents:(id)contents attributes:(id)attrs {
    DumpData(contents, (NSString *)path, "createFile");
    return %orig;
}

- (BOOL)copyItemAtPath:(id)src toPath:(id)dst error:(id *)err {
    BOOL r = %orig;
    if (PathInteresting((NSString *)dst)) DumpArchive((NSString *)dst, "copyItem");
    return r;
}

%end


// ===== 弹窗/提示 调用栈追踪 =====
// 目的：点击仪表皮肤出现"未连接"提示时，把调用栈打出来，
// 直接定位是哪个类/方法做的连接判断（避免盲目 hook）。
static int gStackN = 0;

static void DumpStack(const char *why, NSString *detail) {
    if (gStackN >= 6) return;      // 最多 6 次，避免刷屏
    gStackN++;
    NSArray *frames = [NSThread callStackSymbols];
    NSMutableString *st = [NSMutableString string];
    NSUInteger n = MIN((NSUInteger)16, frames.count);
    for (NSUInteger i = 1; i < n; i++) [st appendFormat:@" <- %@", frames[i]];
    Emit("[STACK] 提示出现", "%s | %s%s", why,
         detail.length > 120 ? [[detail substringToIndex:120] UTF8String] : detail.UTF8String,
         st.UTF8String);
}

%hook UIAlertController

+ (id)alertControllerWithTitle:(id)title message:(id)msg preferredStyle:(long)style {
    NSString *d = [NSString stringWithFormat:@"title=%@ msg=%@",
                   [title isKindOfClass:[NSString class]] ? title : @"(nil)",
                   [msg isKindOfClass:[NSString class]] ? msg : @"(nil)"];
    DumpStack("UIAlertController", d);
    return %orig;
}

%end

// Toast 通常是发通知或调 UIView 扩展
%hook NSNotificationCenter

- (void)postNotificationName:(id)name object:(id)obj userInfo:(id)info {
    if ([name isKindOfClass:[NSString class]]) {
        NSString *low = ((NSString *)name).lowercaseString;
        if ([low containsString:@"toast"] || [low containsString:@"hud"] ||
            [low containsString:@"alert"])
            DumpStack(((NSString *)name).UTF8String,
                      [NSString stringWithFormat:@"userInfo=%@", info]);
    }
    %orig;
}

%end

%hook UIView

- (void)showToast:(id)msg {
    DumpStack("UIView.showToast", [NSString stringWithFormat:@"msg=%@", msg]);
    %orig;
}
- (void)showToast:(id)msg duration:(double)d {
    DumpStack("UIView.showToast:duration:", [NSString stringWithFormat:@"msg=%@", msg]);
    %orig;
}

%end

%ctor {
    gLog = os_log_create("com.rev.themeprobe", "general");
    os_log(gLog, "ThemeProbe 1.5 已加载（含弹窗调用栈追踪）");
    os_log(gLog, "[BEAT] 心跳：%{public}s", "启动完成，等待皮肤资源流程");
}
