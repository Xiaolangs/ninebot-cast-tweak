#!/usr/bin/env python3
"""
Ninebot / JCore "sis" 请求加解密参考实现
（逆向自 cn.ninebot.segway 6.10.9，用于 /iot_ota/ota/get-last-firmware 等接口）

================= 算法 ==================
请求方向：
  seed    = 随机 32 位整数（App 用 arc4random()）
  aesKey  = MD5( str(seed) ) 的十六进制字符串        → 32 字节 ASCII
  body    = gzip( JSON 明文 )
  d       = Base64( AES-256-CBC( body, key=aesKey, iv="0102030405060708", PKCS7 ) )
  k       = Base64( RSA-1024-PKCS1( aesKey ) )        → 128 字节
  p       = 101（协议标识，常量）
  请求体   = {"k":"<k>","p":101,"d":"<d>"}

响应方向：
  用同一个 aesKey 解 d：gunzip( AES-256-CBC 解密( Base64(d) ) ) → JSON

关键点：
  * IV 是硬编码 ASCII 串 "0102030405060708"（不是随机）
  * 密钥是 MD5 的【十六进制文本】当 32 字节用，不是 MD5 的 16 字节原始值
  * RSA 公钥（1024-bit，SPKI）内嵌在 App 二进制里，见 PUBLIC_KEY_B64
  * 因此：能自己加密发请求；但他人抓的包无法解密（RSA 私钥在服务端）
==========================================
"""
import argparse, base64, gzip, hashlib, json, os, subprocess, sys, tempfile

# 从 Ninebot 二进制中提取（JCOREHttpSisRequest authorizationString 内联）
PUBLIC_KEY_B64 = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCi0v4VEUhOdfIEfFCrPC72pcDsQF/luTmr"
    "4q34NY0EZYGKzfQuTrUAm916P52HCgF+342gjZ/Nvijts5543qYNyoLvgtu4NRcHJmuGI/w7"
    "qifhfsivYeoEj9wYphXOyB9HUjzwn1BtAih+1RyUrcErCi249yabUOIKQygPZ9OXXQIDAQAB"
)
IV = b"0102030405060708"
P_FIELD = 101


def derive_key(seed: int) -> bytes:
    """aesKey = MD5(十进制 seed) 的十六进制串，作为 32 字节 ASCII 密钥"""
    return hashlib.md5(str(seed).encode()).hexdigest().encode()


def _openssl(args, stdin=None):
    r = subprocess.run(["openssl"] + args, input=stdin, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"openssl {args[0]} 失败: {r.stderr.decode(errors='replace')[:300]}")
    return r.stdout


def aes_cbc(data: bytes, key: bytes, encrypt: bool) -> bytes:
    with tempfile.TemporaryDirectory() as td:
        inp, out = os.path.join(td, "in"), os.path.join(td, "out")
        open(inp, "wb").write(data)
        args = ["enc"] + ([] if encrypt else ["-d"]) + [
            "-aes-256-cbc", "-K", key.hex(), "-iv", IV.hex(), "-in", inp, "-out", out]
        _openssl(args)
        return open(out, "rb").read()


def rsa_encrypt(data: bytes) -> bytes:
    with tempfile.TemporaryDirectory() as td:
        der, inp, out = (os.path.join(td, n) for n in ("pub.der", "in", "out"))
        open(der, "wb").write(base64.b64decode(PUBLIC_KEY_B64))
        open(inp, "wb").write(data)
        _openssl(["pkeyutl", "-encrypt", "-pubin", "-inkey", der, "-keyform", "DER",
                  "-pkeyopt", "rsa_padding_mode:pkcs1", "-in", inp, "-out", out])
        return open(out, "rb").read()


def build_body(plain_json: bytes, seed: int) -> dict:
    key = derive_key(seed)
    d = base64.b64encode(aes_cbc(gzip.compress(plain_json), key, True)).decode()
    k = base64.b64encode(rsa_encrypt(key)).decode()
    return {"k": k, "p": P_FIELD, "d": d}


def decrypt_d(d_b64: str, key: bytes) -> bytes:
    return gzip.decompress(aes_cbc(base64.b64decode(d_b64), key, False))


def main():
    ap = argparse.ArgumentParser(description="Ninebot sis 请求加解密")
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("encrypt", help="明文 JSON → {k,p,d}")
    e.add_argument("--json", required=True, help="明文 JSON 文件")
    e.add_argument("--seed", type=int, default=None, help="种子（默认随机）")

    d = sub.add_parser("decrypt", help="d 字段 → 明文")
    d.add_argument("--d", required=True, help="响应里的 d（base64）")
    d.add_argument("--seed", type=int, required=True, help="当初加密用的 seed")

    a = ap.parse_args()
    if a.cmd == "encrypt":
        seed = a.seed if a.seed is not None else int.from_bytes(os.urandom(4), "big")
        plain = open(a.json, "rb").read().strip()
        body = build_body(plain, seed)
        print(f"# seed = {seed}")
        print(f"# aesKey = {derive_key(seed).decode()}")
        print(json.dumps(body, ensure_ascii=False))
    else:
        print(decrypt_d(a.d, derive_key(a.seed)).decode())


if __name__ == "__main__":
    main()
