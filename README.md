# termux-emacs

用 GNU Emacs 官方公开构建密钥（`assets/emacs.keystore`）重签 Termux 系 APK——
Termux 主程序与官方插件的 GitHub Release 构建，重签后可与 Android 原生 Emacs
（`org.gnu.emacs`）通过 `sharedUserId` 共享同一 Linux UID。

本仓库自 [UniEmacs](https://github.com/ShineBreaker/UniEmacs) 的 `docs/mobile/`
与签名流水线剥离而来：UniEmacs 侧只保留手机部署与使用指南，APK 的产出全部归本仓库。

## 为什么需要重签

termux 版 Emacs 与 Termux（及其插件）都在 manifest 里声明了
`android:sharedUserId="com.termux"`，Android 只给**同签名**的包分配同一 UID。
GNU Emacs 官方公开了自己的构建密钥（密码 `emacs1`），把 Termux 系 APK 用它重签一遍，
Emacs 就能执行 Termux 内的程序（git 等）。机制详见 [docs/mechanism.md](docs/mechanism.md)。

**插件与主程序必须同签名**：Termux:API / Boot / Float / Styling / Tasker / Widget
等也声明同一个 sharedUserId，只重签主程序不够——混签会直接报
`INSTALL_FAILED_SHARED_USER_INCOMPATIBLE`。这就是本仓库覆盖全部官方插件的原因。

## 覆盖范围（termux 官方 app 家族）

| 应用           | 包名             | 上游仓库             | 本仓库处理                                                         |
| -------------- | ---------------- | -------------------- | ------------------------------------------------------------------ |
| Termux（主程序）| `com.termux`     | termux/termux-app    | 自动重签（预览版，`apt-android-7` + `universal`）                  |
| Termux:API     | `com.termux.api` | termux/termux-api    | 自动重签                                                           |
| Termux:Boot    | `com.termux.boot`| termux/termux-boot   | 自动重签                                                           |
| Termux:Styling | `com.termux.styling` | termux/termux-styling | 自动重签                                                      |
| Termux:Tasker  | `com.termux.tasker` | termux/termux-tasker | 自动重签                                                       |
| Termux:Widget  | `com.termux.widget` | termux/termux-widget | 自动重签                                                       |
| Termux:GUI     | `com.termux.gui` | termux/termux-gui    | 自动重签（上游 2021 年停更，仅为完整性纳入）                       |
| Termux:Float   | `com.termux.float` | termux/termux-float | 不处理——本机维护 fork [termux-float-modern](https://github.com/ShineBreaker/termux-float-modern)，自构建自签名 |
| Termux:X11     | `com.termux.x11` | termux/termux-x11    | 不自动——release tag 固定为 `nightly`，无法按版本跳过；手动重签见 [docs/manual-resign.md](docs/manual-resign.md) |
| Termux:AM      | —                | termux/TermuxAm      | 已废弃（Android 10+ 失效），不处理                                 |

不建议使用的 `Termux:Float` / 已停更的 `Termux:GUI` 之外，其余插件装上后即可与
重签版 Termux 共享 UID 正常使用。上游资产的命名规律是
`<仓库名>-app_<tag>+github.debug.apk`（debug 构建，签名时需 `-debuggable-apk-permitted`）。

## 使用

### 下载安装（推荐）

到 [Releases](../../releases) 下载所需 APK。release tag 为 `<仓库>-<上游 tag>`
（如 `termux-api-v0.53.0`），各版本互不影响。

装机顺序（sharedUserId 的安装约束，不能乱）：

1. 备份并卸载手机上所有 Termux 系应用与 Emacs（卸载会清各自数据目录；
   混签名残留会导致安装失败）
2. 先装 Termux 主程序（本仓库重签版）
3. 再装需要的插件（本仓库重签版）
4. 最后装 termux 版 Emacs（<https://ftp.gnu.org/gnu/emacs/android/termux/>，
   如 `emacs-30.2-29-arm64-v8a.apk`）
5. 打开 Termux 执行 `pkg update && pkg upgrade`，之后 `pkg install git` 等即可在 Emacs 内使用

升级规则：重签版与官方渠道（F-Droid/Play/GitHub 官方）签名不同，**不能跨签名覆盖升级**；
升级用本仓库发布的新版本 APK 覆盖安装（同签名才能覆盖）。

### 本地重签

依赖：`curl`、`jq`、`java`（apksigner 会自动探测本机 Android SDK build-tools；
也可 `export APKSIGNER="java -jar /path/to/apksigner.jar"` 指定）：

```sh
just all               # 全部目标：抓上游最新版 + 重签，产物在 dist/
just only termux-api   # 只处理勾选的仓库
just status            # 查看各目标当前上游版本
just fetch termux-api  # 只抓取到 download/
just resign <apk>      # 重签任意 APK
```

本地遇到 GitHub API 403（匿名限流）时：`export GITHUB_TOKEN=$(gh auth token)` 后重试
（CI 已自动注入）。

### 自动更新

[.github/workflows/resign.yml](.github/workflows/resign.yml) 每周检查一次上游版本，
对每个有新版的目标：下载 → 按官方 checksums 校验 → 重签 → 断言证书指纹 → 发布 release；
已发布过的版本直接跳过（连下载都省）。也可在 Actions 页手动触发
_Resign Termux APKs_（可限定仓库、可 `force` 重建）。无需配置任何 Secrets。

## 目录结构

```
scripts/
├── fetch-termux-apk.sh    # 通用抓取：termux 官方 release APK + 官方 checksums 校验
├── resign-apk.sh          # Emacs 密钥重签 + 证书指纹断言（可对任意 APK 使用）
└── build-apks.sh          # 目标表 + 批量：探测 → 下载 → 重签 →（--publish）发布
assets/
└── emacs.keystore         # Emacs 官方公开构建密钥（PKCS12，密码 emacs1，无保密性）
docs/
├── mechanism.md           # sharedUserId 同签名机制
└── manual-resign.md       # 手动重签完整指南（含 x11 等未自动化的目标）
justfile                   # 本地命令包装
```

## 文档

- [docs/mechanism.md](docs/mechanism.md)——sharedUserId 同签名机制与两条获取路线
- [docs/manual-resign.md](docs/manual-resign.md)——手动重签完整指南（密钥获取、命令参数、指纹校验、安装顺序）
- UniEmacs 侧的手机部署与验证指南：<https://github.com/ShineBreaker/UniEmacs/blob/main/docs/mobile/README.md>
