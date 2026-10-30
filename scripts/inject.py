#!/usr/bin/env python3
"""注入 dylib + 改 bundle id。
用法: inject.py <Payload/Ninebot.app> <Frameworks/xxx.dylib 相对路径> <新 BundleID>
"""
import sys, pathlib, plistlib
import lief

app = pathlib.Path(sys.argv[1])
dylib_rel = sys.argv[2]
new_bid = sys.argv[3]

bin_path = app / "Ninebot"
print(f"[inject] binary = {bin_path}  size = {bin_path.stat().st_size:,}")

b = lief.parse(str(bin_path))
if b is None:
    sys.exit("LIEF 解析失败")

before = len(b.libraries)
b.add_library('@executable_path/' + dylib_rel)
print(f"[inject] LC_LOAD_DYLIB: {before} -> {len(b.libraries)}")

out = pathlib.Path(str(bin_path) + ".new")
b.write(str(out))
out.replace(bin_path)
print("[inject] 写入完成")

p = app / "Info.plist"
d = plistlib.load(open(p, "rb"))
old = d.get("CFBundleIdentifier")
d["CFBundleIdentifier"] = new_bid
plistlib.dump(d, open(p, "wb"))
print(f"[inject] CFBundleIdentifier: {old} -> {new_bid}")
