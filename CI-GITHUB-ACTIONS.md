# 用 GitHub Actions 编译 dylib

本机没有 Xcode/iOS SDK，但 **GitHub Actions 的 `macos-14` runner 自带 Xcode 与 iPhoneOS SDK**，
正好补上缺失的工具链，产出真正的 iOS arm64 dylib。

## 1. 仓库该放什么

只要这四样（其余都是本地大文件，已被 `.gitignore` 排除）：

```
.github/workflows/build-dylib.yml
tweak-theos/            # Theos(Logos) 工程
tweak/                  # 纯 ObjC 版（兜底）
.gitignore
```

> ⚠️ 不要提交 `ipa_extract/`（205 MB 二进制）、`ghidra_proj/`（3.3 GB 工程）、`analysis/`——`.gitignore` 已排除。

## 2. 推送并触发

```bash
git init && git add .github tweak-theos tweak .gitignore CI-GITHUB-ACTIONS.md
git commit -m "ProjectionOverride: Theos/Logos dylib + CI"
git branch -M main
git remote add origin git@github.com:<you>/<repo>.git
git push -u origin main
```
推送后自动触发（也可在 Actions 页点 *Run workflow* 手动跑）。

## 3. 两个 job

| job | 说明 | 产物 |
|---|---|---|
| `build-logos` | 拉取 Theos（`--recursive`，含 logos 子模块）→ `make` | `ProjectionOverride-logos`（Logos 版 dylib） |
| `build-plain` | 不走 Theos，直接 `xcrun --sdk iphoneos clang` 编 `tweak/ProjectionOverride.m` | `ProjectionOverride-plain` |

两条路互为兜底：Theos 侧若因版本变动出问题，plain 版仍能出包。

## 4. CI 内的自动校验（会拦下坏产物）

`build-logos` 编译后强制检查，任一不满足即 fail：

1. `file` 必须是 **arm64**；
2. `nm -gU` 必须**定义** `_MSHookMessageEx`；
3. `nm -u` 不得出现 substrate 残留 → 否则侧载必崩；
4. 打印 `otool -D` 确认 `install_name` 为 `@executable_path/ProjectionOverride.dylib`。

这三条正是"免越狱能不能用"的判据，比"编译成功"更有意义。

## 5. 拿到产物

Actions → 选这次 run → 页面底部 **Artifacts** → 下载 zip → 解压得到 `ProjectionOverride.dylib`
→ 按 `tweak-theos/README.md` 第 5 节注入并重签。

## 6. 成本与注意

- 公开仓库的 Actions 免费；私有仓库会消耗 macOS 分钟数（10× 倍率），一次构建约 2–4 分钟。
- 不需要任何 Secret：构建不做签名。**签名在注入/侧载时由你的证书完成**（dylib 与主程序必须同证书）。
- 缓存了 `$THEOS` 目录加速；缓存损坏时会自动重新克隆（`Setup Theos` 步骤内置自愈）。
- 首次运行建议先确认 `Show toolchain` 步骤输出的 `xcrun --sdk iphoneos --show-sdk-path` 非空。
