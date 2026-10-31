// BodyProbe 1.1 — 抓请求明文（双路）
//
// 路线A: +[JCOREUtilities gzip:]      → 直接拿到 gzip 前的明文 JSON
// 路线B: +/-[JCOREDataSecurity aesEncryptData:withKey:iv:]（128 位，App 实际用的）
//        → 输入是 gzip 数据，钩子里就地解压得到明文
//
// 安全设计：只处理 >=200 字节且形如 JSON/gzip 的数据；BLE 小包天然被排除；
// 总行数封顶、重入保护、无数组/字典操作。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <zlib.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static volatile int gIn = 0;
static int gLines = 0;

#define BP_CHUNK 700
#define BP_MAX_LINES 600

static void DumpText(const char *tag, NSString *text) {
    if (!text.length || gLines > BP_MAX_LINES) return;
    NSUInteger total = (text.length + BP_CHUNK - 1) / BP_CHUNK;
    for (NSUInteger i = 0; i < total && gLines <= BP_MAX_LINES; i++) {
        NSUInteger loc = i * BP_CHUNK;
        NSUInteger len = MIN((NSUInteger)BP_CHUNK, text.length - loc);
        gLines++;
        os_log(gLog, "%{public}s[%lu/%lu] %{public}s", tag,
               (unsigned long)(i + 1), (unsigned long)total,
               [text substringWithRange:NSMakeRange(loc, len)].UTF8String);
    }
}

static NSData *Gunzip(NSData *in) {
    if (in.length < 18) return nil;
    z_stream s = {0};
    if (inflateInit2(&s, 15 + 32) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:in.length * 6 + 4096];
    s.next_in = (Bytef *)in.bytes;
    s.avail_in = (uInt)in.length;
    s.next_out = (Bytef *)out.mutableBytes;
    s.avail_out = (uInt)out.length;
    int rc = inflate(&s, Z_FINISH);
    NSData *r = nil;
    if (rc == Z_STREAM_END) r = [NSData dataWithBytes:out.bytes length:s.total_out];
    inflateEnd(&s);
    return r;
}

static BOOL LooksGzip(NSData *d) {
    const unsigned char *b = (const unsigned char *)d.bytes;
    return d.length > 2 && b[0] == 0x1f && b[1] == 0x8b;
}

// 路线A：gzip 的输入就是明文
static void CheckPlain(id data) {
    if (gIn || ![data isKindOfClass:[NSData class]]) return;
    NSData *d = (NSData *)data;
    if (d.length < 200 || d.length > 500000) return;
    const unsigned char *b = (const unsigned char *)d.bytes;
    if (!(b[0] == '{' || b[0] == '[')) return;      // 只认 JSON 开头
    gIn = 1;
    DumpText("[PLAIN]", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
    gIn = 0;
}

// 路线B：AES 输入是 gzip，先解压再看
static void CheckCipher(id data, id key, id iv, const char *how) {
    if (gIn || ![data isKindOfClass:[NSData class]]) return;
    NSData *d = (NSData *)data;
    if (d.length < 200 || d.length > 500000) return;
    if (!LooksGzip(d)) return;                       // 只认 gzip → 避开所有二进制流量
    gIn = 1;
    NSData *plain = Gunzip(d);
    if (plain.length) {
        NSString *ks = [key isKindOfClass:[NSData class]]
            ? [NSString stringWithFormat:@"(%luB)", (unsigned long)((NSData *)key).length] : @"?";
        os_log(gLog, "[HIT] %{public}s keyLen=%{public}s iv=%{public}s gzipLen=%lu",
               how, ks.UTF8String,
               ([iv isKindOfClass:[NSString class]] ? (NSString *)iv : @"?").UTF8String,
               (unsigned long)d.length);
        DumpText("[PLAIN]", [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding]);
    }
    gIn = 0;
}

%hook JCOREUtilities
+ (id)gzip:(id)data { CheckPlain(data); return %orig; }
- (id)gzip:(id)data { CheckPlain(data); return %orig; }
%end

%hook JCOREDataSecurity
+ (id)aesEncryptData:(id)d withKey:(id)k iv:(id)iv { CheckCipher(d, k, iv, "+aes128"); return %orig; }
- (id)aesEncryptData:(id)d withKey:(id)k iv:(id)iv { CheckCipher(d, k, iv, "-aes128"); return %orig; }
+ (id)aes256EncryptData:(id)d withKey:(id)k iv:(id)iv { CheckCipher(d, k, iv, "+aes256"); return %orig; }
- (id)aes256EncryptData:(id)d withKey:(id)k iv:(id)iv { CheckCipher(d, k, iv, "-aes256"); return %orig; }
%end

%ctor {
    gLog = os_log_create("com.rev.bodyprobe", "general");
    os_log(gLog, "BodyProbe 1.1 已加载（gzip 入口 + AES-128/256 双路抓明文）");
}
