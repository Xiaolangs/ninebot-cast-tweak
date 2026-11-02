// NbKeyGrab — 拦截 CommonCrypto 解密，抓出 .nb 动态配置包的 AES key/iv
//
// 背景：DynamicPackage/<vehicle_type>/encrypt/code/*.nb 全部是 AES 密文
// （base64，熵 7.99，长度为 16 倍数），key/iv 由 /vehicle/device-config/sign-content 下发。
// 抓到 key/iv 后即可在电脑上离线解密全部 68 个配置文件。
//
// 手段：dyld interpose 拦截 CCCrypt 与 CCCryptorCreate（不依赖 substrate）。
// 过滤：只记录「解密方向、数据长度 >= 900 字节」的调用；已知 .nb 尺寸见下。
// 上限 60 条。

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <CommonCrypto/CommonCryptor.h>

static os_log_t gLog = NULL;
static int gN = 0;

// 已知 .nb 解码后尺寸（用于识别）
static const size_t kSizes[] = {62144, 18880, 2944, 976, 82860};

static void HexLog(const char *tag, const void *p, size_t n, size_t cap) {
    if (!p || !n) { os_log(gLog, "[NB] %{public}s=(null)", tag); return; }
    size_t m = n < cap ? n : cap;
    char buf[200] = {0};
    const unsigned char *b = (const unsigned char *)p;
    for (size_t i = 0; i < m && i*2+2 < sizeof(buf); i++) snprintf(buf+i*2, 3, "%02x", b[i]);
    os_log(gLog, "[NB] %{public}s(len=%lu)=%{public}s", tag, (unsigned long)n, buf);
}

typedef CCCryptorStatus (*CCCryptFn)(CCOperation, CCAlgorithm, CCOptions,
                                     const void *, size_t, const void *,
                                     const void *, size_t, void *, size_t, size_t *);
extern CCCryptorStatus CCCrypt(CCOperation, CCAlgorithm, CCOptions,
                               const void *, size_t, const void *,
                               const void *, size_t, void *, size_t, size_t *);
static CCCryptFn gOrigCCCrypt = NULL;

static CCCryptorStatus MyCCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options,
                                 const void *key, size_t keyLength, const void *iv,
                                 const void *dataIn, size_t dataInLength,
                                 void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved) {
    if (op == kCCDecrypt && alg == kCCAlgorithmAES && dataInLength >= 900 && gN < 60) {
        gN++;
        os_log(gLog, "[NB] DECRYPT dataLen=%lu keyLen=%lu opt=%u",
               (unsigned long)dataInLength, (unsigned long)keyLength, (unsigned)options);
        HexLog("key", key, keyLength, 64);
        HexLog("iv", iv, 16, 16);
    }
    return gOrigCCCrypt(op, alg, options, key, keyLength, iv, dataIn, dataInLength,
                        dataOut, dataOutAvailable, dataOutMoved);
}

// 流式接口：CCCryptorCreate 会带出 key/iv
typedef CCCryptorStatus (*CreateFn)(CCOperation, CCAlgorithm, CCOptions,
                                    const void *, size_t, const void *, CCCryptorRef *);
extern CCCryptorStatus CCCryptorCreate(CCOperation, CCAlgorithm, CCOptions,
                                       const void *, size_t, const void *, CCCryptorRef *);
static CreateFn gOrigCreate = NULL;

static CCCryptorStatus MyCreate(CCOperation op, CCAlgorithm alg, CCOptions options,
                                const void *key, size_t keyLength, const void *iv,
                                CCCryptorRef *out) {
    if (op == kCCDecrypt && alg == kCCAlgorithmAES && gN < 60 && keyLength >= 16) {
        gN++;
        os_log(gLog, "[NB] CREATE-DEC keyLen=%lu opt=%u", (unsigned long)keyLength, (unsigned)options);
        HexLog("key", key, keyLength, 64);
        HexLog("iv", iv, 16, 16);
    }
    return gOrigCreate(op, alg, options, key, keyLength, iv, out);
}

__attribute__((used)) static struct {
    const void *replacement; const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)MyCCCrypt, (const void *)CCCrypt },
    { (const void *)MyCreate,  (const void *)CCCryptorCreate },
};

__attribute__((constructor)) static void Init(void) {
    gLog = os_log_create("com.rev.nbkey", "general");
    gOrigCCCrypt = (CCCryptFn)CCCrypt;
    gOrigCreate  = (CreateFn)CCCryptorCreate;
    os_log(gLog, "NbKeyGrab 1.0 已加载（抓 AES 解密 key/iv）");
}
