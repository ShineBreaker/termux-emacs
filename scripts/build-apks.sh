#!/usr/bin/env bash
# 批量重签 termux 系 APK：遍历目标表（主程序 + 官方插件），逐个
#   探测上游最新版本 → 下载并按官方 checksums 校验 → 用 Emacs 官方公开密钥重签。
# 加 --publish 时把产物发布为本仓库的 GitHub Release（该版本已发布则直接跳过，连下载都省）。
#
# 用法:
#   build-apks.sh [--publish] [--force] [--only <仓库,...>] [--download <目录>] [--out <目录>]
#
# 选项:
#   --publish   发布为本仓库 release（需已认证 gh；默认只产出到 --out 目录）
#   --force     publish 时目标 release 已存在也删除重建
#   --only      只处理指定仓库（逗号分隔，如 termux-api,termux-widget）
#   --download  APK 下载目录（默认 download）
#   --out       重签产物目录（默认 dist）
#
# 依赖: curl、jq，以及 java + apksigner（自动探测本机 Android SDK build-tools；
#       也可 export APKSIGNER="java -jar /path/to/apksigner.jar" 指定）
#
# 目标表里的仓库名即本仓库 release tag 前缀：<仓库>-<上游 tag>，如 termux-api-v0.53.0
set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# 目标表：<仓库>|<资产名正则>|<额外 fetch 参数>|<版本键模式>
# 版本键模式 use-digest：上游 tag 恒定（nightly）时用资产 digest 前 12 位做版本键，
# 否则用上游 tag。release tag = <仓库>-<版本键>。
# - termux-float 不在表内：本机维护 fork（ShineBreaker/termux-float-modern），自构建自签名
TARGETS=(
  'termux-app|^termux-app_.+\+apt-android-7-.+_universal\.apk$|-P|tag'
  'termux-api|\.apk$||tag'
  'termux-boot|\.apk$||tag'
  'termux-styling|\.apk$||tag'
  'termux-tasker|\.apk$||tag'
  'termux-widget|\.apk$||tag'
  'termux-gui|\.apk$||tag'
  # sharedUid 变体已声明 sharedUserId="com.termux"，正是要重签的那个
  'termux-x11|universal-sharedUid.*\.apk$||digest'
)

PUBLISH=0
FORCE=0
ONLY=""
STATUS=0
DOWNLOAD=download
OUT_DIR=dist

while [[ $# -gt 0 ]]; do
  case $1 in
    --publish) PUBLISH=1 ;;
    --force) FORCE=1 ;;
    --status) STATUS=1 ;;
    --only) ONLY=$2; shift ;;
    --download) DOWNLOAD=$2; shift ;;
    --out) OUT_DIR=$2; shift ;;
    -h | --help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知选项: $1（-h 查看用法）" ;;
  esac
  shift
done

cd "$REPO_ROOT"

if [[ $STATUS -eq 1 ]]; then
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r repo asset_pattern extra key_mode <<<"$entry"
    probe=$(scripts/fetch-termux-apk.sh -r "$repo" -p "$asset_pattern" $extra -c 2>/dev/null)
    tag=$(sed -n 's/^tag=//p' <<<"$probe")
    digest=$(sed -n 's/^digest=//p' <<<"$probe")
    if [[ $key_mode == digest ]]; then ver=${digest:0:12}; else ver=$tag; fi
    printf '%-16s %-20s %s\n' "$repo" "$tag" "${ver:-(解析失败)}"
  done
  exit 0
fi

if [[ $PUBLISH -eq 1 ]]; then
  command -v gh >/dev/null || die "需要 gh（GitHub CLI）才能发布 release"
  gh auth status >/dev/null 2>&1 || die "gh 未认证，先运行 gh auth login"
fi

# apksigner 探测：APKSIGNER 环境变量 > 本机 Android SDK build-tools（取最高版本）
APKSIGNER_CMD=${APKSIGNER:-}
if [[ -z $APKSIGNER_CMD ]]; then
  for base in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" "$HOME/Programs/Android/SDK"; do
    [[ -n $base ]] || continue
    jar=$(ls -d "$base"/build-tools/*/lib/apksigner.jar 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n $jar ]]; then
      APKSIGNER_CMD="java -jar $jar"
      echo "==> 使用 apksigner: $jar"
      break
    fi
  done
fi
[[ -n $APKSIGNER_CMD ]] ||
  die "未找到 apksigner：安装 Android SDK build-tools，或 export APKSIGNER=\"java -jar <apksigner.jar 路径>\""

mkdir -p "$DOWNLOAD" "$OUT_DIR"

# 发布产物为本仓库 release；tag 形如 <仓库>-<上游 tag>
publish_release() {
  local repo=$1 tag=$2 apk=$3 upstream_asset=$4 rel_tag=$5
  if gh release view "$rel_tag" >/dev/null 2>&1; then
    if [[ $FORCE -eq 1 ]]; then
      echo "==> release $rel_tag 已存在，--force：删除重建"
      gh release delete "$rel_tag" --yes --cleanup-tag
    else
      echo "==> release $rel_tag 已存在，跳过发布"
      return 0
    fi
  fi
  local notes
  notes=$(mktemp)
  {
    echo "用 GNU Emacs 官方公开构建密钥重签的 $repo APK，供 Android 原生 Emacs（\`org.gnu.emacs\`）共享 UID 使用。"
    echo
    echo "- 上游版本：[$repo $tag](https://github.com/termux/$repo/releases/tag/$tag)"
    echo "- 原始资产：\`$upstream_asset\`（已按官方 checksums 校验）"
    echo "- 签名密钥：Emacs 官方 \`emacs.keystore\`，证书 SHA-256 指纹 \`50b47e8f09b8781fccc998df3fc5c02de0dd9670a3d37e6cacba9f4e76319604\`"
    echo
    echo "**安装提醒**：重签版与官方渠道签名不同，无法跨签名覆盖安装；升级请用本仓库发布的新版本。装机顺序（先 Termux 后 Emacs）与卸载注意事项见仓库 README。"
  } >"$notes"
  gh release create "$rel_tag" "$apk" \
    --title "$repo $tag (resigned for Emacs)" \
    --notes-file "$notes"
  rm -f "$notes"
}

failures=0
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r repo asset_pattern extra key_mode <<<"$entry"

  if [[ -n $ONLY ]]; then
    case ",$ONLY," in
      *",$repo,"*) ;;
      *) continue ;;
    esac
  fi

  echo
  echo "═══ [$repo] ═══"

  # 探测上游最新版本（只解析，不下载）
  probe=$(scripts/fetch-termux-apk.sh -r "$repo" -p "$asset_pattern" $extra -o "$DOWNLOAD" -c)
  tag=$(sed -n 's/^tag=//p' <<<"$probe")
  asset=$(sed -n 's/^asset=//p' <<<"$probe")
  digest=$(sed -n 's/^digest=//p' <<<"$probe")

  # 版本键：固定 tag 的上游（nightly）用内容 digest，否则用 tag
  if [[ $key_mode == digest ]]; then
    [[ -n $digest ]] || die "$repo 需要 digest 做版本键，但上游 API 未返回 digest"
    ver=${digest:0:12}
  else
    ver=$tag
  fi
  rel_tag="${repo}-${ver}"

  # publish 且未 --force：该版本已发布则跳过（连下载都省）
  if [[ $PUBLISH -eq 1 && $FORCE -eq 0 ]] && gh release view "$rel_tag" >/dev/null 2>&1; then
    echo "==> $rel_tag 已发布，跳过"
    continue
  fi

  # 下载并校验；单个目标失败不中断其余目标
  if ! fetched=$(scripts/fetch-termux-apk.sh -r "$repo" -p "$asset_pattern" $extra -o "$DOWNLOAD"); then
    echo "==> [$repo] 抓取失败，继续下一目标" >&2
    failures=$((failures + 1))
    continue
  fi
  apk=$(sed -n 's/^apk=//p' <<<"$fetched")

  # 重签；产物名 = 上游 APK 名 + -emacs-signed 后缀
  out_apk="$OUT_DIR/$(basename "${apk%.apk}")-emacs-signed.apk"
  if ! APKSIGNER="$APKSIGNER_CMD" scripts/resign-apk.sh "$apk" -o "$out_apk"; then
    echo "==> [$repo] 重签失败，继续下一目标" >&2
    failures=$((failures + 1))
    continue
  fi

  # 发布
  if [[ $PUBLISH -eq 1 ]]; then
    publish_release "$repo" "$tag" "$out_apk" "$asset" "$rel_tag"
  fi
done

echo
if [[ $failures -gt 0 ]]; then
  die "$failures 个目标失败，其余见上"
fi
echo "==> 全部完成，产物在 $OUT_DIR/"
