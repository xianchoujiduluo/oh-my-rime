# tools/

本项目自带的打包、安装与同步脚本。**不依赖任何第三方工具**（`pack.py` 仅用 Python 标准库），
因此可以在本地和 CI 里跑同一份代码。

| 脚本 | 用途 |
| --- | --- |
| `pack.py` | 打包为可分发的 `dist/oh-my-rime.zip` |
| `install.sh` / `install.ps1` | 安装 / 更新 / 卸载配置方案 |
| `rime-sync.sh` / `rime-sync.ps1` | 用 Git 同步**用户词典**（多设备） |
| `skin.sh` | 命令行挑选皮肤（补 macOS 没有图形化皮肤选择器的缺口） |

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
$u='https://raw.githubusercontent.com/xianchoujiduluo/oh-my-rime/main/tools/install.ps1'; $f="$env:TEMP\omr-install.ps1"; irm $u -OutFile $f; powershell -ExecutionPolicy Bypass -File $f
```

> **为什么不是 `irm ... | iex`？**
> `.ps1` 文件带 UTF-8 BOM（Windows PowerShell 5.1 需要它才能正确读中文，
> 否则按 GBK 解码会报「字符串缺少终止符」）。而 `irm` 会把 BOM 当成
> 普通字符（U+FEFF）拼在脚本开头，导致 `iex` 解析失败。
> 先 `-OutFile` 落盘再用 `-File` 执行，BOM 会被正确当作编码标记识别。
>
> 若确实想用管道形式，需要手动去掉前导 BOM 字符：
> ```powershell
> $c = (irm <URL>) -replace "^[\uFEFF]", ""; iex $c
> ```

两个脚本的行为差异：

- `install.sh` 的 `--help` 正文内嵌，不依赖 `$0`，因此 `curl | bash` 可用。
- `install.ps1` 检测到非文件方式运行时改用异常而非 `exit` 中止，
  因此即使管道执行也**不会关闭你当前的 PowerShell 会话**。

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
.\tools\install.ps1 -WeaselDir "C:\Program Files\Rime"
```

`-Repo` 已预置为本仓库，如需从上游或其他 fork 安装可用它覆盖。

#### 重新部署与小狼毫安装目录

安装/卸载完成后，脚本会尝试自动执行 `WeaselDeployer.exe /deploy`。

小狼毫的安装目录按以下顺序查找：

1. 命令行显式传入的 `-WeaselDir`
2. 注册表 `HKLM\SOFTWARE\Rime\Weasel` 的 `InstallDir` / `WeaselRoot`
   （32 位进程会落到 `WOW6432Node`，脚本会一并查询）
3. 常见默认位置：`%ProgramFiles%\Rime`、`%ProgramFiles(x86)%\Rime`、
   `%ProgramW6432%\Rime`、`%LOCALAPPDATA%\Programs\Rime`
4. 在 `%ProgramFiles%\Rime` 下递归查找
5. `PATH`

若提示 **未找到 WeaselDeployer.exe**，脚本会列出已尝试的路径。此时：

```powershell
# 方式一：显式指定安装目录（最常见为 "C:\Program Files\Rime"）
.\tools\install.ps1 -WeaselDir "C:\Program Files\Rime"

# 方式二：手动重新部署
#   右键任务栏「中」图标 → 重新部署
#   或开始菜单 → 小狼毫输入法 → 【小狼毫】重新部署

# 方式三：自己跑 deployer（路径换成实际安装目录）
& "C:\Program Files\Rime\WeaselDeployer.exe" /deploy
```

> `WeaselDeployer.exe` 的可用参数：`/deploy`（更新工作区/重新部署）、
> `/dict`（词典管理）、`/sync`（同步用户数据）、`/install`（初始部署）。
> 脚本使用 `/deploy`。

若自动部署返回非 0 退出码，脚本会提示查看 `%TEMP%` 下的 `rime.weasel.*` 日志；
YAML 出错时，有问题的文件会被 Rime 移入 `<Rime 用户目录>\trash\`。

---

## 用户词典同步：`rime-sync.sh` / `rime-sync.ps1`

把 **Rime 用户词典**（`.userdb`，你的输入习惯）通过 Git 在多台设备间同步。

> **只同步用户词典**，不同步配置、皮肤、词库。配置用 `install.sh` 更新。

### 原理

Rime 内置同步机制会把用户词典导出成文本快照：

```
<sync_dir>/<installation_id>/<方案名>.userdb.txt
```

本脚本把 `sync_dir` 当作 Git 仓库来传输快照。**合并由 Rime 自己完成**
（按时间衰减加权，见 `librime` 的 `formula_d`），Git 只负责搬文件。

### 首次设置（每台设备都要做）

**第 1 步：在 `installation.yaml` 里指定 `sync_dir`**

该文件位于 Rime 用户目录：

| 平台 | 路径 |
| --- | --- |
| macOS | `~/Library/Rime/installation.yaml` |
| Windows | `%APPDATA%\Rime\installation.yaml` |
| Linux | `~/.local/share/fcitx5/rime/installation.yaml`（或 `~/.config/ibus/rime/`） |

它由 Rime 首次部署时生成，内容形如：

```yaml
distribution_code_name: Squirrel
installation_id: "a1b2c3d4-..."     # 每台设备必须不同
rime_version: 1.17.0
```

**加一行**（指向你的 Git 仓库，即 `sync_dir`）：

```yaml
sync_dir: /Users/你的名字/rime-sync
```

> ⚠️ **`installation_id` 每台设备必须不同**，否则设备会互相覆盖。
> Rime 会按 `sync_dir/<installation_id>/` 存放各设备的快照。

**第 2 步：初始化仓库**

```bash
./tools/rime-sync.sh --init          # macOS / Linux
```

```powershell
.\tools\rime-sync.ps1 -Init          # Windows
```

它会创建目录、`git init`，并写入：

- `.gitignore` —— 只追踪 `*.userdb.txt` 快照文本，忽略二进制
- `.gitattributes` —— `*.userdb.txt merge=union`，冲突时保留双方

**第 3 步：连远程（建议私有仓库）**

```bash
cd /Users/你的名字/rime-sync
git remote add origin git@github.com:你的用户名/rime-sync.git
git add -A && git commit -m init && git push -u origin main
```

> ⚠️ **务必用私有仓库**：用户词典会暴露你的常用词、人名等隐私。

**第 4 步：其他设备**

```bash
git clone <你的仓库> ~/rime-sync
# 再改该设备的 installation.yaml（installation_id 换一个、sync_dir 指过来）
```

### 日常使用

```bash
./tools/rime-sync.sh                 # 同步：pull → 触发 Rime 同步 → commit & push
./tools/rime-sync.sh --status        # 只看状态
./tools/rime-sync.sh --no-push       # 提交到本地但不推
./tools/rime-sync.sh --push-only     # 不触发 Rime 同步，只提交推送
./tools/rime-sync.sh --dry-run       # 只打印动作
```

```powershell
.\tools\rime-sync.ps1
.\tools\rime-sync.ps1 -Status
.\tools\rime-sync.ps1 -NoPush
.\tools\rime-sync.ps1 -PushOnly
.\tools\rime-sync.ps1 -DryRun
```

### 执行顺序（重要）

```
git pull      → 拿到其他设备的快照
Rime --sync   → Rime 合并所有快照并导出本机快照
git commit/push → 推回去
```

顺序不能反，否则 Rime 读不到别的设备的数据。

### 触发 Rime 同步的方式

| 平台 | 命令 | 备注 |
| --- | --- | --- |
| macOS | `Squirrel --sync` | 通过分布式通知转给运行中的输入法，**需鼠须管在运行** |
| Windows | `WeaselDeployer.exe /sync` | 自动查找安装目录（同 `install.ps1` 的策略） |
| Linux | `rime_dict_manager --sync` | 无头模式，**不需要前端在运行**；需安装 `librime-bin` |

找不到触发工具时，脚本会打印手动操作提示（菜单里的「同步用户数据」），
并**明确区分**「Git 失败」与「Git 成功但未能自动触发 Rime 同步」两种情况。

### 冲突处理

`.gitattributes` 里的 `merge=union` 会让快照文件在冲突时**保留双方的行**——
因为 Rime 会按时间衰减重新计算权重，多出来的行不会造成错误，比人工取舍更安全。

若仍遇到冲突：

```bash
cd <sync_dir>
git status
git checkout --theirs -- '*.userdb.txt'    # 或 --ours
git add -A && git rebase --continue
```

### 重要限制

- **必须手动执行**：Rime 没有定时同步，`--build`（重新部署）也**不会**触发同步
- **Windows 建议用任务计划程序**定时调用 `rime-sync.ps1`；macOS 可用 `launchd`
- **各设备薄荷版本应一致**：万象词库切换后音标格式变过，跨版本同步可能声调显示异常
- **不要与云盘混用**：同一目录同时被云盘和 Git 管理会产生冲突副本

---

## 挑选皮肤：`skin.sh`

### 为什么需要这个脚本

Windows 小狼毫有图形化的「输入法设定」可以勾选皮肤，但 **macOS 鼠须管从上游就没有这个界面**：

- Squirrel 源码里**没有任何 `.xib` / `.storyboard`**，没实现过设置窗口
- 菜单里的 `Settings...` 只是 `openRimeFolder()`——**打开 `~/Library/Rime` 文件夹**，不是设置界面

所以 macOS 上换皮肤只能手写 `squirrel.custom.yaml`。本脚本用命令行提供等价的挑选体验：
列出皮肤（带颜色预览）、输入编号、自动写入配置并重新部署。

> 只用 bash，**不依赖 python / yq / PyYAML**，可在 macOS 自带的 bash 3.2 上运行。

### 用法

```bash
./tools/skin.sh                     # 交互式：列出皮肤 → 输入编号 → 自动应用
./tools/skin.sh --list              # 只列出所有皮肤（带色块预览）
./tools/skin.sh --current           # 显示当前生效的亮色/暗色皮肤
./tools/skin.sh --set mint_dark_green                  # 直接指定亮色
./tools/skin.sh --set mint_dark_green mint_dark_blue   # 亮色 + 暗色
./tools/skin.sh --preview solarized_dark               # 预览单个皮肤
./tools/skin.sh --target ~/Library/Rime                # 指定用户目录
./tools/skin.sh --no-deploy         # 改完不自动部署
./tools/skin.sh --dry-run           # 只打印将写入的内容
./tools/skin.sh --no-color          # 禁用色块（终端不支持真彩色时）
```

### 输出示例

```
*  1) ███ mint_light_blue          蓝水鸭／Mint Light Blue  ← 当前亮色
   2) ███ mint_dark_blue           黑水鸭／Mint Dark Blue   ← 当前暗色
   3) ███ mint_light_green         碧皓青／Mint Light Green
   ...
```

每行三个色块依次是**底色 / 拼音色 / 首选底色**，用 ANSI 真彩色渲染。
标记 `*` 表示当前启用。若不支持 24bit 颜色（或非 TTY），会自动退化为纯文本列表。

### 行为

- **只读** `<用户目录>/squirrel.yaml`（或 `weasel.yaml`）里的预设，**不改动任何原文件**
- 结果写入 `<用户目录>/squirrel.custom.yaml`，用 Rime 的 `patch` 机制覆写
- **保护已有自定义**：会剔除旧的 `color_scheme` 行再追加新值，
  你在同一文件里的 `font_face`、`app_options` 等设置**原样保留**
- 改动前自动备份为 `squirrel.custom.yaml.bak-<时间戳>`
- 若已有 custom 文件且用的是嵌套写法（`style:` 块），也能正确读取当前值

### 说明

- 亮色/暗色分别对应「系统设置 → 外观」的浅色/深色模式
- 皮肤定义来自方案的配置文件，因此安装了新方案后可用皮肤会自动变多
- Windows 用户也可以用本脚本，但小狼毫本身已有图形界面，一般不需要

---

## 发布：`.github/workflows/release.yaml`

推 `v*` 标签即触发：

```bash
git tag v1.0.0
git push origin v1.0.0
```

流水线会执行 `python3 tools/pack.py`，并把 `dist/oh-my-rime.zip` 发布到 Release。
也可在 Actions 页面用 `workflow_dispatch` 手动指定 tag 重发（已有 Release 会走 `gh release upload --clobber` 覆盖）。

发布结束后会统一发送一封结果邮件（`Email workflow result` job），正文含
`needs.release.result`，可区分成功、失败与取消。

### 邮件通知所需配置

在 **Settings → Secrets and variables → Actions** 中配置，缺任意一项会导致通知 job 失败：

| 类型 | 名称 | 示例 / 说明 |
| --- | --- | --- |
| Variable | `SMTP_HOST` | `smtp.gmail.com` |
| Variable | `SMTP_PORT` | `465`（隐式 TLS） |
| Secret | `SMTP_USERNAME` | 完整邮箱地址 |
| Secret | `SMTP_PASSWORD` | 服务商 App Password，**不要用账号主密码** |
| Secret | `SMTP_FROM` | 发件地址，通常与 `SMTP_USERNAME` 一致 |
| Secret | `NOTIFY_EMAIL_TO` | 收件地址，多个用逗号分隔 |

用 Gmail 发信需先开启两步验证并创建 App Password。`GITHUB_TOKEN` 由 Actions 自动注入，无需配置。

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
- PowerShell 脚本里**不要用 `$Args` 作为参数名**——那是 PowerShell 的自动变量，
  会导致实参被吞掉（`rime-sync.ps1` 早期版本踩过这个坑，已改为 `$CmdArgs`）。
- 写 `.gitignore` / `.gitattributes` 时**必须用无 BOM 的 UTF-8**。
  PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写入 BOM，导致首行规则失效；
  脚本已改用 `[System.IO.File]::WriteAllText` + `UTF8Encoding($false)`。
- **`.ps1` 文件必须带 UTF-8 BOM**。Windows PowerShell 5.1 在**没有 BOM 时**
  会按系统 ANSI 代码页（中文系统为 GBK）读取脚本，导致中文注释/字符串变乱码、
  引号被吞、报 `字符串缺少终止符`/`MissingExpressionAfterToken` 之类的语法错误。
  用 UTF-8 BOM 写入即可解决：
  ```bash
  printf '\xef\xbb\xbf' | cat - script.ps1 > tmp && mv tmp script.ps1
  ```
  注意这与 `.gitignore` / `.gitattributes` **相反**——那些文件绝不能带 BOM。
  两者冲突的根源：PS 5.1 需要 BOM 才能正确判定编码，而 `irm` 会把 BOM
  当普通字符传给 `iex`，所以 Windows 的推荐用法是**落盘后用 `-File` 执行**。
- 解析 YAML 时，**不要用 `case "$line" in [[:space:]]*\#*)` 判断注释行**——
  它会连"值后带行尾注释"的数据行（如 `back_color: 0xefefef  # 底色`）一起跳过。
  `skin.sh` 早期版本因此漏掉全部颜色字段。正确做法是先剥掉前导空白，
  再判断是否以 `#` 开头。
- 生成 ANSI 转义序列用 `printf`，**不要用 `$'...'` 与变量拼接**。
  后者在变量穿插时引号极易被拆错，导致 `\033` 原样输出而非解释为 ESC。
