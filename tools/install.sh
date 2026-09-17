#!/usr/bin/env bash
#
# oh-my-rime 安装 / 更新 / 卸载脚本 (macOS + Linux)
#
# 用法:
#   ./install.sh                 # 自动识别 Rime 用户目录并安装/更新
#   ./install.sh --target DIR    # 指定 Rime 用户目录
#   ./install.sh --from ZIP      # 从本地 zip 安装（不联网）
#   ./install.sh --version v1.0.0# 指定要安装的 tag
#   ./install.sh --uninstall     # 卸载（仅删除本项目安装的文件）
#   ./install.sh --uninstall --purge   # 卸载并删除 build/ 缓存与用户词典
#   ./install.sh --dry-run       # 只打印将要做什么，不实际改动
#   ./install.sh --no-deploy     # 安装/卸载后不自动重新部署
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 配置：改成你自己的仓库即可
# ---------------------------------------------------------------------------
REPO="${OH_MY_RIME_REPO:-xianchoujiduluo/oh-my-rime}"
ASSET_NAME="oh-my-rime.zip"
DEFAULT_VERSION="latest"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info()  { printf '%s\n' "${GREEN}[*]${RESET} $*"; }
warn()  { printf '%s\n' "${YELLOW}[!]${RESET} $*" >&2; }
die()   { printf '%s\n' "${RED}[x]${RESET} $*" >&2; exit 1; }

DRY_RUN=0
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "    [dry-run] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
MODE="install"
TARGET=""
FROM_ZIP=""
VERSION="$DEFAULT_VERSION"
PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall)  MODE="uninstall" ;;
    --purge)      PURGE=1 ;;
    --target)     TARGET="${2:-}"; shift ;;
    --from)       FROM_ZIP="${2:-}"; shift ;;
    --version)    VERSION="${2:-}"; shift ;;
    --dry-run)    DRY_RUN=1 ;;
    --no-deploy)  NO_DEPLOY=1 ;;
    -h|--help)    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "未知参数: $1（用 --help 查看用法）" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 定位 Rime 用户目录
# ---------------------------------------------------------------------------
detect_target() {
  local os candidates
  os="$(uname -s)"
  if [ "$os" = "Darwin" ]; then
    candidates=(
      "$HOME/Library/Rime"                        # 鼠须管 Squirrel
      "$HOME/.local/share/fcitx5/rime"            # Fcitx5 macOS
    )
  else
    candidates=(
      "$HOME/.local/share/fcitx5/rime"            # Fcitx5 (最常见)
      "$HOME/.config/ibus/rime"                   # ibus-rime
      "$HOME/.config/fcitx/rime"                  # 旧版 fcitx
    )
  fi

  # 优先返回已存在的目录，让用户“无感升级”
  local d
  for d in "${candidates[@]}"; do
    if [ -d "$d" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done

  # 一个都不存在时，返回当前平台的首选位置
  printf '%s\n' "${candidates[0]}"
}

if [ -z "$TARGET" ]; then
  TARGET="$(detect_target)"
  info "自动识别 Rime 用户目录: $TARGET"
else
  info "使用指定目录: $TARGET"
fi

# 安全检查：绝不接受根目录或家目录本身
case "$TARGET" in
  "/"|"$HOME"|"") die "拒绝操作危险目录: '$TARGET'" ;;
esac

# ---------------------------------------------------------------------------
# 部署（重新部署）辅助
# ---------------------------------------------------------------------------
NO_DEPLOY=0

# 若系统装有 rime_deployer，则直接命令行部署；否则退回打印操作提示。
# 返回 0 表示已尝试部署（或用户显式跳过），1 表示只能手动部署。
try_deploy() {
  if [ "$NO_DEPLOY" = "1" ]; then
    printf '\n%s\n' "已跳过重新部署（--no-deploy）。${BOLD}记得稍后手动重新部署${RESET}"
    return 0
  fi

  if command -v rime_deployer >/dev/null 2>&1; then
    printf '\n%s\n' "${BOLD}正在重新部署...${RESET}"
    if [ "$DRY_RUN" = "1" ]; then
      printf '%s\n' "    [dry-run] rime_deployer --build \"$TARGET\""
      return 0
    fi
    if rime_deployer --build "$TARGET" >/tmp/oh-my-rime-deploy.log 2>&1; then
      info "重新部署成功"
      return 0
    fi
    warn "rime_deployer 部署失败，日志末尾："
    tail -n 15 /tmp/oh-my-rime-deploy.log | sed 's/^/    /' >&2
    warn "常见原因：YAML 语法错误；有问题的文件会被移入 $TARGET/trash/"
    return 1
  fi

  return 1
}

redeploy_hint() {
  printf '\n%s\n' "${BOLD}下一步：重新部署（必须做，否则改动不生效）${RESET}"
  case "$(uname -s)" in
    Darwin) printf '%s\n' "  • 鼠须管：菜单栏图标 →「重新部署」" \
                         "  • 或执行: pkill -f Squirrel && open -a Squirrel" ;;
    *)      printf '%s\n' "  • Fcitx5: fcitx5 -r -d   （或右键托盘 → 重新部署）" \
                         "  • ibus  : ibus restart" ;;
  esac
  printf '%s\n' "  • 命令行: rime_deployer --build \"$TARGET\"  （需 librime-bin）"
}

# 部署，失败则打印提示
finish_deploy() {
  if ! try_deploy; then
    redeploy_hint
  fi
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
do_uninstall() {
  local manifest="$TARGET/manifest.txt"

  if [ ! -f "$manifest" ]; then
    die "找不到 $manifest —— 无法确定哪些文件是本项目安装的。
    如果你是从 GitHub 下载 zip 手动解压的（老版本不带 manifest.txt），
    请自行清理，或先用新版 install.sh 覆盖安装一次再卸载。"
  fi

  info "读取清单: $manifest"
  local count=0 rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    [ "$rel" = "manifest.txt" ] && continue
    # 防御：拒绝清单里出现绝对路径或 ..
    case "$rel" in /*|*..*) warn "跳过可疑条目: $rel"; continue ;; esac
    if [ -f "$TARGET/$rel" ]; then
      run rm -f "$TARGET/$rel"
      count=$((count + 1))
    fi
  done < "$manifest"

  run rm -f "$manifest"
  info "已删除 $count 个文件"

  # 清理空目录（dicts/ lua/aux_code/ opencc/ ...）
  if [ "$DRY_RUN" != "1" ]; then
    find "$TARGET" -mindepth 1 -type d -empty -not -path '*/build/*' -delete 2>/dev/null || true
  fi

  if [ "$PURGE" = "1" ]; then
    warn "--purge: 同时删除 build/ 缓存与用户词典（你的个人词频会丢失）"
    run rm -rf "$TARGET/build"
    run rm -f  "$TARGET"/*.userdb "$TARGET"/*.userdb.txt 2>/dev/null || true
    run rm -rf "$TARGET/sync"
  else
    info "保留了 build/ 缓存与用户词典；如需一并删除请加 --purge"
  fi

  info "卸载完成"
  finish_deploy
}

# ---------------------------------------------------------------------------
# 安装 / 更新
# ---------------------------------------------------------------------------
do_install() {
  command -v unzip >/dev/null 2>&1 || die "缺少 unzip，请先安装（如 apt install unzip / brew install unzip）"

  local tmp_dir zip_path url
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" EXIT

  if [ -n "$FROM_ZIP" ]; then
    [ -f "$FROM_ZIP" ] || die "找不到本地压缩包: $FROM_ZIP"
    zip_path="$FROM_ZIP"
    info "使用本地压缩包: $zip_path"
  else
    command -v curl >/dev/null 2>&1 || die "缺少 curl"
    if [ "$VERSION" = "latest" ]; then
      url="https://github.com/$REPO/releases/latest/download/$ASSET_NAME"
    else
      url="https://github.com/$REPO/releases/download/$VERSION/$ASSET_NAME"
    fi
    zip_path="$tmp_dir/$ASSET_NAME"
    info "下载: $url"
    curl -fL --retry 3 --progress-bar -o "$zip_path" "$url" \
      || die "下载失败。请确认仓库 $REPO 已有 release，或先用 --from 指定本地包"
  fi

  # 解压到临时目录，先校验再落地
  unzip -q "$zip_path" -d "$tmp_dir/extract"
  [ -f "$tmp_dir/extract/manifest.txt" ] || die "压缩包内缺少 manifest.txt，可能不是本项目产物"

  # 备份用户配置（自定义文件绝不能被覆盖）
  local backup_dir="$TARGET/backup-$(date +%Y%m%d-%H%M%S)"
  local to_backup=()
  local f
  for f in default.custom.yaml squirrel.custom.yaml weasel.custom.yaml \
           user.yaml installation.yaml; do
    [ -f "$TARGET/$f" ] && to_backup+=("$f")
  done

  mkdir -p "$TARGET"

  if [ ${#to_backup[@]} -gt 0 ]; then
    info "备份你的自定义配置到: $backup_dir"
    run mkdir -p "$backup_dir"
    for f in "${to_backup[@]}"; do
      run cp -p "$TARGET/$f" "$backup_dir/"
    done
  fi

  # 检测是否已安装（有 manifest 说明是本项目装的）
  if [ -f "$TARGET/manifest.txt" ]; then
    info "检测到已安装，执行更新（覆盖式）"
  fi

  # 清理上一版安装的文件：避免“方案改名后旧文件残留”
  if [ -f "$TARGET/manifest.txt" ]; then
    info "清理旧版本文件..."
    local old_rel
    while IFS= read -r old_rel; do
      [ -z "$old_rel" ] && continue
      case "$old_rel" in /*|*..*) continue ;; esac
      # 跳过用户自定义文件
      case "$old_rel" in *.custom.yaml) continue ;; esac
      [ -f "$TARGET/$old_rel" ] && run rm -f "$TARGET/$old_rel"
    done < "$TARGET/manifest.txt"
    run rm -f "$TARGET/manifest.txt"
  fi

  # 复制新文件
  info "安装文件到: $TARGET"
  run cp -p "$tmp_dir/extract/manifest.txt" "$TARGET/manifest.txt"
  local installed=0 rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    case "$rel" in /*|*..*) die "清单含非法路径: $rel" ;; esac
    case "$rel" in
      *.custom.yaml)
        # 不覆盖用户已有自定义配置
        if [ -f "$TARGET/$rel" ]; then
          info "跳过已有自定义配置: $rel"
          continue
        fi
        ;;
    esac
    local d; d="$(dirname "$rel")"
    [ "$d" != "." ] && run mkdir -p "$TARGET/$d"
    run cp -p "$tmp_dir/extract/$rel" "$TARGET/$rel"
    installed=$((installed + 1))
  done < "$tmp_dir/extract/manifest.txt"

  info "共安装 $installed 个文件（另含清单 manifest.txt，供卸载使用）"

  # 提示：Lua 插件依赖（仅 Linux 需要单独装）
  if [ "$(uname -s)" = "Linux" ] && command -v apt >/dev/null 2>&1; then
    local missing=0
    dpkg -l 2>/dev/null | grep -q '^ii  librime-plugin-lua' || missing=1
    dpkg -l 2>/dev/null | grep -q '^ii  librime-plugin-octagram' || missing=1
    if [ "$missing" = "1" ]; then
      warn "检测到可能缺少 Lua / 语法模型插件，薄荷的部分功能将不可用。建议执行："
      printf '%s\n' "    sudo apt install librime-plugin-lua librime-plugin-octagram"
    fi
  fi

  info "安装完成 ✅"
  finish_deploy
}

# ---------------------------------------------------------------------------
case "$MODE" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
esac
