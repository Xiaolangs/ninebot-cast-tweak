// NetPlainLog — 只做一件事：把接口请求/响应的明文打出来
//
// 设计前提：这个 App 的接口是 JSON。响应体解密后的明文最终会进
// NSJSONSerialization，在这里打印即可拿到「所有接口的明文」，
// 不需要去挂 AES/SM4（那会在 BLE 场景高频触发导致卡死）。
//
// 安全阀：总条数硬上限 + 时间节流 + 长度截断 + 重入保护。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <substrate.h>

static os_log_t      gLog      = NULL;
static int           gCount    = 0;
static CFAbsoluteTime gLast    = 0;
static volatile int  gInHook   = 0;

#define PO_MAX_LINES   120      // 总打印条数上限
#define PO_MIN_GAP     0.05     // 两条之间最小间隔（秒）
#define PO_MAX_CHARS   400      // 单条最大字符数
#define PO_MAX_BYTES   65536    // 超过这个大小直接跳过，避免处理大包

static void Emit(const char *tag, NSString *text) {
    if (!text || text.length < 8) return;
    if (gCount >= PO_MAX_LINES) return;
    if (gInHook) return;                       // 重入保护
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLast < PO_MIN_GAP) return;      // 节流
    gInHook = 1;
    gLast = now;
    gCount++;
    NSString *t = text.length > PO_MAX_CHARS
        ? [[text substringToIndex:PO_MAX_CHARS] stringByAppendingString:@"…(截断)"]
        : text;
    os_log(gLog, "%{public}s %{public}s", tag, t.UTF8String);
    gInHook = 0;
}

static NSString *Plain(id data) {
    if (![data isKindOfClass:[NSData class]]) return nil;
    NSData *d = (NSData *)data;
    if (d.length == 0 || d.length > PO_MAX_BYTES) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(id)data options:(unsigned long)opt error:(id *)err {
    id r = %orig;
    Emit("[RESP]", Plain(data));
    return r;
}

+ (id)dataWithJSONObject:(id)obj options:(unsigned long)opt error:(id *)err {
    id r = %orig;
    Emit("[REQ] ", Plain(r));
    return r;
}

%end

// 附带打印 URL（只打一次每条，量很小），方便把明文和接口对上
%hook NSURLSession

- (id)dataTaskWithRequest:(id)req {
    if (gCount < PO_MAX_LINES) {
        id url = ((id (*)(id, SEL))objc_msgSend)(req, NSSelectorFromString(@"URL"));
        id s   = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
        if ([s isKindOfClass:[NSString class]]) Emit("[URL] ", s);
    }
    return %orig;
}

- (id)downloadTaskWithRequest:(id)req {
    if (gCount < PO_MAX_LINES) {
        id url = ((id (*)(id, SEL))objc_msgSend)(req, NSSelectorFromString(@"URL"));
        id s   = url ? ((id (*)(id, SEL))objc_msgSend)(url, NSSelectorFromString(@"absoluteString")) : nil;
        if ([s isKindOfClass:[NSString class]]) Emit("[DL]  ", s);
    }
    return %orig;
}

%end

%ctor {
    gLog = os_log_create("com.rev.netplainlog", "general");
    os_log(gLog, "NetPlainLog 1.0 已加载（接口明文打印，上限 %d 条）", PO_MAX_LINES);
}
