#!/usr/bin/env python3
"""用 kxn/ninebot-recon 还原出的 wire 协议构造 iot_ota 请求"""
import argparse, base64, json, sys, time, uuid, urllib.request, ssl, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ninebot_crypto as C

URL = "https://steeldust.ninebot.com/iot_ota/ota/get-last-firmware"

def build_params(a, with_cc):
    biz = {}
    if a.with_common:
        biz.update({
            "sys_language": "zh-hans-cn",
            "client_ver": "610093816",
            "device_id": a.device_id,
            "regionx": "bj",
            "language": "zh",
            "ostype": "ios",
            "lang": "zh",
            "platform_ver": "27.0.1",
            "platform": "ios",
            "login_country": "CN",
        })
    biz.update({
        "uid": a.uid, "wnumber": a.wnumber, "env_type": "1",
        "download_type": "2",
        "parts": [{"part_type": a.part, "version": a.version}],
    })
    inner = C.build_inner(biz) if with_cc else C._go_json_dumps(biz)
    return inner.encode()

def headers(a, now_ms):
    return {
        "Content-Type": "text/html",
        "Access-Token": a.token,
        "Uid": a.uid, "MID": a.uid, "Device-Id": a.device_id,
        "Client-Ver": "610093816", "App-Version": "610093816",
        "Service-Time": str(now_ms), "Request-Id": uuid.uuid4().hex,
        "NET-Version": "1.0.13", "Platform": "iOS", "Platform-Ver": "27.0.1",
        "Ninebot-Version": "2", "Business-Type": "1", "Login-Country": "CN",
        "Need_decrypt": "1",
        "Regionx": "bj", "Language": "zh", "Sys-Language": "zh-hans-cn",
        "Accept": "application/json",
        "User-Agent": "Ninebot/6.10.9 (cn.ninebot.segway; build:3816; iOS 27.0.1) Alamofire/5.10.2",
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", required=True)
    ap.add_argument("--uid", required=True)
    ap.add_argument("--wnumber", required=True)
    ap.add_argument("--device-id", default="043EB569-DBE9-4965-ACB1-7513EB77818A")
    ap.add_argument("--part", default="TFT")
    ap.add_argument("--version", default="0")
    ap.add_argument("--no-checkcode", action="store_true")
    ap.add_argument("--with-common", action="store_true")
    ap.add_argument("--platform", type=int, default=2)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    inner = build_params(a, not a.no_checkcode)
    print("# 内层业务 JSON:", inner.decode()[:300])

    body, sec = C.build_request(inner, platform=a.platform)
    print(f"# wire 字段: {list(body.keys())}  d={len(body['d'])}B64  h={body['h'][:16]}...  k={len(body['k'])}B64")
    print(f"# secrets: kd1={sec['kd1']} kd2={sec['kd2']} kd3={sec['kd3']} kd4={sec['kd4']}")
    data = json.dumps(body, separators=(",", ":")).encode()

    if a.dry_run:
        print("\n[dry-run] 未发送"); return

    # 用系统 curl（避免 Python 缺根证书）
    import subprocess, tempfile
    with tempfile.TemporaryDirectory() as td:
        bf = os.path.join(td, "body.json")
        open(bf, "wb").write(data)
        cmd = ["curl", "-sS", "-m", "25", "-o", os.path.join(td, "resp.txt"),
               "-w", "%{http_code}", "-X", "POST", URL, "--data-binary", "@" + bf]
        for k, v in headers(a, int(time.time()*1000)).items():
            cmd += ["-H", f"{k}: {v}"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print("curl 失败:", r.stderr[:300]); return
        try:
            status = int(r.stdout.strip())
        except ValueError:
            status = -1
        text = open(os.path.join(td, "resp.txt"), encoding="utf-8", errors="replace").read()
    print(f"\nHTTP {status}  {len(text)}B")
    print("响应原文(前200):", text[:200])

    try:
        w = json.loads(text)
        if "r" in w:
            plain = C.decrypt_wire_response(w, sec)
            print("\n--- 解密成功 ---")
            try:
                biz = C.unwrap_response(plain)
                print("业务 JSON:")
                print(json.dumps(json.loads(biz), ensure_ascii=False, indent=2)[:3000])
            except Exception:
                print("wrapper 明文:", plain[:800].decode("utf-8","replace"))
        else:
            print("\n响应无 r 字段:", list(w.keys()) if isinstance(w, dict) else type(w))
    except Exception as e:
        print("解密失败:", e)

if __name__ == "__main__":
    main()
