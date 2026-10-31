#!/usr/bin/env python3
"""按真实明文结构构造 iot_ota 请求（含 access_token/nonce/checkcode），触发固件更新查询"""
import argparse, hashlib, json, os, secrets, subprocess, sys, tempfile, time, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ninebot_crypto as C

URL = "https://steeldust.ninebot.com/iot_ota/ota/get-last-firmware"
COMMON = ["sys_language","client_ver","device_id","regionx","language","ostype","lang",
          "platform_ver","platform","login_country"]

def build_params(a, ver_field):
    parts = [{"part_type": t} for t in a.parts]
    # 只给目标部件加 version（可选 pn）
    for p in parts:
        if p["part_type"] == a.part:
            p["version"] = a.version
            if a.pn: p["pn"] = a.pn
    p = {"uid": a.uid, "wnumber": a.wnumber, "env_type": "1",
         "download_type": "2", "parts": parts, "download": a.download,
         "access_token": a.token,
         "sys_language": "zh-hans-cn", "client_ver": a.client_ver,
         "device_id": a.device_id, "regionx": "bj", "language": "zh",
         "ostype": a.ostype, "lang": "zh", "platform_ver": a.platform_ver,
         "platform": a.platform, "login_country": "CN",
         "serviceTime": int(time.time() * 1000),
         "nonce": secrets.token_hex(16)[:2].lower() + secrets.token_hex(16)[2:].upper()}
    no_cc = json.dumps(p, separators=(",", ":"), ensure_ascii=False)
    p["checkcode"] = hashlib.md5(no_cc.encode()).hexdigest().upper()
    return p

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", required=True)
    ap.add_argument("--uid", required=True)
    ap.add_argument("--wnumber", required=True)
    ap.add_argument("--part", default="TFT")
    ap.add_argument("--version", default="0")
    ap.add_argument("--pn", default="")
    ap.add_argument("--download", default="1", help="1=请求下载链接")
    ap.add_argument("--parts", default="MCU,BFG,ABS-F,ABS-R,CHG,HEP,LIGHT,ECU,BMS1,BMS2,BMS3,DIS,TFT,BMS-BLE1,BMS-BLE2,BMS-BLE3,BLE,FL-APL")
    ap.add_argument("--client-ver", default="610124167")
    ap.add_argument("--device-id", default="10802948c22c659225d5b56a092b42a8")
    ap.add_argument("--ostype", default="and")
    ap.add_argument("--platform", default="android")
    ap.add_argument("--platform-ver", default="14 Google_Pixel 5")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    a.parts = [x.strip() for x in a.parts.split(",") if x.strip()]

    params = build_params(a, True)
    inner = json.dumps(params, separators=(",", ":"), ensure_ascii=False)
    print("# 内层明文（含 checkcode）:")
    print(inner[:600])
    print(f"# checkcode = {params['checkcode']}")

    body, sec = C.build_request(inner.encode(), platform=2)
    data = json.dumps(body, separators=(",", ":")).encode()

    h = {"Content-Type": "text/html;charset=UTF-8", "Access_token": a.token,
         "Uid": a.uid, "MID": a.uid, "Device-Id": a.device_id,
         "Client-Ver": a.client_ver, "App-Version": a.client_ver,
         "Service-Time": str(int(time.time()*1000)), "Request-Id": uuid.uuid4().hex,
         "NET-Version": "1.0.13", "Platform": a.platform, "Platform-Ver": a.platform_ver,
         "Ninebot-Version": "2", "Business-Type": "0", "Login-Country": "CN",
         "Regionx": "bj", "Language": "zh", "Sys-Language": "zh-hans-cn",
         "Accept": "application/json", "Need_decrypt": "1", "Debug": "0",
         "User-Agent": "okhttp/4.9.1"}
    if a.dry_run:
        print("\n[dry-run] 未发送")
        return

    with tempfile.TemporaryDirectory() as td:
        bf, of = os.path.join(td, "b"), os.path.join(td, "o")
        open(bf, "wb").write(data)
        cmd = ["curl", "-sS", "-m", "25", "-o", of, "-w", "%{http_code}", "-X", "POST", URL, "--data-binary", "@"+bf]
        for k, v in h.items(): cmd += ["-H", f"{k}: {v}"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        txt = open(of, encoding="utf-8", errors="replace").read() if os.path.exists(of) else ""
    print(f"\nHTTP {r.stdout.strip()}  {len(txt)}B")
    try:
        biz = json.loads(C.decrypt_wire_response(json.loads(txt), sec).decode())
        print(f"code={biz.get('code')} desc={biz.get('desc')}")
        print(json.dumps(biz.get("data"), ensure_ascii=False, indent=2)[:3000] if biz.get("data") else "data=null")
    except Exception as e:
        print("解密失败:", e, "|", txt[:150])

if __name__ == "__main__":
    main()
