// SeedProbe 1.1 — 把「加密种子」和「请求 URL」绑定输出
//
// 背景：iot_ota 的 d 用 AES-256-CBC，密钥 = MD5(seed)，seed 由 arc4random 生成、
// 不随请求发送。要解密抓包就必须知道对应请求的 seed。
// 1.0 只打 seed，需要靠时间戳人工对齐；1.1 用线程局部变量把它和 URL 绑在一起，
// 直接给出「这条请求用的是哪个 seed」。
//
// 依然只涉及两个低频点（每请求一次），无大数据处理。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static __thread unsigned int tlSeed = 0;      // 当前线程最近一次生成的种子

%hook JCOREDataSecurity

+ (id)encryptKeyForHttp:(unsigned int *)out {
    id r = %orig;
    if (out) { tlSeed = *out; }
    return r;
}
- (id)encryptKeyForHttp:(unsigned int *)out {
    id r = %orig;
    if (out) { tlSeed = *out; }
    return r;
}

%end

// 请求体落定时，把 URL 与种子配对输出
%hook NSMutableURLRequest

- (void)setHTTPBody:(id)body {
    if (tlSeed != 0) {
        id url = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"URL"));
        id s = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
        if ([s isKindOfClass:[NSString class]]) {
            os_log(gLog, "[PAIR] seed=%u url=%{public}s", tlSeed, ((NSString *)s).UTF8String);
        }
    }
    %orig;
}

%end

%ctor {
    gLog = os_log_create("com.rev.seedprobe", "general");
    os_log(gLog, "SeedProbe 1.1 已加载（seed ↔ URL 配对）");
}
