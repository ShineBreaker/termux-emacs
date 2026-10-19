# termux-emacs：为 Android 原生 Emacs（org.gnu.emacs）重签 Termux 系 APK。
# 日常使用直接到 Releases 下载 *-emacs-signed.apk，无需在本地执行以下命令。
# 目标表与机制见 README.md 与 docs/。

default:
    @just --list

# ═══ 批量 ═══

# 全部目标：抓取上游最新版 + 重签，产物在 dist/
all:
    scripts/build-apks.sh

# 只处理指定仓库（逗号分隔，如 termux-api,termux-widget）
only repos:
    scripts/build-apks.sh --only {{repos}}

# 探测各目标当前上游版本与版本键，不下载不重签
status:
    scripts/build-apks.sh --status

# ═══ 单个 ═══

# 抓取单个目标的最新 APK 到 download/（如 just fetch termux-api）
fetch repo:
    scripts/fetch-termux-apk.sh -r {{repo}} -o download

# 重签单个 APK（默认用仓库内密钥；产物加 -emacs-signed 后缀）
resign apk:
    scripts/resign-apk.sh {{apk}}

# ═══ 维护 ═══

# 清理下载与产物目录
clean:
    rm -rf download dist
