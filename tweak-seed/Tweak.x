// SeedProbe — 最小探针：只输出每个请求的加密种子
//
// 为什么需要它：iot_ota 的请求体 {k,p,d} 里，d 是 AES-256-CBC，密钥 = MD5(seed)，
// 而 seed 是客户端 arc4random 生成的、不随请求发送（服务端靠 RSA 解 k 拿到密钥）。
// 因此没有 seed 就无法解密抓到的包 —— 这个探针把 seed 打出来即可。
//
// 只钩一个方法，每请求调用一次，无数据拷贝、无字符串处理，风险极低。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <substrate.h>

static os_log_t gLog = NULL;

static void EmitSeed(unsigned int seed, id key) {
    NSString *ks = [key isKindOfClass:[NSString class]] ? (NSString *)key
                 : ([key isKindOfClass:[NSData class]]
                    ? [NSString stringWithFormat:@"(%luB)", (unsigned long)((NSData *)key).length]
                    : @"?");
    os_log(gLog, "[SEED] seed=%u key=%{public}s", seed, ks.UTF8String);
}

%hook JCOREDataSecurity

+ (id)encryptKeyForHttp:(unsigned int *)out {
    id r = %orig;
    if (out) EmitSeed(*out, r);
    return r;
}
- (id)encryptKeyForHttp:(unsigned int *)out {
    id r = %orig;
    if (out) EmitSeed(*out, r);
    return r;
}

%end

%ctor {
    gLog = os_log_create("com.rev.seedprobe", "general");
    os_log(gLog, "SeedProbe 1.0 已加载（输出请求加密种子）");
}
