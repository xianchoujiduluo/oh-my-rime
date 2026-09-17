# tools/

本项目自带的打包与部署脚本。**不依赖任何第三方工具**（`pack.py` 仅用 Python 标准库），
因此可以在本地和 CI 里跑同一份代码。

---

## 我在改这个项目，怎么验证？

改完配置后，「编译」是由 Rime 引擎完成的，不需要传统编译器：

```bash
# 1. 安装/更新到 Rime 用户目录（脚本会自动清理旧版本文件）
./tools/install.sh

# 2. 重新部署（脚本会尝试自动调用，失败则打印提示）
rime_deployer --build ~/.local/share/fcitx5/rime
```

部署失败时，有问题的文件会被 Rime 移入 `<Rime 用户目录>/trash/`，这是主要查错入口。

> **注意**：只编译单个方案（`rime_deployer --compile x.schema.yaml`）在方案存在
> 反查依赖（如 `stroke`、`radical_pinyin`）时可能失败，**全量 `--build` 更安全**。

---

## 打包：`pack.py`

```bash
python3 tools/pack.py                    # 输出 dist/oh-my-rime.zip
python3 tools/pack.py -o /tmp/my.zip     # 指定输出路径
```

产物内容 = 仓库内所有非点文件（排除 `.git`、`.github/`、`.ide/` 等点目录），
并额外附带一份 **`manifest.txt`**（本包包含哪些文件）。

`manifest.txt` 是安装脚本实现「精确卸载」的依据：卸载时只删除清单里记录的文件，
不会误删用户自己的配置。

### 为什么不用 `find ... -exec zip`？

原流水线写法存在两个问题：

```bash
# 有问题的写法
find ./ -type f ! -name ".*" ! -path "*/.git/*" -exec zip oh-my-rime.zip {} +
```

1. `! -name ".*"` **只排除文件名以点开头的文件**，管不住点**目录**，
   导致 `.github/`、`.ide/` 里的 CI 配置和 Dockerfile 被打进用户包。
2. 依赖 `zip` 命令（部分环境未预装），且无法附带 `manifest.txt`（`-exec` 逐个追加，
   难以先写入清单）。

`pack.py` 用 Python 标准库解决这两点，并保证 **CI 与本地产物一致**。

---

## 安装 / 更新 / 卸载

两个脚本功能对等，按平台选用：

| 平台 | 脚本 |
| --- | --- |
| macOS / Linux | `tools/install.sh` |
| Windows (小狼毫) | `tools/install.ps1` |

### 一行安装（推荐）

**macOS / Linux** —— 终端里粘贴：

```bash
curl -fsSL https://raw.githubusercontent.com/xianchoujiduluo/oh-my-rime/main/tools/install.sh | bash
```

**Windows** —— PowerShell 里粘贴（无需管理员权限）：

```powershell
irm https://raw.githubusercontent.com/xianchoujiduluo/oh-my-rime/main/tools/install.ps1 | iex
```

两个脚本都支持在管道/表达式方式下运行：

- `install.sh` 的 `--help` 正文内嵌，不依赖 `$0`，因此 `curl | bash` 可用。
- `install.ps1` 检测到非文件方式运行时改用异常而非 `exit` 中止，
  因此 `irm | iex` **不会关闭你当前的 PowerShell 会话**。

### 常用变体

**macOS / Linux**

```bash
# 卸载 / 卸载并清空缓存
curl -fsSL <上面的 URL> | bash -s -- --uninstall
curl -fsSL <上面的 URL> | bash -s -- --uninstall --purge

# 安装指定版本 / 指定目录
curl -fsSL <上面的 URL> | bash -s -- --version v1.0.0
curl -fsSL <上面的 URL> | bash -s -- --target ~/Library/Rime
```

**Windows**

```powershell
# 需要传参时先落盘再执行（保留错误详情）
$u='https://raw.githubusercontent.com/xianchoujiduluo/oh-my-rime/main/tools/install.ps1'
$f="$env:TEMP\omr.ps1"; irm $u -OutFile $f
powershell -ExecutionPolicy Bypass -File $f -Version v1.0.0
powershell -ExecutionPolicy Bypass -File $f -Uninstall
powershell -ExecutionPolicy Bypass -File $f -Uninstall -Purge
```

### 脚本方式（仓库内或已下载）

```bash
./tools/install.sh                       # 自动识别 Rime 用户目录
./tools/install.sh --target ~/Library/Rime
./tools/install.sh --version v1.0.0      # 指定版本
./tools/install.sh --from ./oh-my-rime.zip  # 从本地包安装
./tools/install.sh --uninstall           # 卸载（保留用户数据）
./tools/install.sh --uninstall --purge   # 连缓存/用户词典一起删
./tools/install.sh --dry-run             # 只打印动作
./tools/install.sh --no-deploy           # 不自动重新部署
```

### 共同特性

- **安装 / 更新一体**：已安装则先按旧 `manifest.txt` 清理旧文件，再复制新文件
- **保护用户数据**：永不覆盖 `*.custom.yaml`，不碰 `user.yaml`、`*.userdb`、`build/`
- **自动备份**：更新前把已有自定义配置备份到 `backup-<时间戳>/`
- **精确卸载**：只删除本项目安装的文件，可选 `--purge` 连缓存/用户词典一起删
- **安全防护**：拒绝在 `/`、`$HOME`、盘符根目录等危险路径上操作

### macOS / Linux

```bash
./tools/install.sh                       # 自动识别 Rime 用户目录
./tools/install.sh --target ~/Library/Rime
./tools/install.sh --version v1.0.0      # 指定版本
./tools/install.sh --from ./oh-my-rime.zip  # 从本地包安装
./tools/install.sh --uninstall           # 卸载（保留用户数据）
./tools/install.sh --uninstall --purge   # 连缓存/用户词典一起删
./tools/install.sh --dry-run             # 只打印动作
./tools/install.sh --no-deploy           # 不自动重新部署
```

自动识别的目录，按平台与「是否已存在」优先匹配：

- macOS：`~/Library/Rime`（Squirrel）→ `~/.local/share/fcitx5/rime`
- Linux：`~/.local/share/fcitx5/rime` → `~/.config/ibus/rime` → `~/.config/fcitx/rime`

### Windows

```powershell
# 若提示禁止运行脚本，先执行（或单次用 -ExecutionPolicy Bypass）
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

.\tools\install.ps1
.\tools\install.ps1 -Target "$env:APPDATA\Rime"
.\tools\install.ps1 -Version v1.0.0
.\tools\install.ps1 -From .\oh-my-rime.zip
.\tools\install.ps1 -Uninstall
.\tools\install.ps1 -Uninstall -Purge
.\tools\install.ps1 -DryRun
.\tools\install.ps1 -NoDeploy
```

`-Repo` 已预置为本仓库，如需从上游或其他 fork 安装可用它覆盖。

---

## 发布：`.github/workflows/release.yaml`

推 `v*` 标签即触发：

```bash
git tag v1.0.0
git push origin v1.0.0
```

流水线会执行 `python3 tools/pack.py`，并把 `dist/oh-my-rime.zip` 发布到 Release。
也可在 Actions 页面用 `workflow_dispatch` 手动指定 tag 重发。

### 本地复现 CI 打包

```bash
python3 tools/pack.py    # 与 CI 完全相同的命令与产物
```

---

## 注意事项

- **`tools/` 会被打包进用户包**（`pack.py` 不排除它）。用户因此可以直接用
  `install.sh` 更新自己。若不想分发脚本，可在 `pack.py` 的 `collect()` 里加过滤。
- **Linux 需要额外插件**：`librime-plugin-lua`、`librime-plugin-octagram`，
  Windows/macOS 的安装包已内嵌，无需处理。`install.sh` 会检测并提示。
- 修改 `pack.py` 的排除规则后，记得同步检查 `manifest.txt` 是否正确生成。
