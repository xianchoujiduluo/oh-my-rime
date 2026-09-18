#!/usr/bin/env bash
#
# Rime 皮肤选择器（macOS / Linux）
#
# 为什么需要它：Windows 小狼毫有图形化的「输入法设定」可以勾选皮肤，
# 而 macOS 鼠须管从上游就没有这个界面（源码里连 .xib 都没有），
# 只能手写 squirrel.custom.yaml。本脚本用命令行提供等价的挑选体验。
#
# 用法:
#   ./skin.sh                              # 交互式列出皮肤并选择
#   ./skin.sh --list                       # 只列出所有皮肤（带颜色预览）
#   ./skin.sh --current                    # 显示当前皮肤
#   ./skin.sh --set mint_dark_green        # 直接指定亮色
#   ./skin.sh --set mint_dark_green mint_dark_blue   # 亮色 + 暗色
#   ./skin.sh --preview mint_light_green   # 预览某个皮肤
#   ./skin.sh --target DIR                 # 指定 Rime 用户目录
#   ./skin.sh --no-deploy                  # 改完不自动重新部署
#   ./skin.sh --dry-run                    # 只打印将写入的内容
#   ./skin.sh --no-color                   # 禁用颜色预览
#
# 只用 bash，不依赖 python / yq / PyYAML（macOS 自带 bash 3.2 即可）。
#
# 行为:
#   - 只读 <用户目录> 里的 preset_color_schemes 预设，不改动任何原文件
#   - 选择结果写入 <用户目录>/<前端>.custom.yaml，用 patch 覆写
#   - 因此升级方案时你的选择不会丢
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 输出 helper
# ---------------------------------------------------------------------------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
info() { printf '%s\n' "${GREEN}[*]${RESET} $*"; }
step() { printf '%s\n' "${CYAN}[▸]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[!]${RESET} $*" >&2; }
die()  { printf '%s\n' "${RED}[x]${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
MODE="interactive"
TARGET=""
NO_DEPLOY=0
DRY_RUN=0
NO_COLOR=0
SET_LIGHT=""
SET_DARK=""
PREVIEW_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --list)      MODE="list" ;;
    --current)   MODE="current" ;;
    --set)       MODE="set"
                 SET_LIGHT="${2:-}"; shift
                 # 可选的第二个位置参数 = 暗色皮肤
                 if [ $# -ge 1 ] && [ -n "${2:-}" ] && [ "${2#-}" = "${2:-}" ]; then
                   SET_DARK="$2"; shift
                 fi ;;
    --preview)   MODE="preview"; PREVIEW_ID="${2:-}"; shift ;;
    --target)    TARGET="${2:-}"; shift ;;
    --no-deploy) NO_DEPLOY=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --no-color)  NO_COLOR=1 ;;
    -h|--help)   sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "未知参数: $1（用 --help 查看用法）" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 定位 Rime 用户目录
# ---------------------------------------------------------------------------
detect_target() {
  local os="$1" candidates d
  if [ "$os" = "Darwin" ]; then
    candidates=("$HOME/Library/Rime" "$HOME/.local/share/fcitx5/rime")
  else
    candidates=("$HOME/.local/share/fcitx5/rime" "$HOME/.config/ibus/rime" "$HOME/.config/fcitx/rime")
  fi
  for d in "${candidates[@]}"; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  printf '%s\n' "${candidates[0]}"
}

OS_NAME="$(uname -s)"
[ -n "$TARGET" ] || TARGET="$(detect_target "$OS_NAME")"
TARGET="${TARGET%/}"
[ -d "$TARGET" ] || die "Rime 用户目录不存在: $TARGET"

# ---------------------------------------------------------------------------
# 找到含 preset_color_schemes 的配置源文件
# ---------------------------------------------------------------------------
find_source() {
  local f
  for f in "$TARGET/squirrel.yaml" "$TARGET/weasel.yaml"; do
    [ -f "$f" ] && grep -q '^preset_color_schemes:' "$f" 2>/dev/null && { printf '%s\n' "$f"; return 0; }
  done
  f="/Library/Input Methods/Squirrel.app/Contents/SharedSupport/squirrel.yaml"
  [ -f "$f" ] && grep -q '^preset_color_schemes:' "$f" 2>/dev/null && { printf '%s\n' "$f"; return 0; }
  for f in "/c/Program Files/Rime/data/weasel.yaml" "/mnt/c/Program Files/Rime/data/weasel.yaml"; do
    [ -f "$f" ] && grep -q '^preset_color_schemes:' "$f" 2>/dev/null && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

SRC="$(find_source)" || die "在 $TARGET 及常见安装位置都找不到含 preset_color_schemes 的配置
    请确认已装好鼠须管/小狼毫，并至少重新部署过一次"

case "$SRC" in
  *weasel.yaml)   CUSTOM_NAME="weasel.custom.yaml" ;;
  *)              CUSTOM_NAME="squirrel.custom.yaml" ;;
esac
CUSTOM="$TARGET/$CUSTOM_NAME"

info "Rime 用户目录: $TARGET"
info "皮肤定义来源: $SRC"
info "将写入: $CUSTOM"

# ---------------------------------------------------------------------------
# 解析 YAML（纯 bash）
#   只需处理本仓库的实际结构：preset_color_schemes 下两级缩进、
#   无锚点、无列表项。用字符串操作而非正则工具，兼容 bash 3.2。
# ---------------------------------------------------------------------------

# 去掉行尾注释（尊重引号），再去掉首尾空白
strip_val() {
  local v="$1"
  local out="" ch q="" i=0 len=${#v}
  while [ "$i" -lt "$len" ]; do
    ch="${v:$i:1}"
    if [ -n "$q" ]; then
      out+="$ch"
      [ "$ch" = "$q" ] && q=""
    elif [ "$ch" = '"' ] || [ "$ch" = "'" ]; then
      q="$ch"; out+="$ch"
    elif [ "$ch" = '#' ]; then
      break
    else
      out+="$ch"
    fi
    i=$((i + 1))
  done
  # 修剪首尾空白
  out="${out#"${out%%[![:space:]]*}"}"
  out="${out%"${out##*[![:space:]]}"}"
  # 去引号
  case "$out" in
    \"*\") out="${out#\"}"; out="${out%\"}" ;;
    \'*\') out="${out#\'}"; out="${out%\'}" ;;
  esac
  printf '%s' "$out"
}

# 从 $1 读取亮色/暗色，输出 "light<TAB>dark"
parse_current() {
  local file="$1" light="" dark="" in_style=0 line key val
  [ -f "$file" ] || { printf '\t\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    # 同上：只跳过整行注释，不能误伤带行尾注释的数据行
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in \#*) continue ;; esac

    key="${line%%:*}"; key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    val="${line#*:}"

    # 形式一：Rime patch 的扁平键  style/color_scheme: xxx
    case "$key" in
      style/color_scheme)      [ -z "$light" ] && light="$(strip_val "$val")" ;;
      style/color_scheme_dark) [ -z "$dark" ]  && dark="$(strip_val "$val")" ;;
    esac

    # 形式二：嵌套块  style:\n  color_scheme: xxx
    if [ "$key" = "style" ]; then in_style=1; continue; fi
    if [ "$in_style" = "1" ]; then
      case "$line" in
        [!\ ]*) in_style=0 ;;   # 回到顶层，块结束
      esac
    fi
    [ "$in_style" = "1" ] || continue
    case "$key" in
      color_scheme)      [ -z "$light" ] && light="$(strip_val "$val")" ;;
      color_scheme_dark) [ -z "$dark" ]  && dark="$(strip_val "$val")" ;;
    esac
  done < "$file"
  printf '%s\t%s\n' "$light" "$dark"
}

# 解析皮肤列表，填充全局数组
IDS=(); NAMES=(); BACKS=(); TEXTS=(); HLS=()
parse_schemes() {
  local file="$1" in_block=0 line cur=""
  while IFS= read -r line || [ -n "$line" ]; do
    # 跳过空行与「以 # 开头」的注释行。
    # 注意：不能用 case 的 [[:space:]]*\#* —— 那会连"值里带行尾注释"
    # 的数据行（如 `back_color: 0xefefef  # 底色`）也一并跳过。
    case "$line" in "") continue ;; esac
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in \#*) continue ;; esac

    if [ "$in_block" = "0" ]; then
      [ "$line" = "preset_color_schemes:" ] && in_block=1
      continue
    fi

    # 顶层键出现 → 块结束
    case "$line" in
      [!\ ]*) break ;;
    esac

    # 2 空格缩进 = 皮肤 id
    if [ "${line:0:2}" = "  " ] && [ "${line:2:1}" != " " ]; then
      cur="${line:2}"
      cur="${cur%%:*}"
      IDS+=("$cur"); NAMES+=(""); BACKS+=(""); TEXTS+=(""); HLS+=("")
      continue
    fi

    # 4 空格缩进 = 字段
    if [ "${line:0:4}" = "    " ] && [ "${line:4:1}" != " " ] && [ -n "$cur" ]; then
      local key="${line:4}"; key="${key%%:*}"
      local val="${line#*:}"
      local idx=$(( ${#IDS[@]} - 1 ))
      case "$key" in
        name)                          NAMES[$idx]="$(strip_val "$val")" ;;
        back_color)                    BACKS[$idx]="$(strip_val "$val")" ;;
        text_color)                    TEXTS[$idx]="$(strip_val "$val")" ;;
        hilited_candidate_back_color)  HLS[$idx]="$(strip_val "$val")" ;;
      esac
      continue
    fi
  done < "$file"
}

parse_schemes "$SRC"
[ "${#IDS[@]}" -gt 0 ] || die "在 $SRC 里没解析到任何皮肤（文件格式可能已变化）"

# 当前生效：优先 custom，其次源文件
read -r CUR_LIGHT CUR_DARK <<EOF
$(parse_current "$CUSTOM")
EOF
if [ -z "$CUR_LIGHT" ]; then
  read -r CUR_LIGHT CUR_DARK <<EOF
$(parse_current "$SRC")
EOF
fi

# ---------------------------------------------------------------------------
# 颜色预览
# ---------------------------------------------------------------------------
use_color() {
  [ "$NO_COLOR" = "1" ] && return 1
  [ -t 1 ] || return 1
  case "${COLORTERM:-}" in
    *truecolor*|*24bit*) return 0 ;;
  esac
  case "${TERM:-}" in
    *truecolor*|*24bit*) return 0 ;;
  esac
  return 1
}

HAVE_COLOR=0
use_color && HAVE_COLOR=1

# 0xRRGGBB / #RRGGBB / 十进制 → 输出 "r g b"，失败返回 1
to_rgb() {
  local v="$1" n
  v="${v// /}"
  [ -n "$v" ] || return 1
  case "$v" in
    0x*|0X*) n=$((16#${v#0[xX]})) ;;
    \#*)     n=$((16#${v#\#})) ;;
    *)       n=$((v)) 2>/dev/null || return 1 ;;
  esac
  # 兼容 0xAARRGGBB
  [ "$n" -gt 16777215 ] && n=$((n & 16777215))
  printf '%s %s %s\n' $(((n >> 16) & 255)) $(((n >> 8) & 255)) $((n & 255))
}

# 渲染一排色块
# 用 printf 而不是 $'...' 拼接：后者在变量穿插时极易被引号拆错，
# 导致 \033 不被解释、原样输出。
render_swatch() {
  local out="" hex rgb r g b
  for hex in "$@"; do
    if rgb="$(to_rgb "$hex")"; then
      read -r r g b <<<"$rgb"
      out+="$(printf '\033[48;2;%s;%s;%sm\033[38;2;%s;%s;%sm  \033[0m' \
                     "$r" "$g" "$b" "$r" "$g" "$b")"
    else
      out+="  "
    fi
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 显示
# ---------------------------------------------------------------------------
show_row() {
  local i="$1" marker="  " tag="" id="${IDS[$i]}"
  [ "$id" = "${CUR_LIGHT:-}" ] && { marker="* "; tag="${GREEN}← 当前亮色${RESET}"; }
  [ "$id" = "${CUR_DARK:-}" ] && tag="${tag} ${CYAN}← 当前暗色${RESET}"

  printf '%s%2d) ' "$marker" $((i + 1))
  if [ "$HAVE_COLOR" = "1" ]; then
    printf '%s ' "$(render_swatch "${BACKS[$i]}" "${TEXTS[$i]}" "${HLS[$i]}")"
  fi
  printf '%-24s %s' "$id" "${NAMES[$i]}"
  [ -n "$tag" ] && printf '  %s' "$tag"
  printf '\n'
}

list_all() {
  printf '\n%s\n' "${BOLD}可用皮肤（${#IDS[@]} 套）${RESET}"
  if [ "$HAVE_COLOR" = "1" ]; then
    printf '%s\n' "${DIM}  色块依次为：底色 / 拼音色 / 首选底色${RESET}"
  fi
  printf '\n'
  local i
  for ((i = 0; i < ${#IDS[@]}; i++)); do show_row "$i"; done
  printf '\n'
  printf '%s\n' "${DIM}  * = 当前启用；「系统设置 → 外观」切换亮/暗时分别生效${RESET}"
}

# ---------------------------------------------------------------------------
# 写入 custom.yaml
# ---------------------------------------------------------------------------
write_patch() {
  local light="$1" dark="$2" tmp backup
  tmp="$(mktemp)"

  if [ -f "$CUSTOM" ] && [ -s "$CUSTOM" ]; then
    # 只要 custom 文件已存在就【合并】，绝不整份覆盖：
    # 先剔除旧的 color_scheme 行（含嵌套写法），保留其余自定义项。
    grep -vE '^[[:space:]]*(style/)?color_scheme(_dark)?:' "$CUSTOM" > "$tmp" || true

    # 若剔除后没有 patch: 行（例如原文件只有注释），补一个
    if ! grep -qE '^patch:[[:space:]]*$' "$tmp"; then
      { printf 'patch:\n'; cat "$tmp"; } > "$tmp.2"
      mv "$tmp.2" "$tmp"
    fi

    # 去掉末尾多余空行；并确保文件以换行结尾，
    # 否则追加的新行会和最后一行粘在一起（app_options: true  style/color_scheme: x）
    while [ -s "$tmp" ] && [ -z "$(tail -c 1 "$tmp")" ]; do
      head -c -1 "$tmp" > "$tmp.3" && mv "$tmp.3" "$tmp"
    done
    [ -s "$tmp" ] && printf '\n' >> "$tmp"

    printf '  style/color_scheme: %s\n' "$light" >> "$tmp"
    [ -n "$dark" ] && printf '  style/color_scheme_dark: %s\n' "$dark" >> "$tmp"
  else
    {
      printf '# 皮肤覆写 —— 由 tools/skin.sh 生成\n'
      printf '# 优先级高于 squirrel.yaml / weasel.yaml，升级方案时不会被覆盖\n'
      printf 'patch:\n'
      printf '  style/color_scheme: %s\n' "$light"
      [ -n "$dark" ] && printf '  style/color_scheme_dark: %s\n' "$dark"
    } > "$tmp"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf '\n%s\n' "${BOLD}[dry-run] 将写入 $CUSTOM：${RESET}"
    sed 's/^/    /' "$tmp"
    rm -f "$tmp"
    return 0
  fi

  if [ -f "$CUSTOM" ]; then
    backup="$CUSTOM.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CUSTOM" "$backup"
    info "已备份原文件 → $(basename "$backup")"
  fi

  mv "$tmp" "$CUSTOM"
  info "已写入 $CUSTOM"
}

# ---------------------------------------------------------------------------
# 重新部署
# ---------------------------------------------------------------------------
redeploy() {
  if [ "$NO_DEPLOY" = "1" ]; then
    warn "已跳过重新部署（--no-deploy），记得手动部署"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "    [dry-run] 重新部署"
    return 0
  fi

  if [ "$OS_NAME" = "Darwin" ]; then
    local s="/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"
    if [ -x "$s" ]; then
      step "重新部署"
      if "$s" --build >/dev/null 2>&1; then
        info "部署完成 ✅"
      else
        warn "部署命令返回非 0，请查看日志"
      fi
      return 0
    fi
  elif command -v rime_deployer >/dev/null 2>&1; then
    step "重新部署"
    if ( cd "$TARGET" && rime_deployer --build ) >/dev/null 2>&1; then
      info "部署完成 ✅"
    else
      warn "部署失败，常见原因是 YAML 语法错误"
    fi
    return 0
  fi

  warn "未能自动重新部署，请手动操作："
  case "$OS_NAME" in
    Darwin) printf '%s\n' "  • 右键菜单栏「中」图标 → Deploy" ;;
    *)      printf '%s\n' "  • 在输入法前端菜单里选择「重新部署」" ;;
  esac
}

# ---------------------------------------------------------------------------
# 各模式
# ---------------------------------------------------------------------------
find_index() {
  local want="$1" i
  for ((i = 0; i < ${#IDS[@]}; i++)); do
    [ "${IDS[$i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

case "$MODE" in
  list)
    list_all
    exit 0 ;;

  current)
    printf '\n%s\n' "${BOLD}当前皮肤${RESET}"
    printf '  亮色 : %s\n' "${CUR_LIGHT:-（未设置，用源文件默认）}"
    printf '  暗色 : %s\n' "${CUR_DARK:-（未设置）}"
    printf '\n%s\n' "${DIM}  定义来源: $SRC${RESET}"
    if [ -f "$CUSTOM" ]; then
      printf '%s\n' "${DIM}  覆写文件: $CUSTOM (存在)${RESET}"
    else
      printf '%s\n' "${DIM}  覆写文件: $CUSTOM (尚未创建)${RESET}"
    fi
    exit 0 ;;

  preview)
    [ -n "$PREVIEW_ID" ] || die "用法: --preview <皮肤id>"
    i="$(find_index "$PREVIEW_ID")" || die "找不到皮肤: $PREVIEW_ID（用 --list 查看可用 id）"
    printf '\n%s\n' "${BOLD}${NAMES[$i]}${RESET}  (${IDS[$i]})"
    if [ "$HAVE_COLOR" = "1" ]; then
      printf '  预览  : %s  %s\n' "$(render_swatch "${BACKS[$i]}" "${TEXTS[$i]}" "${HLS[$i]}")" "${DIM}底色/拼音色/首选底色${RESET}"
    fi
    printf '  底色     : %s\n' "${BACKS[$i]}"
    printf '  拼音色   : %s\n' "${TEXTS[$i]}"
    printf '  首选底色 : %s\n' "${HLS[$i]}"
    exit 0 ;;

  set)
    [ -n "$SET_LIGHT" ] || die "用法: --set <亮色id> [暗色id]"
    find_index "$SET_LIGHT" >/dev/null || die "找不到皮肤: $SET_LIGHT（用 --list 查看）"
    if [ -n "$SET_DARK" ]; then
      find_index "$SET_DARK" >/dev/null || die "找不到皮肤: $SET_DARK"
    fi
    write_patch "$SET_LIGHT" "$SET_DARK"
    redeploy
    exit 0 ;;
esac

# ---------------------------------------------------------------------------
# 交互模式
# ---------------------------------------------------------------------------
list_all

printf '%s' "选择【亮色】皮肤编号（回车取消）: "
read -r ans || true
[ -z "${ans:-}" ] && { info "已取消"; exit 0; }
case "$ans" in *[!0-9]*) die "请输入数字" ;; esac
idx=$((ans - 1))
[ "$idx" -ge 0 ] && [ "$idx" -lt "${#IDS[@]}" ] || die "编号超出范围（1-${#IDS[@]}）"
LIGHT="${IDS[$idx]}"

printf '%s' "选择【暗色】皮肤编号（回车 = 沿用当前设置）: "
read -r ans2 || true
DARK=""
if [ -n "${ans2:-}" ]; then
  case "$ans2" in *[!0-9]*) die "请输入数字" ;; esac
  idx2=$((ans2 - 1))
  [ "$idx2" -ge 0 ] && [ "$idx2" -lt "${#IDS[@]}" ] || die "编号超出范围（1-${#IDS[@]}）"
  DARK="${IDS[$idx2]}"
fi

printf '\n'
info "亮色 → $LIGHT"
[ -n "$DARK" ] && info "暗色 → $DARK"
write_patch "$LIGHT" "$DARK"
redeploy
