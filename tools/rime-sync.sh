#!/usr/bin/env bash
#
# Rime 用户词典 Git 同步（macOS + Linux）
#
# 原理：Rime 把用户词典导出成 <sync_dir>/<installation_id>/*.userdb.txt 快照，
#       本脚本把这个目录当成 Git 仓库来传输。
#       合并由 Rime 自己完成（按时间衰减加权），Git 只负责搬文件。
#
# 用法:
#   ./rime-sync.sh                # pull → 触发 Rime 同步 → commit & push
#   ./rime-sync.sh --status       # 只看状态，不改动任何东西
#   ./rime-sync.sh --no-push      # 同步并提交到本地，但不 push
#   ./rime-sync.sh --push-only    # 不触发 Rime 同步，只提交已有改动并 push
#   ./rime-sync.sh --init         # 首次设置：建仓库、写 .gitignore/.gitattributes
#   ./rime-sync.sh --target DIR   # 指定 Rime 用户目录
#   ./rime-sync.sh --repo DIR     # 指定 Git 仓库目录（默认读 installation.yaml 的 sync_dir）
#   ./rime-sync.sh --dry-run      # 只打印将执行的命令
#
# 前置条件:
#   1. 在 <Rime 用户目录>/installation.yaml 里设置 sync_dir 指向本 Git 仓库
#   2. 每台设备的 installation_id 必须不同
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 输出 helper
# ---------------------------------------------------------------------------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
BOLD=$'\033[1m'; RESET=$'\033[0m'
info() { printf '%s\n' "${GREEN}[*]${RESET} $*"; }
step() { printf '%s\n' "${CYAN}[▸]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[!]${RESET} $*" >&2; }
die()  { printf '%s\n' "${RED}[x]${RESET} $*" >&2; exit 1; }

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
MODE="sync"
TARGET=""
REPO=""
DO_PUSH=1
DO_TRIGGER=1

while [ $# -gt 0 ]; do
  case "$1" in
    --status)    MODE="status" ;;
    --init)      MODE="init" ;;
    --no-push)   DO_PUSH=0 ;;
    --push-only) DO_TRIGGER=0 ;;
    --target)    TARGET="${2:-}"; shift ;;
    --repo)      REPO="${2:-}"; shift ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "未知参数: $1（用 --help 查看用法）" ;;
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
      "$HOME/Library/Rime"                      # 鼠须管 Squirrel
      "$HOME/.local/share/fcitx5/rime"          # Fcitx5 macOS
    )
  else
    candidates=(
      "$HOME/.local/share/fcitx5/rime"          # Fcitx5
      "$HOME/.config/ibus/rime"                 # ibus-rime
      "$HOME/.config/fcitx/rime"                # 旧版 fcitx
    )
  fi

  local d
  for d in "${candidates[@]}"; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  printf '%s\n' "${candidates[0]}"
}

if [ -z "$TARGET" ]; then
  TARGET="$(detect_target)"
fi
TARGET="${TARGET%/}"
[ -d "$TARGET" ] || die "Rime 用户目录不存在: $TARGET"

INSTALL_YAML="$TARGET/installation.yaml"
[ -f "$INSTALL_YAML" ] || die "找不到 $INSTALL_YAML（Rime 首次部署后才会生成，请先启动输入法）"

# ---------------------------------------------------------------------------
# 从 installation.yaml 读取 sync_dir 与 installation_id
# 只做简单解析，不依赖 yaml 库
# ---------------------------------------------------------------------------
yaml_get() {
  local key="$1" file="$2"
  sed -nE "s/^[[:space:]]*${key}:[[:space:]]*(.*)$/\1/p" "$file" \
    | head -1 | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/[[:space:]]+$//'
}

SYNC_DIR="$(yaml_get sync_dir "$INSTALL_YAML")"
INSTALL_ID="$(yaml_get installation_id "$INSTALL_YAML")"

if [ -z "$REPO" ]; then
  REPO="$SYNC_DIR"
fi

[ -n "$INSTALL_ID" ] || die "installation.yaml 里没有 installation_id"

info "Rime 用户目录: $TARGET"
info "installation_id: $INSTALL_ID"

if [ -z "$REPO" ]; then
  warn "installation.yaml 里没有设置 sync_dir，且未用 --repo 指定"
  printf '%s\n' "    请先添加一行（路径按需修改）："
  printf '%s\n' "        sync_dir: $HOME/rime-sync"
  die "缺少 sync_dir"
fi

REPO="${REPO/#\~/$HOME}"     # 展开 ~
info "同步仓库: $REPO"

# ---------------------------------------------------------------------------
# --init：首次设置仓库
# ---------------------------------------------------------------------------
do_init() {
  [ -d "$REPO" ] || run mkdir -p "$REPO"

  if [ ! -d "$REPO/.git" ]; then
    step "初始化 Git 仓库"
    run git -C "$REPO" init -q
  else
    step "仓库已存在，跳过 git init"
  fi

  # .gitignore：只追踪快照文本
  if [ ! -f "$REPO/.gitignore" ]; then
    step "写入 .gitignore"
    if [ "$DRY_RUN" = "1" ]; then
      printf '%s\n' "    [dry-run] 创建 $REPO/.gitignore"
    else
      cat > "$REPO/.gitignore" <<'EOF'
# 只追踪 Rime 导出的快照文本，忽略临时文件与二进制
*.tmp
*.log
.DS_Store
Thumbs.db
*.userdb
*.userdb/
*.ldb
*.sst
EOF
    fi
  fi

  # .gitattributes：快照冲突时取并集（Rime 会按时间衰减重新计算权重，
# 多出来的行不会造成错误）
  if [ ! -f "$REPO/.gitattributes" ]; then
    step "写入 .gitattributes"
    if [ "$DRY_RUN" = "1" ]; then
      printf '%s\n' "    [dry-run] 创建 $REPO/.gitattributes"
    else
      cat > "$REPO/.gitattributes" <<'EOF'
# 用户词典快照：冲突时保留双方，交给 Rime 合并
*.userdb.txt merge=union
EOF
    fi
  fi

  info "初始化完成。后续步骤："
  printf '%s\n' "    1. cd $REPO && git remote add origin <你的私有仓库>"
  printf '%s\n' "    2. git add -A && git commit -m 'init' && git push -u origin main"
  printf '%s\n' "    3. 在每台设备上运行 ./rime-sync.sh"
}

# ---------------------------------------------------------------------------
# 触发 Rime 同步（把 sync_dir ↔ 本地 userdb 互相合并）
# ---------------------------------------------------------------------------
find_deployer() {
  # macOS：Squirrel 可执行文件
  local mac="/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"
  [ -x "$mac" ] && { printf '%s\n' "$mac"; return 0; }

  # Linux：rime_dict_manager 支持无头 --sync（不需要前端在运行）
  if command -v rime_dict_manager >/dev/null 2>&1; then
    command -v rime_dict_manager
    return 0
  fi
  # ibus 的打包路径
  if [ -x /usr/lib/ibus-rime/rime_dict_manager ]; then
    printf '%s\n' /usr/lib/ibus-rime/rime_dict_manager
    return 0
  fi

  return 1
}

trigger_sync() {
  local os deployer
  os="$(uname -s)"

  if [ "$os" = "Darwin" ]; then
    deployer="$(find_deployer || true)"
    if [ -z "$deployer" ]; then
      warn "找不到 Squirrel，无法自动同步。请手动操作："
      printf '%s\n' "  • 右键菜单栏「中」图标 → Sync user data"
      return 1
    fi
    step "触发同步: $deployer --sync"
    # --sync 通过分布式通知转发给正在运行的输入法进程；
    # 若输入法未运行，通知会丢失，因此这里提示用户。
    run "$deployer" --sync
    if [ "$DRY_RUN" != "1" ]; then
      sleep 1
      if ! pgrep -qf 'Squirrel'; then
        warn "未检测到运行中的 Squirrel，通知可能未被处理"
        printf '%s\n' "    请启动鼠须管后重试，或用菜单栏 → Sync user data"
      fi
    fi
    return 0
  fi

  # Linux
  deployer="$(find_deployer || true)"
  if [ -z "$deployer" ]; then
    warn "找不到 rime_dict_manager，无法自动同步。"
    printf '%s\n' "    可安装 librime-bin 后重试（提供无头同步）："
    printf '%s\n' "        sudo apt install librime-bin"
    printf '%s\n' "    或在输入法前端菜单里选择「同步」"
    return 1
  fi
  step "触发同步: $deployer --sync"
  # 注意：rime_dict_manager 需要知道 user_data_dir / shared_data_dir，
  # 它默认用当前目录，因此切到用户目录执行。
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "    [dry-run] (cd $TARGET && $deployer --sync)"
  else
    ( cd "$TARGET" && "$deployer" --sync )
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Git 操作
# ---------------------------------------------------------------------------
# 是否已配置提交身份（首次 commit 必需）
has_git_identity() {
  local n m
  n="$(git config --get user.name 2>/dev/null || true)"
  m="$(git config --get user.email 2>/dev/null || true)"
  [ -n "$n" ] && [ -n "$m" ]
}

# 是否是"空分支"：有 .git，但当前分支还没有任何提交
is_unborn_branch() {
  ! git -C "$REPO" rev-parse --verify HEAD >/dev/null 2>&1
}

assert_git_identity() {
  if has_git_identity; then return 0; fi
  warn "Git 尚未配置提交身份，无法创建提交"
  printf '%s\n' "    请先执行（把值换成你自己的）："
  printf '%s\n' "        git config --global user.name  \"你的名字\""
  printf '%s\n' "        git config --global user.email \"你的邮箱\""
  printf '%s\n' "    然后重新运行本脚本。"
  return 1
}

git_pull() {
  step "拉取其他设备的更新"
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "    [dry-run] git -C $REPO pull --rebase --autostash"
    return 0
  fi
  if ! git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    info "未配置 origin，跳过 pull"
    return 0
  fi

  # 空分支（还没有任何提交）时 git pull 会报
  # "Updating an unborn branch with changes added to the index"。
  # 此时没有本地历史可 rebase，pull 本身也没有意义，跳过。
  if is_unborn_branch; then
    info "当前分支还没有首次提交，跳过 pull"
    printf '%s\n' "    （首次提交后，后续运行才会真正拉取其他设备的快照）"
    return 0
  fi

  if ! git -C "$REPO" pull --rebase --autostash 2>&1; then
    warn "git pull 失败"
    printf '%s\n' "    若是冲突，处理建议："
    printf '%s\n' "      cd $REPO"
    printf '%s\n' "      git status              # 看冲突文件"
    printf '%s\n' "      git checkout --theirs -- '*.userdb.txt'   # 或 --ours"
    printf '%s\n' "      git add -A && git rebase --continue"
    printf '%s\n' "    若是远程仓库为空/无跟踪分支，可先完成首次提交再重试。"
    return 1
  fi
}

git_commit_push() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "    [dry-run] git -C $REPO add -A && commit && push"
    return 0
  fi

  if [ -z "$(git -C "$REPO" status --porcelain)" ]; then
    info "无变化，无需提交"
    return 0
  fi

  # 空分支 + 暂存区已有内容时 git 会拒绝 pull/rebase，
  # 所以先把已有暂存内容提交掉，避免留下"半初始化"状态。
  if is_unborn_branch; then
    info "当前分支还没有首次提交，先完成首次提交"
  fi

  assert_git_identity || return 1

  step "提交快照"
  git -C "$REPO" add -A
  local host; host="$(hostname 2>/dev/null || echo unknown)"
  if ! git -C "$REPO" commit -q -m "sync: $host $(date '+%F %T')" 2>&1; then
    warn "git commit 失败"
    return 1
  fi
  info "已提交"

  if [ "$DO_PUSH" != "1" ]; then
    info "按 --no-push 保留在本地"
    return 0
  fi

  if ! git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    info "未配置 origin，已提交到本地"
    return 0
  fi

  step "推送到远程"
  local branch
  branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

  # 是否已设置上游分支
  if git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    if git -C "$REPO" push -q 2>&1; then
      info "已推送"
      return 0
    fi
    warn "push 失败（远程可能有新提交）。重试本脚本，或手动 git pull --rebase 后 push"
    return 1
  fi

  # 首次推送：远程该分支可能已有历史（另一台设备先推过），
  # 直接 --set-upstream 会因历史无关被拒，需先 rebase。
  info "首次推送，设置上游 origin/$branch"
  if git -C "$REPO" fetch -q origin 2>/dev/null; then
    if git -C "$REPO" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
      if ! git -C "$REPO" rebase "origin/$branch" 2>&1; then
        warn "与 origin/$branch 合并出现冲突"
        printf '%s\n' "    处理建议："
        printf '%s\n' "      cd $REPO"
        printf '%s\n' "      git status"
        printf '%s\n' "      # 快照文件可直接取远端版本：git checkout --theirs -- '*.userdb.txt'"
        printf '%s\n' "      git add -A && git rebase --continue"
        printf '%s\n' "      git push -u origin $branch"
        return 1
      fi
    fi
  fi

  if git -C "$REPO" push -q --set-upstream origin "$branch" 2>&1; then
    info "已推送"
    return 0
  fi
  warn "push 失败。若远端已有历史，请手动："
  printf '%s\n' "      cd $REPO"
  printf '%s\n' "      git fetch origin"
  printf '%s\n' "      git rebase origin/main"
  printf '%s\n' "      git push -u origin main"
  return 1
}

# ---------------------------------------------------------------------------
# --status
# ---------------------------------------------------------------------------
do_status() {
  printf '%s\n' "${BOLD}=== Rime 用户词典同步状态 ===${RESET}"
  printf '%s\n' "  Rime 用户目录   : $TARGET"
  printf '%s\n' "  installation_id : $INSTALL_ID"
  printf '%s\n' "  sync_dir        : ${SYNC_DIR:-（未设置）}"
  printf '%s\n' "  仓库            : $REPO"
  echo

  if [ -d "$REPO/.git" ]; then
    printf '%s\n' "${BOLD}Git 状态${RESET}"
    git -C "$REPO" status --short --branch || true
    echo
    printf '%s\n' "${BOLD}最近的提交${RESET}"
    git -C "$REPO" log --oneline -5 2>/dev/null || echo "  （无提交）"
    echo
    printf '%s\n' "${BOLD}远程${RESET}"
    git -C "$REPO" remote -v | sed 's/^/  /' || true
  else
    warn "$REPO 不是 Git 仓库，先运行: $0 --init"
  fi

  echo
  printf '%s\n' "${BOLD}快照目录${RESET}"
  if [ -d "$REPO/$INSTALL_ID" ]; then
    ls -la "$REPO/$INSTALL_ID" | sed 's/^/  /'
  else
    printf '%s\n' "  $REPO/$INSTALL_ID 尚不存在（还没同步过）"
  fi
  echo
  printf '%s\n' "${BOLD}所有设备的快照${RESET}"
  find "$REPO" -maxdepth 2 -name '*.userdb.txt' 2>/dev/null | sed "s|$REPO/|  |" || true
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
case "$MODE" in
  init)   do_init; exit 0 ;;
  status) do_status; exit 0 ;;
esac

[ -d "$REPO/.git" ] || die "$REPO 不是 Git 仓库。先运行: $0 --init"

GIT_FAILED=0
RIME_SYNCED=1

git_pull || GIT_FAILED=1

if [ "$DO_TRIGGER" = "1" ]; then
  trigger_sync || RIME_SYNCED=0
fi

git_commit_push || GIT_FAILED=1

echo
if [ "$GIT_FAILED" != "0" ]; then
  warn "Git 操作失败，请查看上面的提示"
  exit 1
fi

if [ "$RIME_SYNCED" = "1" ]; then
  info "同步完成 ✅"
else
  # git 部分已成功，只是没能自动触发 Rime 同步
  warn "Git 已同步，但未能自动触发 Rime 同步"
  printf '%s\n' "    → 快照可能是旧的。请手动同步一次："
  case "$(uname -s)" in
    Darwin) printf '%s\n' "        右键菜单栏「中」图标 → Sync user data" ;;
    *)      printf '%s\n' "        在输入法前端菜单里选择「同步」" ;;
  esac
  printf '%s\n' "    → 然后重新运行本脚本以提交最新快照"
  exit 0
fi
