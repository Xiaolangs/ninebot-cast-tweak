// CCCryptProbe 1.0 — 用 dyld interpose 拦截 CCCrypt，抓 AES 密钥
//
// 前面的教训：密钥不经过 rsaEncrypt:/encryptKeyForHttp:，说明它是 Swift/C 层
// 直接调 CommonCrypto。CCCrypt 是所有人的必经之路。
// 过滤条件：加密操作 + 数据长度 2000~4000 字节（实测请求体 d = 2560 字节）。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <CommonCrypto/CommonCryptor.h>

static os_log_t gLog = NULL;
static int gN = 0;

static CCCryptorStatus MyCCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options,
                                 const void *key, size_t keyLength,
                                 const void *iv,
                                 const void *dataIn, size_t dataInLength,
                                 void *dataOut, size_t dataOutAvailable,
                                 size_t *dataOutMoved);

typedef CCCryptorStatus (*CCCryptFn)(CCOperation, CCAlgorithm, CCOptions,
                                     const void *, size_t, const void *,
                                     const void *, size_t,
                                     void *, size_t, size_t *);
static CCCryptFn gOrig = NULL;
extern CCCryptorStatus CCCrypt(CCOperation, CCAlgorithm, CCOptions,
                               const void *, size_t, const void *,
                               const void *, size_t, void *, size_t, size_t *);

static void LogBytes(const char *tag, const void *p, size_t n, size_t cap) {
    if (!p || !n) { os_log(gLog, "%{public}s=(null)", tag); return; }
    size_t m = n < cap ? n : cap;
    char buf[160] = {0};
    const unsigned char *b = (const unsigned char *)p;
    for (size_t i = 0; i < m && i * 2 + 2 < sizeof(buf); i++)
        snprintf(buf + i * 2, 3, "%02x", b[i]);
    os_log(gLog, "%{public}s(len=%lu)=%{public}s", tag, (unsigned long)n, buf);
}

static CCCryptorStatus MyCCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options,
                                 const void *key, size_t keyLength,
                                 const void *iv,
                                 const void *dataIn, size_t dataInLength,
                                 void *dataOut, size_t dataOutAvailable,
                                 size_t *dataOutMoved) {
    // 只关心「加密 + 请求体长度」；不改变任何行为
    if (op == kCCEncrypt && dataInLength >= 2000 && dataInLength <= 4000 && gN < 20) {
        gN++;
        os_log(gLog, "[CC] ENCRYPT alg=%d opt=%u dataLen=%lu keyLen=%lu",
               (int)alg, (unsigned)options, (unsigned long)dataInLength, (unsigned long)keyLength);
        LogBytes("key", key, keyLength, 64);
        LogBytes("iv", iv, iv ? 16 : 0, 16);
    }
    return gOrig(op, alg, options, key, keyLength, iv, dataIn, dataInLength,
                 dataOut, dataOutAvailable, dataOutMoved);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)MyCCCrypt, (const void *)CCCrypt },
};

__attribute__((constructor)) static void Init(void) {
    gLog = os_log_create("com.rev.cccrypt", "general");
    gOrig = (CCCryptFn)CCCrypt;
    os_log(gLog, "CCCryptProbe 1.0 已加载（interpose CCCrypt）");
}
