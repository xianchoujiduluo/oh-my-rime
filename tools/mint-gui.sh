#!/usr/bin/env bash
#
# 薄荷输入法图形设置（macOS / Linux）
#
# 为什么需要它：Windows 小狼毫的「输入法设定」里有皮肤、方案、词典三个图形入口，
# 而 macOS 鼠须管从上游就没有设置界面（源码里连 .xib 都没有），只能手写 YAML。
# 本脚本起一个本地网页，把这三件事变成点选操作。
#
# 用法:
#   ./mint-gui.sh                    # 自动探测用户目录并打开浏览器
#   ./mint-gui.sh --target ~/Library/Rime
#   ./mint-gui.sh --port 8765        # 固定端口（默认随机）
#   ./mint-gui.sh --no-browser       # 只起服务
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="$HERE/gui/server.py"

GREEN=''; CYAN=''; YELLOW=''; RED=''; RESET=''
if [ -t 1 ]; then
  GREEN=$'\033[32m'; CYAN=$'\033[36m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
fi

die() { printf '%s\n' "${RED}[x]${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 找 python3
#
# 装了 git 的 macOS 必有 /usr/bin/python3（Command Line Tools 提供），
# 因此这里不做任何安装动作，找不到就明确报错。
# ---------------------------------------------------------------------------
find_python() {
  local p
  for p in /usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  p="$(command -v python3 2>/dev/null || true)"
  [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
  return 1
}

PY="$(find_python || true)"
if [ -z "$PY" ]; then
  die "找不到 python3。macOS 上它随 Xcode 命令行工具一起安装：
    xcode-select --install"
fi

[ -f "$SERVER" ] || die "缺少 $SERVER（请确认 tools/gui/ 已完整同步）"

exec "$PY" "$SERVER" "$@"
