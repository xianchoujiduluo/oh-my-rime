# AGENTS.md

本文件为在本仓库工作的编码代理提供指导。仓库是 **oh-my-rime（薄荷输入法）** —— 一套 Rime 输入法方案与配置模板。

## 项目概览

- **性质**：Rime 输入法配置仓库（YAML 词库/方案 + Lua 插件 + OpenCC 词典），没有编译产物、没有 `package.json`、没有单元测试。
- **上游**：`Mintimate/oh-my-rime`（`origin` 通常是个人 fork）。国内镜像：`https://cnb.cool/Mintimate/rime/oh-my-rime`。
- **文档站**：<https://www.mintimate.cc>（配置覆写、FAQ、语言模型等问题的权威来源）。
- **"构建/测试"的含义**：把文件部署到本地 Rime 用户目录并重新部署。Rime 用户目录：
  - Windows（Weasel）：`%APPDATA%\Rime`
  - macOS（Squirrel）：`~/Library/Rime`；Fcitx5 macOS：`~/.local/share/fcitx5/rime`
  - Linux：ibus `~/.config/ibus/rime`，Fcitx5 `~/.local/share/fcitx5/rime`
  - Android（Fcitx5）：`.../files/data/rime/`
  - 日志：Windows `%TEMP%`，macOS `$TMPDIR`，Linux `/tmp`

改动后需在客户端里「重新部署」并 `Ctrl` + `` ` `` 切换方案验证。仓库内没有可运行的测试命令。

## 仓库结构

| 路径 | 说明 |
| --- | --- |
| `*.schema.yaml` | 输入方案（`rime_mint` 为默认全拼，`double_pinyin*` / `wubi*` / `terra_pinyin` / `radical_pinyin` / `stroke` / `t9` / `melt_eng` 等） |
| `*.dict.yaml`（根目录） | 方案绑定的字典入口，通过 `import_tables` 引用 `dicts/` |
| `dicts/` | 词库。**`rime_mint.*` / `rime_ice.*` 由 GitHub Action 自动更新，不要手工编辑**；自定义词条写入 `dicts/custom_simple.dict.yaml` |
| `lua/` | Lua 插件（processor / translator / filter）；`lua/aux_code/` 为辅助码表 |
| `opencc/` | 简繁、Emoji 等 OpenCC 配置（`.json`）与其词表（`.txt`） |
| `default.yaml` / `squirrel.yaml` / `weasel.yaml` / `ibus_rime.yaml` | 各平台全局配置 |
| `plum/full.recipe.yaml` | plum 全量安装/更新清单。**新增顶层文件后需同步更新此清单**，否则不会被安装 |
| `.github/workflows/` | `release.yaml`（`v*` tag / `workflow_dispatch` 触发，打包并发布 Release，末尾邮件通知）、`mirrorToCNB.yaml`（同步到 CNB）。没有 YAML 校验或测试 CI |
| `.cnb.yml` / `.ide/Dockerfile` | CNB 发布流水线与开发容器 |

## 发布链路与所需凭据

`release.yaml` 需要以下 Actions 配置，缺任意一项会导致对应步骤失败：

| 类型 | 名称 | 用途 |
| --- | --- | --- |
| Variable | `SMTP_HOST` | SMTP 服务器，如 `smtp.gmail.com` |
| Variable | `SMTP_PORT` | SMTP 端口，如 `465`（隐式 TLS） |
| Secret | `SMTP_USERNAME` | SMTP 登录名（通常是完整邮箱） |
| Secret | `SMTP_PASSWORD` | SMTP 密码或 App Password（非账号主密码） |
| Secret | `SMTP_FROM` | 发件地址，通常与 `SMTP_USERNAME` 一致 |
| Secret | `NOTIFY_EMAIL_TO` | 收件地址，多个用逗号分隔 |
| Secret | `CNB_GIT_PASSWORD` | 仅 `mirrorToCNB.yaml` 使用，CNB 推送凭据 |

注意：`GITHUB_TOKEN` 由 Actions 自动注入，无需手动创建。上游仓库的 secrets 不会复制到 fork，需在本 fork 自行配置。

## 关键约定

- **编码**：所有 YAML/TXT 必须为 UTF-8。字典条目为制表符分隔：`词条\t编码\t权重`。
- **词典入口**：新增词库时，先建 `dicts/xxx.dict.yaml`，再在对应 `*.dict.yaml` 的 `import_tables` 中引用，最后确认 `plum/full.recipe.yaml` 的 glob 能覆盖到。
- **Lua 插件**：在 `lua/` 下新增脚本后，脚本返回一个 table（通常 `local M = {} ... return M`）；在方案的 `engine.processors` / `translators` / `filters` 中以 `lua_processor@*name`、`lua_translator@*name`、`lua_filter@*name` 形式引用。`rime.lua` 仅作说明，不是模块注册表。
- **修改默认行为用 `.custom.yaml` 覆写**，不要直接改 `default.yaml` / `squirrel.yaml` / `weasel.yaml` 的默认值（README 与文档站均强调这一点）；`default.yaml` 内的冗余是为兼容 rimetool。
- **`version:` 字段**：方案用 `YY.MM.DD`（如 `"24.11.11"`），词典用 `YYYY.MM.DD` 或 `YYYY-MM-DD`。改动行为时同步更新对应版本号。
- **多语言 README**：`README.md` 与 `README_zh-cn.md` 内容一致（简体），`README_zh-CHT.md`、`README_en.md` 为对应译本；改动简介时保持四者同步。
- **兼容性**：需兼容 Windows 7/XP 上的 Weasel 0.14.3（Lua/新特性受限），修改核心方案时留意。

## 提交规范

历史提交以 Conventional Commits 风格为主，无强制校验：`fix:`, `feat:`, `refactor:`, `perf:`, `chore:`, `docs:`，可带 scope（如 `fix(lua):`、`feat(dict):`）。描述中英文均可。自动更新词库的提交由 `github-actions[bot]` 产生，勿手工制造同类提交。

## 给代理的工作建议

1. 改动前先用 `git log`/`git blame` 了解该文件的维护方式（自动更新文件与手工维护文件处理方式不同）。
2. 编辑 YAML 时保持缩进与现有风格一致（2 空格），不要重排或格式化无关内容——大词库 diff 会掩盖真实改动。
3. 修改方案后**无法在仓库内验证**：清楚说明需要在 Rime 客户端重新部署并切换方案验证，不要声称"已测试通过"。
4. 涉及上游问题（词库内容、纠错词）建议引导到上游仓库或雾凇/万象词库仓库提 issue，而非在本仓库改自动更新文件。
