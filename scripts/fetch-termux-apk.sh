#!/usr/bin/env bash
# 从 termux 官方仓库的 GitHub Release 抓取 APK，并按官方 checksums 校验 sha256。
#
# 用法:
#   fetch-termux-apk.sh -r <仓库> [-t <tag>] [-p <资产正则>] [-P] [-o <目录>] [-c]
#
# 选项:
#   -r  GitHub 仓库：短名（如 termux-api，默认属主 termux）或全名（owner/repo）
#   -t  指定上游 tag（如 v0.53.0）；缺省取最新 release
#   -p  APK 资产名正则（默认 '\.apk$'）；release 内须恰好匹配一个资产
#   -P  只认预览版（prerelease）；termux-app 主程序用
#   -o  下载目录（默认 download）
#   -c  check-only：只解析 tag/资产名并输出，不下载
#
# 输出（同时写入 $GITHUB_OUTPUT 供 workflow 使用）:
#   tag=<上游 tag>
#   asset=<上游资产名>
#   apk=<下载后的 APK 路径>（-c 模式不输出）
set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

write_output() { echo "$1=$2"; [[ -n ${GITHUB_OUTPUT:-} ]] && echo "$1=$2" >>"$GITHUB_OUTPUT" || true; }

# 仅允许 https + GitHub 官方域，拒绝其余 host
validate_url() {
  case "$1" in
    https://api.github.com/* | https://github.com/* | https://objects.githubusercontent.com/*) ;;
    *) die "拒绝访问白名单之外的 URL: $1" ;;
  esac
}

REPO=""
OUT_DIR=download
ASSET_PATTERN='\.apk$'
TAG_OPT=""
PRERELEASE_ONLY=0
CHECK_ONLY=0

while getopts ":r:o:t:p:Pch" opt; do
  case $opt in
    r) REPO=$OPTARG ;;
    o) OUT_DIR=$OPTARG ;;
    t) TAG_OPT=$OPTARG ;;
    p) ASSET_PATTERN=$OPTARG ;;
    P) PRERELEASE_ONLY=1 ;;
    c) CHECK_ONLY=1 ;;
    h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知选项，运行 $0 -h 查看用法" ;;
  esac
done

[[ -n $REPO ]] || die "缺少 -r <仓库>"
[[ $REPO == */* ]] || REPO="termux/$REPO"
command -v curl >/dev/null || die "需要 curl"
command -v jq >/dev/null || die "需要 jq"

API="https://api.github.com/repos/$REPO/releases?per_page=30"
validate_url "$API"

CURL_ARGS=(-fsSL --retry 5 --retry-all-errors --retry-delay 2 --max-time 300)
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  CURL_ARGS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

releases_json=$(curl "${CURL_ARGS[@]}" "$API") || die "获取 $REPO 的 release 列表失败"
[[ -n $releases_json ]] || die "release 列表为空"

if [[ -n $TAG_OPT ]]; then
  release_json=$(jq --arg t "$TAG_OPT" '.[] | select(.tag_name == $t)' <<<"$releases_json")
  [[ -n $release_json ]] || die "$REPO 不存在 tag 为 $TAG_OPT 的 release"
elif [[ $PRERELEASE_ONLY -eq 1 ]]; then
  release_json=$(jq '[.[] | select(.prerelease)][0]' <<<"$releases_json")
  [[ $release_json != null ]] || die "$REPO 最近 30 个 release 中没有预览版"
else
  release_json=$(jq '.[0]' <<<"$releases_json")
  [[ $release_json != null ]] || die "$REPO 没有 release"
fi

TAG=$(jq -r '.tag_name' <<<"$release_json")

# 资产匹配：要求恰好一个；多个时报错列出候选，避免过宽的正则选错包
mapfile -t matches < <(jq -r --arg p "$ASSET_PATTERN" '.assets[] | select(.name | test($p)) | .name' <<<"$release_json")
[[ ${#matches[@]} -ge 1 ]] || die "release $TAG 中没有匹配正则 “$ASSET_PATTERN” 的资产"
if [[ ${#matches[@]} -gt 1 ]]; then
  printf '%s\n' "${matches[@]}" >&2
  die "正则 “$ASSET_PATTERN” 在 release $TAG 中匹配到多个资产（见上），请收窄"
fi
ASSET=${matches[0]}
APK_URL=$(jq -r --arg n "$ASSET" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$release_json")

# 资产内容摘要（GitHub API 的 digest 字段）；固定 tag 的上游（nightly）用它做版本键
asset_digest() {
  jq -r --arg n "$ASSET" '.assets[] | select(.name == $n) | .digest // ""' <<<"$release_json" |
    sed 's/^sha256://'
}

if [[ $CHECK_ONLY -eq 1 ]]; then
  write_output tag "$TAG"
  write_output asset "$ASSET"
  write_output digest "$(asset_digest)"
  echo "check-only：$REPO $TAG（$ASSET），未下载" >&2
  exit 0
fi

mkdir -p "$OUT_DIR"
APK_PATH=$(cd "$OUT_DIR" && pwd)/$ASSET

# 官方 checksums 校验：候选为 release 中所有 *_sha256sums / sha256sums /
# checksums-sha256.txt 资产（主程序按 flavor 各一个、插件共用一个）；
# 逐个下载并在其中查找 APK 资产名对应的 sha256 条目
expected=""
while IFS= read -r sums; do
  [[ -n $sums ]] || continue
  sums_url=$(jq -r --arg n "$sums" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$release_json")
  validate_url "$sums_url"
  sums_file=$(mktemp)
  curl "${CURL_ARGS[@]}" -o "$sums_file" "$sums_url" || die "下载 $sums 失败"
  expected=$(awk -v asset="$ASSET" '$2 == asset {print $1}' "$sums_file")
  rm -f "$sums_file"
  if [[ -n $expected ]]; then
    break
  fi
done < <(jq -r '.assets[] | select(.name | test("_sha256sums$|^sha256sums$|^checksums-sha256\\.txt$")) | .name' <<<"$release_json")

if [[ -z $expected ]]; then
  # 无 checksums 资产时（如 termux-x11）用 API 提供的 digest 兜底校验
  expected=$(asset_digest)
  if [[ -n $expected ]]; then
    echo "release $TAG 无 checksums 资产，改用 API digest 校验" >&2
  else
    echo "警告: release $TAG 无 checksums 与 digest，跳过校验" >&2
  fi
fi

# 幂等：本地已有同名文件且 sha256 匹配则跳过下载
if [[ -n $expected && -f $APK_PATH ]] &&
  [[ $(sha256sum "$APK_PATH" | awk '{print $1}') == "$expected" ]]; then
  echo "$ASSET 已存在且 sha256 校验通过，跳过下载" >&2
else
  validate_url "$APK_URL"
  curl "${CURL_ARGS[@]}" -o "$APK_PATH" "$APK_URL" || die "下载 $ASSET 失败"
  # APK 都是 zip：以 PK 魔数判下载有效性（插件 APK 可以只有数百 KB，不设大小下限）
  [[ $(head -c 2 "$APK_PATH") == "PK" ]] || die "下载的文件缺少 zip 魔数（PK），疑似下载失败"
fi

if [[ -n $expected ]]; then
  actual=$(sha256sum "$APK_PATH" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "sha256 校验失败: 期望 $expected 实际 $actual"
  echo "sha256 校验通过: $actual" >&2
fi

write_output tag "$TAG"
write_output asset "$ASSET"
write_output digest "$(asset_digest)"
write_output apk "$APK_PATH"
