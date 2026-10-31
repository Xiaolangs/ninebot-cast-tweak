#!/usr/bin/env python3
"""主题/皮肤接口通用探针：任意 host+path+params，加密发送并解密响应"""
import argparse, hashlib, json, secrets, subprocess, sys, tempfile, time, os, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ninebot_crypto as C

DEFAULT_HOST = "cn-cbu-gateway.ninebot.com"

def build(common, extra):
    p = dict(common); p.update(extra)
    no_cc = json.dumps(p, separators=(",", ":"), ensure_ascii=False)
    p["checkcode"] = hashlib.md5(no_cc.encode()).hexdigest().upper()
    return json.dumps(p, separators=(",", ":"), ensure_ascii=False)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", required=True)
    ap.add_argument("--uid", required=True)
    ap.add_argument("--wnumber", default="")
    ap.add_argument("--path", required=True)
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--params", default="{}", help='JSON 额外参数')
    ap.add_argument("--business-type", default="0")
    ap.add_argument("--platform", default="android")
    a = ap.parse_args()

    did = secrets.token_hex(16)
    common = {"uid": a.uid, "wnumber": a.wnumber, "access_token": a.token,
              "sys_language": "zh-hans-cn", "client_ver": "610124167", "device_id": did,
              "regionx": "bj", "language": "zh", "ostype": "and", "lang": "zh",
              "platform_ver": "14 Google_Pixel 5", "platform": a.platform,
              "login_country": "CN", "serviceTime": int(time.time() * 1000),
              "nonce": secrets.token_hex(16)[:2].lower() + secrets.token_hex(16)[2:].upper()}
    inner = build(common, json.loads(a.params))
    body, sec = C.build_request(inner.encode(), platform=2)
    data = json.dumps(body, separators=(",", ":")).encode()

    h = {"Content-Type": "text/html;charset=UTF-8", "Access_token": a.token,
         "Uid": a.uid, "MID": a.uid, "Device-Id": did, "Client-Ver": "610124167",
         "App-Version": "610124167", "Service-Time": str(int(time.time()*1000)),
         "Request-Id": uuid.uuid4().hex, "NET-Version": "1.0.13", "Platform": a.platform,
         "Platform-Ver": "14 Google_Pixel 5", "Ninebot-Version": "2",
         "Business-Type": a.business_type, "Login-Country": "CN", "Regionx": "bj",
         "Language": "zh", "Sys-Language": "zh-hans-cn", "Accept": "application/json",
         "Need_decrypt": "1", "Debug": "0", "User-Agent": "okhttp/4.9.1"}
    with tempfile.TemporaryDirectory() as td:
        bf, of = os.path.join(td, "b"), os.path.join(td, "o")
        open(bf, "wb").write(data)
        cmd = ["curl", "-sS", "-m", "20", "-o", of, "-w", "%{http_code}", "-X", "POST",
               f"https://{a.host}{a.path}", "--data-binary", "@" + bf]
        for k, v in h.items(): cmd += ["-H", f"{k}: {v}"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        txt = open(of, encoding="utf-8", errors="replace").read() if os.path.exists(of) else ""
    print(f"HTTP {r.stdout.strip()}  {len(txt)}B")
    try:
        biz = json.loads(C.decrypt_wire_response(json.loads(txt), sec).decode())
        print("code =", biz.get("code"), "| desc =", biz.get("desc"))
        print(json.dumps(biz.get("data"), ensure_ascii=False, indent=2)[:4000])
    except Exception as e:
        print("未加密响应 / 解密失败:", e)
        print(txt[:400])

if __name__ == "__main__":
    main()
