// KeyProbe — 只观察 HTTP 加密密钥的派生过程（低频，安全）
//
// 背景：JCOREDataSecurity 的 HTTP 加密密钥 = MD5(seed 的十进制字符串)
//       seed 由上层注入。服务端报 "code:5 encryption failed" 意味着
//       客户端用的 key 与服务端不同 → 只要看到 seed/key 就能判断原因。
//
// 这些方法都是「每请求一次」级别，不在 BLE 热路径上，可安全挂载。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <stdarg.h>
#import <stdio.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static int      gN = 0;
static CFAbsoluteTime gLast = 0;

#define KP_MAX   300
#define KP_GAP   0.03

static void Emit(const char *tag, const char *fmt, ...) {
    if (gN >= KP_MAX) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLast < KP_GAP) return;
    gLast = now; gN++;
    char buf[512];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    os_log(gLog, "%{public}s %{public}s", tag, buf);
}

static NSString *Short(id o) {
    if (!o) return @"(nil)";
    NSString *s = [o isKindOfClass:[NSString class]] ? (NSString *)o : [o description];
    if (![s isKindOfClass:[NSString class]]) return @"?";
    return s.length > 80 ? [[s substringToIndex:80] stringByAppendingString:@"…"] : s;
}

%hook JCOREDataSecurity

// seed → key 的派生（这里是关键：seed 是什么值）
+ (id)generateSeedKey:(unsigned long long)seed {
    id r = %orig;
    Emit("[KEY] +generateSeedKey", "seed=%llu (0x%llx) -> key=%s",
         seed, seed, Short(r).UTF8String);
    return r;
}
- (id)generateSeedKey:(unsigned long long)seed {
    id r = %orig;
    Emit("[KEY] -generateSeedKey", "seed=%llu (0x%llx) -> key=%s",
         seed, seed, Short(r).UTF8String);
    return r;
}

// 取 seed 派生 key（带缓存）
+ (id)encryptKeyWithSeed:(unsigned long long)seed {
    id r = %orig;
    Emit("[KEY] +keyWithSeed", "seed=%llu key=%s", seed, Short(r).UTF8String);
    return r;
}
- (id)encryptKeyWithSeed:(unsigned long long)seed {
    id r = %orig;
    Emit("[KEY] -keyWithSeed", "seed=%llu key=%s", seed, Short(r).UTF8String);
    return r;
}

// 当前 HTTP 用的 key
+ (id)encryptKeyForHttp:(void *)out {
    id r = %orig;
    Emit("[KEY] +keyForHttp", "key=%s", Short(r).UTF8String);
    return r;
}
- (id)encryptKeyForHttp:(void *)out {
    id r = %orig;
    Emit("[KEY] -keyForHttp", "key=%s", Short(r).UTF8String);
    return r;
}

// 真正加密请求体时用的 key + 明文长度
+ (id)encrypt:(id)plain aesKey:(id)key {
    Emit("[KEY] +encrypt", "key=%s plainLen=%lu",
         Short(key).UTF8String,
         (unsigned long)([plain isKindOfClass:[NSData class]] ? ((NSData *)plain).length : 0));
    return %orig;
}
- (id)encrypt:(id)plain aesKey:(id)key {
    Emit("[KEY] -encrypt", "key=%s plainLen=%lu",
         Short(key).UTF8String,
         (unsigned long)([plain isKindOfClass:[NSData class]] ? ((NSData *)plain).length : 0));
    return %orig;
}

%end

%ctor {
    gLog = os_log_create("com.rev.keyprobe", "general");
    os_log(gLog, "KeyProbe 1.0 已加载（观察 HTTP 加密密钥派生）");
}
