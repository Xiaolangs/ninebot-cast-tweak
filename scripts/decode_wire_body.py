#!/usr/bin/env python3
"""
离线解码 wire 请求体：拿到 KeyBodyProbe 输出的 key + body 后，解出内层业务 JSON

用法:
  python3 decode_wire_body.py --body-file body.txt --key 944cb0c4b91f1e58bde8003a46460b16
  python3 decode_wire_body.py --body-file body.txt        # 自动用 body 内联的种子猜测（不可行时会报错）
"""
import argparse, base64, gzip, json, subprocess, tempfile, os, sys

IVS = {"iv0102": b"0102030405060708", "ivzero": b"\x00" * 16}

def aes_dec(data, key, alg, iv):
    with tempfile.TemporaryDirectory() as td:
        i, o = os.path.join(td, "i"), os.path.join(td, "o")
        open(i, "wb").write(data)
        cmd = ["openssl", "enc", "-d", "-" + alg, "-K", key.hex()]
        if iv is not None:
            cmd += ["-iv", iv.hex()]
        cmd += ["-in", i, "-out", o]
        r = subprocess.run(cmd, capture_output=True)
        return open(o, "rb").read() if r.returncode == 0 else None

def keyvariants(k):
    out = []
    kb = k.encode()
    if len(kb) == 32:                       # 32 位十六进制文本 → 两种理解
        out.append(("ascii32(aes256)", kb))
        try: out.append(("hexdec16(aes128)", bytes.fromhex(k)))
        except Exception: pass
    elif len(kb) == 16:
        out.append(("ascii16(aes128)", kb))
    else:
        out.append((f"raw{len(kb)}", kb[:32]))
        out.append(("md5hex", __import__("hashlib").md5(kb).hexdigest().encode()))
    return out

def try_unwrap(plain):
    """wrapper JSON -> 内层业务 JSON"""
    try:
        w = json.loads(plain.decode("utf-8"))
    except Exception:
        return None, plain
    if isinstance(w, dict) and isinstance(w.get("data"), str):
        try:
            return json.loads(base64.b64decode(w["data"].strip())), w
        except Exception:
            return None, w
    return w, None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--body-file", required=True)
    ap.add_argument("--key", required=True)
    a = ap.parse_args()

    raw = open(a.body_file, encoding="utf-8", errors="replace").read()
    # 允许直接贴日志（含 [BODY][1/5] 前缀）
    lines = []
    for ln in raw.splitlines():
        i = ln.find('{"')
        lines.append(ln[i:] if i >= 0 else ln)
    text = "".join(lines).strip()
    body = json.loads(text)
    print(f"# wire 字段: {list(body.keys())}")
    print(f"# p={body.get('p')} t={body.get('t')} h={body.get('h','')[:16]}… d={len(body.get('d',''))}B64")

    D = base64.b64decode(body["d"] + "=" * (-len(body["d"]) % 4))

    for kn, kb in keyvariants(a.key):
        for alg in (("aes-256-cbc", "aes-128-cbc") if len(kb) == 32 else ("aes-128-cbc",)):
            for ivn, iv in IVS.items():
                out = aes_dec(D, kb, alg, iv)
                if not out:
                    continue
                if out[:2] == b"\x1f\x8b":
                    try: out = gzip.decompress(out)
                    except Exception: pass
                inner, wrap = try_unwrap(out)
                if inner is not None:
                    print(f"\n✅ 解密成功   key={kn}  {alg}  {ivn}")
                    if isinstance(wrap, dict):
                        print(f"   wrapper.platform={wrap.get('platform')} timeStamp={wrap.get('timeStamp')}")
                        for k in ("keyDataOne","keyDataTwo","keyDataThree","keyDataFour"):
                            if k in wrap: print(f"   {k}={wrap[k]}")
                    print("\n--- 内层业务 JSON（完整请求参数）---")
                    print(json.dumps(inner, ensure_ascii=False, indent=2))
                    return
    print("\n❌ 所有密钥/模式组合均失败。请确认 key 是 KeyBodyProbe 的 [KEY] 行、body 是同一条请求")

if __name__ == "__main__":
    main()
