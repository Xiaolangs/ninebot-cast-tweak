#!/usr/bin/env python3
"""
自行构造并发送 iot_ota 请求（不依赖 App、不依赖抓包解密）

原理：
  * 请求体 = {"k": RSA-1024(aesKey), "p":101, "d": AES-256-CBC(gzip(明文))}
  * aesKey = MD5(str(seed)) 的十六进制串；seed 自己选，密钥自己留着
  * 响应里的 r 用同一个 aesKey 解 → 明文 JSON
  所以：自己发的请求，自己能解响应。不需要服务端 RSA 私钥。

用法：
  python3 ota_query.py --token '<Access-Token>' --uid 541117341 \
      --wnumber '你的整车序列号' --pn 'TFT料号' --version 0 --part TFT

  # 只看将要发送的内容，不真的发
  python3 ota_query.py ... --dry-run

怎么拿到这些参数：
  --token     App 请求头 Access-Token（JWT，eyJhbGciOiJSUzI1NiI...）
  --uid       请求头 Uid / MID
  --wnumber   整车序列号（车身铭牌 或 抓包里的 wnumber）
  --pn        TFT 料号（rTftPN 读到的值；不确定可先留空试）
"""
import argparse, base64, gzip, hashlib, json, os, sys, time, uuid, urllib.request, urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sis_crypto as S

URL = "https://steeldust.ninebot.com/iot_ota/ota/get-last-firmware"


def build_plain(a, seed):
    parts = []
    for p in a.part.split(","):
        p = p.strip().upper()
        if not p:
            continue
        item = {"part_type": p, "version": str(a.version)}
        if a.pn:
            item["pn"] = a.pn
        parts.append(item)
    payload = {
        "uid": a.uid,
        "wnumber": a.wnumber,
        "env_type": "1",
        "download_type": "2",
        "parts": parts,
    }
    return json.dumps(payload, separators=(",", ":")).encode()


def headers(a, now_ms):
    h = {
        "Host": "steeldust.ninebot.com",
        "Language": "zh",
        "Client-Ver": a.app_version,
        "User-Agent": f"Ninebot/{a.app_ver_name} (cn.ninebot.segway; build:3816; iOS 27.0.1) Alamofire/5.10.2",
        "MID": a.uid,
        "Uid": a.uid,
        "NET-Version": "1.0.13",
        "Service-Time": str(now_ms),
        "Request-Id": uuid.uuid4().hex,
        "Business-Type": "1",
        "Device-Id": a.device_id or str(uuid.uuid4()).upper(),
        "Sys-Language": "zh-hans-cn",
        "Platform": "iOS",
        "Ninebot-Version": "2",
        "Platform-Ver": "27.0.1",
        "Accept-Language": "zh-Hans-CN;q=1.0",
        "Login-Country": "CN",
        "Access-Token": a.token,
        "Accept": "application/json",
        "Content-Type": "text/html",
        "App-Version": a.app_version,
        "Regionx": "bj",
    }
    return h


def decrypt_response(text, key):
    """响应可能是 {v,s,r} 信封，也可能已是明文"""
    try:
        j = json.loads(text)
    except Exception:
        return {"raw": text[:800]}
    if isinstance(j, dict) and "r" in j:
        try:
            plain = S.decrypt_d(j["r"].replace("\\/", "/"), key)
            return {"decrypted": json.loads(plain)}
        except Exception as e:
            return {"error": f"响应解密失败: {e}", "envelope_keys": list(j.keys())}
    return {"plain": j}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", required=True)
    ap.add_argument("--uid", required=True)
    ap.add_argument("--wnumber", required=True)
    ap.add_argument("--pn", default="", help="TFT 料号（可留空）")
    ap.add_argument("--part", default="TFT", help="部件类型，逗号分隔，默认 TFT")
    ap.add_argument("--version", default="0", help="上报的版本号，默认 0（必然低于线上）")
    ap.add_argument("--device-id", default="")
    ap.add_argument("--app-version", default="610093816")
    ap.add_argument("--app-ver-name", default="6.10.9")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    seed = a.seed if a.seed is not None else int.from_bytes(os.urandom(4), "big")
    key = S.derive_key(seed)
    plain = build_plain(a, seed)
    body = S.build_body(plain, seed)
    data = json.dumps(body, separators=(",", ":")).encode()

    print(f"# seed     = {seed}")
    print(f"# aesKey   = {key.decode()}")
    print(f"# 明文     = {plain.decode()}")
    print(f"# 密文长度 = {len(data)} B  (k={len(body['k'])}B64, d={len(body['d'])}B64)")
    hdrs = headers(a, int(time.time() * 1000))
    print("# 请求头   = " + ", ".join(f"{k}={v[:24]}" for k, v in hdrs.items()
                                   if k in ("Uid", "Service-Time", "Request-Id", "Access-Token")))

    if a.dry_run:
        print("\n[dry-run] 未发送。去掉 --dry-run 即真正请求。")
        return

    req = urllib.request.Request(URL, data=data, headers=hdrs, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            text = r.read().decode("utf-8", "replace")
            print(f"\nHTTP {r.status}  响应 {len(text)} B")
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
        print(f"\nHTTP {e.code}  响应 {len(text)} B")
    except Exception as e:
        print(f"\n请求失败: {e}")
        return

    print("\n--- 响应解密 ---")
    print(json.dumps(decrypt_response(text, key), ensure_ascii=False, indent=2)[:4000])


if __name__ == "__main__":
    main()
