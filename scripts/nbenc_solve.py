#!/usr/bin/env python3
"""
NBEncrypt / iot_ota 参数加密算法求解器

已知结构（静态分析得出）：
  明文 = JSON(parts[]...)
  传输 = gzip(明文)                       ← JCore 路径确认
  信封 = {"k": base64(RSA(会话密钥)), "p": 101, "d": base64(AES(gzip(明文)))}
  原语 = CommonCrypto AES + SecKeyEncrypt(RSA) + CC_MD5 + CCHmac
  时间 = NSUserDefaults["serviceTime"]（已用服务器校准，故客户端改时间会失败）
  已确认硬编码 IV 之一 = "0102030405060708"（JCore sis 层）

用法：
  python3 nbenc_solve.py --plain plain.json --cipher <base64> --time 1793413281100
它会穷举常见 KDF / 模式 / IV 组合，命中即打印配方。
"""
import argparse, base64, gzip, hashlib, itertools, sys

def try_aes(key, data, mode, iv=None):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError:
        return None
    try:
        if mode == "ecb":
            c = Cipher(algorithms.AES(key), modes.ECB())
        elif mode == "cbc":
            c = Cipher(algorithms.AES(key), modes.CBC(iv or b"\x00"*16))
        elif mode == "ctr":
            c = Cipher(algorithms.AES(key), modes.CTR(iv or b"\x00"*16))
        elif mode == "gcm":
            c = Cipher(algorithms.AES(key), modes.GCM(iv or b"\x00"*12))
        else:
            return None
        e = c.encryptor()
        return e.update(data) + e.finalize()
    except Exception:
        return None

def kdf_candidates(t):
    """由 serviceTime 派生候选密钥"""
    s = str(t)
    out = []
    for name, v in [
        ("md5(time)",          hashlib.md5(s.encode()).digest()),
        ("md5(time)_hex",      hashlib.md5(s.encode()).hexdigest().encode()),
        ("md5(time)[:16]",     hashlib.md5(s.encode()).digest()[:16]),
        ("sha256(time)",       hashlib.sha256(s.encode()).digest()),
        ("sha256(time)[:16]",  hashlib.sha256(s.encode()).digest()[:16]),
        ("md5(time//1000)",    hashlib.md5(str(t//1000).encode()).digest()),
        ("md5(md5hex)",        hashlib.md5(hashlib.md5(s.encode()).hexdigest().encode()).digest()),
    ]:
        out.append((name, v))
    return out

IVS = [b"0102030405060708", b"\x00"*16, b"0000000000000000"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plain", required=True, help="明文 JSON 文件")
    ap.add_argument("--cipher", required=True, help="抓到的 d 字段(base64)")
    ap.add_argument("--time", type=int, default=0, help="serviceTime")
    a = ap.parse_args()

    plain = open(a.plain, "rb").read().strip()
    target = base64.b64decode(a.cipher + "=" * (-len(a.cipher) % 4))
    bodies = {"json": plain, "gzip(json)": gzip.compress(plain, mtime=0)}

    print(f"明文 {len(plain)} B，密文 {len(target)} B")
    for bname, body in bodies.items():
        for kname, key in kdf_candidates(a.time):
            for mode in ("ecb", "cbc", "ctr"):
                for iv in (IVS if mode in ("cbc", "ctr") else [None]):
                    got = try_aes(key, body, mode, iv)
                    if not got:
                        continue
                    if got[:len(target)] == target or got[:16] == target[:16]:
                        ivdesc = repr(iv) if iv else "N/A"
                        print("\n✅ 命中: body=%s key=%s mode=AES-%d-%s iv=%s"
                              % (bname, kname, len(key)*8, mode.upper(), ivdesc))
                        return
    print("\n❌ 未命中。可能原因：")
    print("  - d 里还包含额外封装（长度前缀/随机 IV 前置）")
    print("  - 密钥不是由 serviceTime 直接派生（可能需要 checkcode / 设备信息参与）")
    print("  - 需要先解密 k（RSA 私钥，服务端持有）确定会话密钥")

if __name__ == "__main__":
    main()
