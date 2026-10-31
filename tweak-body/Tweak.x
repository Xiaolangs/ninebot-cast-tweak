// BodyProbe — 只钩 gzip 入口，拿到加密前的请求明文 JSON
//
// 为什么安全：App 在加密请求体之前一定会调用 [JCOREUtilities gzip:]。
// 只钩这一个方法（每请求一次），不做密钥处理、不做数组/字典操作、
// 不碰 BLE 高频路径。命中时按 700 字符分段输出，绝不截断。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <substrate.h>

static os_log_t gLog = NULL;
static volatile int gIn = 0;
static int gLines = 0;

#define BP_CHUNK 700
#define BP_MAX   400

static void Dump(const char *tag, NSString *text) {
    if (!text.length || gLines > BP_MAX) return;
    NSUInteger total = (text.length + BP_CHUNK - 1) / BP_CHUNK;
    for (NSUInteger i = 0; i < total && gLines <= BP_MAX; i++) {
        NSUInteger loc = i * BP_CHUNK;
        NSUInteger len = MIN((NSUInteger)BP_CHUNK, text.length - loc);
        gLines++;
        os_log(gLog, "%{public}s[%lu/%lu] %{public}s", tag,
               (unsigned long)(i + 1), (unsigned long)total,
               [text substringWithRange:NSMakeRange(loc, len)].UTF8String);
    }
}

static void CheckBody(id data) {
    if (gIn) return;
    if (![data isKindOfClass:[NSData class]]) return;
    NSData *d = (NSData *)data;
    if (d.length < 200 || d.length > 200000) return;
    gIn = 1;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s.length && [s containsString:@"part_type"]) Dump("[BODY]", s);
    gIn = 0;
}

%hook JCOREUtilities

+ (id)gzip:(id)data { CheckBody(data); return %orig; }
- (id)gzip:(id)data { CheckBody(data); return %orig; }

%end

%ctor {
    gLog = os_log_create("com.rev.bodyprobe", "general");
    os_log(gLog, "BodyProbe 1.0 已加载（抓取请求明文）");
}
