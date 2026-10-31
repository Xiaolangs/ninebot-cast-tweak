// KeyBodyProbe 1.2 — 线程局部配对 + 全量密钥清单
//
// 问题：之前用全局变量存密钥，body 落定时取到的是别的请求/别的线程的值，配对失败。
// 现在：① 线程局部 __thread 保存本线程最近一次密钥；② 同时维护全量清单，
//       body 落定时把「本线程密钥」和「所有见过的密钥」一起打印。
// 钩子仍只有三个低频点：rsaEncrypt:publicKey: / encryptKeyForHttp: / setHTTPBody:

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static __thread char tlKey[128] = {0};          // 本线程最近一次密钥（C 数组，避免 ARC 线程局部限制）
static NSMutableArray<NSString *> *gAll = nil;   // 全量清单
static volatile int gIn = 0;
static int gLines = 0;

#define KB_CHUNK 700
#define KB_MAX_LINES 400
#define KB_MAX_KEYS 12

static NSString *Hex(id o) {
    if ([o isKindOfClass:[NSString class]]) return (NSString *)o;
    if ([o isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)o;
        NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
        const unsigned char *b = (const unsigned char *)d.bytes;
        for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
        return s;
    }
    return nil;
}

static void Remember(id key) {
    NSString *h = Hex(key);
    if (!h.length) return;
    strncpy(tlKey, h.UTF8String ?: "", sizeof(tlKey) - 1);
    tlKey[sizeof(tlKey) - 1] = 0;
    if (gAll.count < KB_MAX_KEYS && ![gAll containsObject:h]) [gAll addObject:h];
    os_log(gLog, "[KEY ] %{public}s  rawLen=%lu", h.UTF8String,
           (unsigned long)([key isKindOfClass:[NSData class]] ? ((NSData *)key).length
                          : ([key isKindOfClass:[NSString class]] ? ((NSString *)key).length : 0)));
}

static void Emit(const char *tag, NSString *s) {
    if (!s.length || gIn || gLines > KB_MAX_LINES) return;
    gIn = 1;
    NSUInteger total = (s.length + KB_CHUNK - 1) / KB_CHUNK;
    for (NSUInteger i = 0; i < total && gLines <= KB_MAX_LINES; i++) {
        NSUInteger loc = i * KB_CHUNK, len = MIN((NSUInteger)KB_CHUNK, s.length - loc);
        gLines++;
        os_log(gLog, "%{public}s[%lu/%lu] %{public}s", tag, (unsigned long)(i+1),
               (unsigned long)total, [s substringWithRange:NSMakeRange(loc, len)].UTF8String);
    }
    gIn = 0;
}

%hook JCOREDataSecurity

+ (id)rsaEncrypt:(id)data publicKey:(id)pk { id r = %orig; Remember(data); return r; }
- (id)rsaEncrypt:(id)data publicKey:(id)pk { id r = %orig; Remember(data); return r; }
+ (id)encryptKeyForHttp:(unsigned int *)out { id r = %orig; Remember(r); return r; }
- (id)encryptKeyForHttp:(unsigned int *)out { id r = %orig; Remember(r); return r; }

%end

%hook NSMutableURLRequest

- (void)setHTTPBody:(id)body {
    %orig;
    if (gIn || gLines > KB_MAX_LINES) return;
    if (![body isKindOfClass:[NSData class]]) return;
    NSData *d = (NSData *)body;
    if (d.length < 200 || d.length > 200000) return;
    const unsigned char *b = (const unsigned char *)d.bytes;
    if (b[0] != '{') return;
    NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!text.length || ![text containsString:@"\"d\""]) return;

    id url = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"URL"));
    id us  = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
    os_log(gLog, "[BODY] url=%{public}s len=%lu tlKey=%{public}s",
           ([us isKindOfClass:[NSString class]] ? (NSString *)us : @"?").UTF8String,
           (unsigned long)d.length, (tlKey[0] ? tlKey : "(无)"));
    os_log(gLog, "[BODY] 全量密钥清单(%lu): %{public}s",
           (unsigned long)gAll.count, [gAll componentsJoinedByString:@","].UTF8String);
    Emit("[BODY]", text);
}

%end

%ctor {
    gLog = os_log_create("com.rev.keybody", "general");
    gAll = [NSMutableArray array];
    os_log(gLog, "KeyBodyProbe 1.2 已加载（线程局部配对 + 全量密钥）");
}
