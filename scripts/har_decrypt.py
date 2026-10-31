#!/usr/bin/env python3
"""
解密 Ninebot 抓包（HAR）：iot_ota / sis 信封

前提：必须知道该请求的 seed（App 内 arc4random 生成，不随请求发送）。
      用 SeedProbe.dylib 装进 App，触发一次请求，日志里的
          [SEED] seed=<数字> key=<md5十六进制>
      就是它。seed 与 key 二选一即可（给 key 时直接用它）。

用法：
  python3 har_decrypt.py --har x.har --seed 123456789
  python3 har_decrypt.py --har x.har --key 25f9e794323b453885f5181f1b624d0b
"""
import argparse, base64, gzip, hashlib, json, os, subprocess, sys, tempfile

IV = b"0102030405060708"


def aes_cbc_dec(data: bytes, key: bytes) -> bytes:
    with tempfile.TemporaryDirectory() as td:
        i, o = os.path.join(td, "i"), os.path.join(td, "o")
        open(i, "wb").write(data)
        r = subprocess.run(["openssl", "enc", "-d", "-aes-256-cbc",
                            "-K", key.hex(), "-iv", IV.hex(), "-in", i, "-out", o],
                           capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.decode(errors="replace")[:200])
        return open(o, "rb").read()


def maybe_gunzip(d: bytes) -> bytes:
    return gzip.decompress(d) if d[:2] == b"\x1f\x8b" else d


def try_dec(b64: str, key: bytes) -> str:
    raw = base64.b64decode(b64.replace("\\/", "/") + "=" * (-len(b64) % 4))
    plain = maybe_gunzip(aes_cbc_dec(raw, key))
    try:
        return json.dumps(json.loads(plain), ensure_ascii=False, indent=2)
    except Exception:
        return plain.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--har", required=True)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--key", help="直接给 MD5 十六进制密钥（32 字符）")
    a = ap.parse_args()
    if not a.seed and not a.key:
        sys.exit("需要 --seed 或 --key")
    key = a.key.encode() if a.key else hashlib.md5(str(a.seed).encode()).hexdigest().encode()
    print(f"# 使用密钥: {key.decode()}\n")

    har = json.load(open(a.har, encoding="utf-8"))
    for idx, e in enumerate(har["log"]["entries"]):
        url = e["request"]["url"]
        print("=" * 70)
        print(f"[{idx}] {e['request']['method']} {url}")
        body = (e["request"].get("postData") or {}).get("text", "")
        if body:
            try:
                j = json.loads(body)
                if "d" in j:
                    print("\n--- 请求明文 ---")
                    print(try_dec(j["d"], key))
                else:
                    print("\n请求体(明文):", body[:400])
            except Exception as ex:
                print("请求体解析失败:", ex)
        ct = (e["response"].get("content") or {}).get("text", "")
        if ct:
            try:
                j = json.loads(ct)
                if "r" in j:
                    print("\n--- 响应明文 ---")
                    print(try_dec(j["r"], key))
                else:
                    print("\n响应(明文):", ct[:400])
            except Exception as ex:
                print("响应解析失败:", ex)
        print()


if __name__ == "__main__":
    main()
