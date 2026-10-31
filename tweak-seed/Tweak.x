// SeedProbe 1.2 — 直接在加密点截取真实密钥
//
// 之前用 seed 思路失败：请求的 aesKey 是复用的，不总是当场由 seed 派生。
// 改为在最终加密处截获：
//   * 加密方向：只处理 gzip 头(1f 8b)的数据 —— 即 HTTP 请求体。
//     BLE/视频帧绝不可能是 gzip，因此天然避开高频路径（这正是之前闪退的原因）。
//   * 解密方向：只处理「密钥已见过」的调用 —— 即对应的响应。
// 上限 30 条，带重入锁，无大数据拷贝。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static volatile int gIn = 0;
static int gN = 0;
static NSMutableArray *gKeys = nil;   // 见过的密钥（十六进制串）

static NSString *KeyStr(id k) {
    if ([k isKindOfClass:[NSData class]]) return [(NSData *)k description];
    if ([k isKindOfClass:[NSString class]]) return (NSString *)k;
    return @"?";
}
static BOOL HexMatches(id k) {
    NSString *s = KeyStr(k);
    for (NSString *x in gKeys) if ([s containsString:x]) return YES;
    return NO;
}

%hook JCOREDataSecurity

+ (id)aes256EncryptData:(id)data withKey:(id)k iv:(id)iv {
    id r = %orig;
    if (gIn || gN >= 30) return r;
    if (![data isKindOfClass:[NSData class]]) return r;
    NSData *d = (NSData *)data;
    const unsigned char *b = (const unsigned char *)d.bytes;
    if (d.length < 8 || b[0] != 0x1f || b[1] != 0x8b) return r;   // 只认 gzip 请求体
    gIn = 1; gN++;
    NSString *ks = KeyStr(k);
    if (ks.length && gKeys.count < 8) [gKeys addObject:ks];
    os_log(gLog, "[GRAB] encrypt  key=%{public}s", ks.UTF8String);
    os_log(gLog, "[GRAB]   iv=%{public}s  gzipLen=%lu", KeyStr(iv).UTF8String, (unsigned long)d.length);
    os_log(gLog, "[GRAB]   outLen=%lu", (unsigned long)([r isKindOfClass:[NSData class]] ? ((NSData *)r).length : 0));
    gIn = 0;
    return r;
}

+ (id)aes256DecryptData:(id)data withKey:(id)k iv:(id)iv {
    id r = %orig;
    if (gIn || gN >= 30) return r;
    if (!HexMatches(k)) return r;                                  // 只认自己刚见过的密钥
    gIn = 1; gN++;
    os_log(gLog, "[GRAB] decrypt  key=%{public}s outLen=%lu", KeyStr(k).UTF8String,
           (unsigned long)([r isKindOfClass:[NSData class]] ? ((NSData *)r).length : 0));
    if ([r isKindOfClass:[NSData class]]) {
        NSData *rd = (NSData *)r;
        const unsigned char *b = (const unsigned char *)rd.bytes;
        os_log(gLog, "[GRAB]   out magic=%02x%02x%02x%02x gzip=%s", b[0], b[1], b[2], b[3],
               (rd.length > 2 && b[0] == 0x1f && b[1] == 0x8b) ? "YES" : "NO");
    }
    gIn = 0;
    return r;
}

%end

%ctor {
    gLog = os_log_create("com.rev.seedprobe", "general");
    gKeys = [NSMutableArray array];
    os_log(gLog, "SeedProbe 1.2 已加载（在加密点截取真实密钥）");
}
