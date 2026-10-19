# 手动重签指南

> 整理自 johanwiden/termux-for-android-emacs README（实测记录）与移动端配置期的参考笔记。
> 原理见 [mechanism.md](mechanism.md)。
> 本仓库的批量脚本（`scripts/build-apks.sh`）与 CI 已覆盖主程序与常规插件，
> 手动流程适用于：未纳入自动化的目标（如 Termux:X11）、想固定某个版本、或没有 clone 仓库时。

## 0. 前置工具

只需 `apksigner`（Android SDK build-tools 组件）：

```sh
# Termux 内
pkg install apksigner

# 桌面 Linux：安装 Android SDK cmdline-tools 后
sdkmanager --install "build-tools;34.0.0"
# 之后使用 $ANDROID_HOME/build-tools/34.0.0/apksigner
```

> 反编译重建（apktool）与 zipalign 步骤已不再需要：直接对官方 APK 重签即可。

## 1. 获取密钥

从 Emacs 源码树下载（或直接用本仓库的 [assets/emacs.keystore](../assets/emacs.keystore)）：

```sh
curl -fLO https://raw.githubusercontent.com/emacs-mirror/emacs/master/java/emacs.keystore
```

密钥库密码 `emacs1`（公开信息）。证书 SHA-256 指纹应为：

```
50b47e8f09b8781fccc998df3fc5c02de0dd9670a3d37e6cacba9f4e76319604
```

## 2. 下载上游 APK

**渠道 A：GitHub 官方 Release（本仓库自动化的来源）**

主程序 [termux/termux-app releases](https://github.com/termux/termux-app/releases)：
资产命名 `termux-app_<tag>+<flavor>-<buildtype>_<abi>.apk`

| 字段      | 取值                                                         | 选择建议                                                                              |
| --------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| flavor    | `apt-android-7` / `apt-android-5`                            | 现代设备一律 `apt-android-7`（Android 7+）；`apt-android-5` 仅用于 Android 5/6 老设备 |
| buildtype | `github-debug`（目前 GitHub Release 仅提供此构建）           | 无需选择                                                                              |
| abi       | `universal` / `arm64-v8a` / `armeabi-v7a` / `x86_64` / `x86` | `universal` 全设备通用；ABI 与设备不符会导致子进程执行失败                            |

各插件仓库（termux-api / boot / styling / tasker / widget / gui）的 Release 同样带 APK，
命名 `<仓库名>-app_<tag>+github.debug.apk`，另附 `checksums-sha256.txt` 可校验。

**渠道 B：F-Droid**（<https://f-droid.org/en/packages/com.termux/> 等，稳定版）

johanwiden 实测记录：F-Droid 版 `0.119.0-beta.3 (1022)`（2025-05-29 上架）重签后在
Android 15 的 OnePlus Open 与 Samsung Tab S8+ 上可用。

**Termux:X11**（已纳入自动化）：上游 release 只有一个 `nightly` tag，内容随时更新，
因此用资产 digest 前 12 位做版本键（release tag 形如 `termux-x11-cd72ac672bc5`），
内容不变则自动跳过。要重签的是 **`termux-x11-universal-sharedUid-debug.apk`**——
只有它声明了 `sharedUserId="com.termux"`；另一个 `termux-x11-universal-debug.apk`
不共享 UID，重签它没有意义。该 release 没有 checksums 资产，脚本用 GitHub API 的
digest 字段兜底校验。

## 3. 重签

```sh
apksigner sign --v2-signing-enabled --v4-signing-enabled false \
  --ks emacs.keystore -debuggable-apk-permitted \
  --ks-pass pass:emacs1 \
  --out termux-api-emacs-signed.apk \
  termux-api-app_v0.53.0+github.debug.apk
```

参数说明（与 Emacs 源码 `java/Makefile.in` 的 `SIGN_EMACS_V2` 一致，另显式禁用 v4
签名以避免多余的 `.idsig` 文件）：

- `--v2-signing-enabled`：启用 APK Signature Scheme v2（Android 7.0+）
- `--v4-signing-enabled false`：v4 签名只为 adb 增量安装服务，侧载用不到
- `-debuggable-apk-permitted`：允许给 debuggable APK 签名。GitHub 构建是 `github-debug`
  变体（manifest 带 `android:debuggable`），必须带此参数
- `--ks-pass pass:emacs1`：Emacs 公开密钥库的密码

批量与自动化：仓库内 `just all` 等价于「抓上游最新版 → 官方 checksums 校验 → 重签」，
或直接用 `scripts/resign-apk.sh <apk>` 重签手头任意 APK（含 Termux:X11 与 Termux:Float
fork 的产物，如需）。

## 4. 验证签名

```sh
apksigner verify --print-certs <重签后的 APK>
```

输出的 `Signer #1 certificate SHA-256 digest` 必须等于第 1 步的指纹
（仓库脚本会自动断言这一指纹，不符即失败）。

## 5. 安装顺序与升级规则

**首次安装 / 从官方签名版切换**（sharedUserId 的安装顺序约束，顺序不能反）：

1. 备份并卸载手机上**所有** Termux 系应用（主程序与插件，卸载会清各自数据目录；
   残留任一同 UID 包都会导致后续安装失败）与 Emacs
2. **先**安装重签版 Termux 主程序 APK
3. **再**安装需要的重签版插件（Termux:API、Termux:Widget 等）
4. **最后**安装 termux 版 Emacs APK（<https://ftp.gnu.org/gnu/emacs/android/termux/>，
   文件名规则 `emacs-<版本>-<最低AndroidAPI>-<ABI>.apk`，如 `emacs-30.2-29-arm64-v8a.apk`）
5. 打开 Termux 执行 `pkg update && pkg upgrade`，之后 `pkg install git` 等即可在 Emacs 内使用

**升级规则**：

- 重签版与官方签名不同，**无法从 Termux 官方渠道（F-Droid/Play）覆盖升级**，升级时用
  新版本 APK 重签后覆盖安装（同签名可覆盖；插件同理）
- termux 版 Emacs 与 GNU 独立版 Emacs（非 termux 目录的 APK）**不能共存**，切换需先卸载
- 权限：设置 → 特殊应用访问 → 所有文件访问 → 授予 Emacs，此后 `/storage/emulated/0/`
  （= `/sdcard/`）可直读直写

## 6. 装机验证清单（在 Emacs 里执行）

```elisp
(eq system-type 'android)        ; => t
(window-system)                  ; => android
(executable-find "git")          ; => 非 nil，说明 Termux 协作生效
(native-comp-available-p)        ; 预计 nil，Android 版不依赖 .eln
(executable-find "sqlite3")      ; org-roam 依赖（CLI 后端）
```

更完整的手机侧部署、验证与排查清单见 UniEmacs 的
[docs/mobile/README.md](https://github.com/ShineBreaker/UniEmacs/blob/main/docs/mobile/README.md)。

## 7. 故障排查

| 现象                                                             | 原因与处理                                                                                                        |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| 装机报 `INSTALL_FAILED_SHARED_USER_INCOMPATIBLE`                 | 设备上还有包占用 `com.termux` 共享用户且签名不同（最常见是 Termux 插件残留）。把 Termux 系应用全部卸载（必要时重启手机），再按 §5 顺序安装 |
| 抓取报 403 / “release 列表获取失败”                              | GitHub API 匿名限流。`export GITHUB_TOKEN=$(gh auth token)` 后重试；CI 已自动传入                                  |
| 报“没有预览版”                                                   | 上游最近 30 个 release 全无 prerelease 标记（主程序目标只认预览版，见 `scripts/build-apks.sh` 目标表）              |
| 报“没有匹配……的资产”                                             | 上游资产命名规则变化，或目标表里的正则需要收窄                                                                     |
| 定时任务没跑                                                     | 仓库超过 60 天无活动时 GitHub 会暂停 scheduled workflow，到 Actions 页重新启用即可                                 |
