// KeyBodyProbe 1.0 — 只钩两个「已验证不崩」的点，拿到 密钥 + 请求体
//
//   1) +/-[JCOREDataSecurity encryptKeyForHttp:]   每请求一次，返回 AES 密钥
//   2) -[NSMutableURLRequest setHTTPBody:]         每请求一次，body 就是 wire JSON
//
// 不碰 gzip: / aesEncryptData: / aes256EncryptData: —— 那些是前几次闪退的来源。
// 拿到两者后在电脑上离线解：d --AES(key)--> wrapper --b64--> 内层业务 JSON。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static NSString *gKey = nil;        // 最近一次生成的密钥
static volatile int gIn = 0;
static int gLines = 0;

#define KB_CHUNK 700
#define KB_MAX_LINES 400

static void Emit(const char *tag, NSString *s) {
    if (!s.length || gIn || gLines > KB_MAX_LINES) return;
    gIn = 1;
    NSUInteger total = (s.length + KB_CHUNK - 1) / KB_CHUNK;
    for (NSUInteger i = 0; i < total && gLines <= KB_MAX_LINES; i++) {
        NSUInteger loc = i * KB_CHUNK;
        NSUInteger len = MIN((NSUInteger)KB_CHUNK, s.length - loc);
        gLines++;
        os_log(gLog, "%{public}s[%lu/%lu] %{public}s", tag,
               (unsigned long)(i + 1), (unsigned long)total,
               [s substringWithRange:NSMakeRange(loc, len)].UTF8String);
    }
    gIn = 0;
}

static NSString *KeyStr(id k) {
    if ([k isKindOfClass:[NSString class]]) return (NSString *)k;
    if ([k isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)k;
        NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
        const unsigned char *b = (const unsigned char *)d.bytes;
        for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
        return s;
    }
    return nil;
}

static void RememberKey(id key) {
    NSString *s = KeyStr(key);
    if (!s.length) return;
    gKey = [s copy];
    os_log(gLog, "[KEY ] len=%lu value=%{public}s",
           (unsigned long)s.length, s.UTF8String);
}

%hook JCOREDataSecurity

+ (id)encryptKeyForHttp:(unsigned int *)out {
    id r = %orig;
    RememberKey(r);
    return r;
}
- (id)encryptKeyForHttp:(unsigned int *)out {
    id r = %orig;
    RememberKey(r);
    return r;
}

%end

%hook NSMutableURLRequest

- (void)setHTTPBody:(id)body {
    %orig;
    if (gIn || gLines > KB_MAX_LINES) return;
    if (![body isKindOfClass:[NSData class]]) return;
    NSData *d = (NSData *)body;
    if (d.length < 200 || d.length > 200000) return;
    const unsigned char *b = (const unsigned char *)d.bytes;
    if (b[0] != '{') return;                      // wire JSON 以 { 开头；二进制请求直接跳过
    NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!text.length) return;
    if (![text containsString:@"\"d\""]) return;  // 只认带 d 字段的加密请求

    id url = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"URL"));
    id us  = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
    os_log(gLog, "[BODY] url=%{public}s len=%lu key=%{public}s",
           ([us isKindOfClass:[NSString class]] ? (NSString *)us : @"?").UTF8String,
           (unsigned long)d.length,
           (gKey.length ? gKey.UTF8String : "(尚未捕获)"));
    Emit("[BODY]", text);
}

%end

%ctor {
    gLog = os_log_create("com.rev.keybody", "general");
    os_log(gLog, "KeyBodyProbe 1.0 已加载（密钥 + wire 请求体）");
}
