<#
.SYNOPSIS
  oh-my-rime 安装 / 更新 / 卸载脚本 (Windows / 小狼毫 Weasel)

.DESCRIPTION
  基于 release 包内的 manifest.txt 工作：
    - 安装/更新：按清单复制文件，保留你的 *.custom.yaml 与用户词典
    - 卸载：只删除清单里记录的、属于本项目的文件

.EXAMPLE
  # 安装最新版（自动定位 %APPDATA%\Rime）
  .\install.ps1

  # 从本地 zip 安装
  .\install.ps1 -From .\oh-my-rime.zip

  # 安装指定版本
  .\install.ps1 -Version v1.0.0

  # 卸载（保留用户词典与缓存）
  .\install.ps1 -Uninstall

  # 卸载并清空缓存 / 用户词典
  .\install.ps1 -Uninstall -Purge

  # 只看会做什么
  .\install.ps1 -DryRun

.NOTES
  若提示脚本被禁止运行，请先执行：
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  或单次绕过：
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>

[CmdletBinding()]
param(
    # 仓库（改成你自己的）
    [string] $Repo = "xianchoujiduluo/oh-my-rime",

    # Rime 用户目录；默认 %APPDATA%\Rime
    [string] $Target,

    # 从本地 zip 安装
    [string] $From,

    # 指定 release tag，默认 latest
    [string] $Version = "latest",

    # 卸载
    [switch] $Uninstall,

    # 卸载时一并删除 build/ 与用户词典
    [switch] $Purge,

    # 只打印动作
    [switch] $DryRun,

    # 不尝试自动重新部署
    [switch] $NoDeploy,

    # 小狼毫安装目录（含 WeaselDeployer.exe）。仅在自动查找失败时需要
    [string] $WeaselDir
)

$ErrorActionPreference = 'Stop'
$AssetName = 'oh-my-rime.zip'

# 以文件方式运行（powershell -File）时 $MyInvocation.MyCommand.Path 有值；
# 以 `irm ... | iex` 或 scriptblock 方式执行时为空。
# 后者不能调 exit，否则会连带关掉用户当前的 PowerShell 会话。
$script:RunningAsFile = [bool]$MyInvocation.MyCommand.Path

# 终止脚本：文件模式用 exit 传递退出码，表达式模式只中断当前脚本块。
function Stop-Script {
    param([int] $Code = 0)
    if ($script:RunningAsFile) { exit $Code }
    throw [System.OperationCanceledException]::new("oh-my-rime install: 中止（退出码 $Code）")
}

# ---------------------------------------------------------------------------
# 输出helpers
# ---------------------------------------------------------------------------
function Write-Info { param($m) Write-Host "[*] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "[x] $m" -ForegroundColor Red }

function Invoke-Step {
    param([scriptblock] $Action)
    if ($DryRun) {
        Write-Host "    [dry-run] $($Action.ToString().Trim())" -ForegroundColor DarkGray
    } else {
        & $Action
    }
}

# ---------------------------------------------------------------------------
# 定位 Rime 用户目录 / Weasel 工具
# ---------------------------------------------------------------------------
if (-not $Target -or $Target -eq '') {
    # 小狼毫 Weasel 默认位置；非 Windows 平台回退到 HOME
    $baseDir = if ($env:APPDATA) { $env:APPDATA } elseif ($HOME) { $HOME } else { '.' }
    $Target = Join-Path $baseDir 'Rime'
    Write-Info "使用默认 Rime 用户目录: $Target"
} else {
    Write-Info "使用指定目录: $Target"
}

$Target = [System.IO.Path]::GetFullPath($Target)

# 安全检查：拒绝盘符根目录与用户主目录本身
$homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
if ($Target -match '^[A-Za-z]:\\?$' -or ($homeDir -and $Target.TrimEnd('\') -eq $homeDir.TrimEnd('\'))) {
    Write-Err "拒绝操作危险目录: $Target"
    Stop-Script 1
}

function Find-WeaselDeployer {
    # 依次尝试：显式 -WeaselDir → 注册表（安装程序自己就用这两个键）→ 常见默认目录
    # → 递归兜底 → PATH。返回 WeaselDeployer.exe 的完整路径，找不到则返回 $null。
    $script:DeployerSearchPaths = @()
    $candidates = New-Object System.Collections.Generic.List[string]

    # 0) 显式指定优先
    if ($WeaselDir) {
        if (-not (Test-Path -LiteralPath $WeaselDir)) {
            Write-Err "-WeaselDir 指定的目录不存在: $WeaselDir"
            return $null
        }
        $candidates.Add((Join-Path $WeaselDir 'WeaselDeployer.exe'))
    }

    # 1) 注册表：HKLM\SOFTWARE\Rime\Weasel 的 InstallDir / WeaselRoot
    #    64 位进程读前者，32 位进程会落到 WOW6432Node，两个都查。
    foreach ($regPath in 'HKLM:\SOFTWARE\Rime\Weasel', 'HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel') {
        foreach ($valueName in 'InstallDir', 'WeaselRoot') {
            try {
                $dir = (Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop).$valueName
                if ($dir) { $candidates.Add((Join-Path $dir 'WeaselDeployer.exe')) }
            } catch { }
        }
    }

    # 2) 常见默认位置。注意 32/64 位与 ARM64 下 $env:ProgramFiles 含义不同，
    #    三个变量都收集，去重后再试。
    $progDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) |
                Where-Object { $_ } | Select-Object -Unique
    foreach ($p in $progDirs) {
        $candidates.Add((Join-Path $p 'Rime\WeaselDeployer.exe'))
    }
    # 用户级安装（部分安装器会装到这里）
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Rime\WeaselDeployer.exe'))
    }

    $script:DeployerSearchPaths = $candidates

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }

    # 3) 兜底：在 <ProgramFiles>\Rime 下递归查找，应对自定义子目录
    foreach ($p in $progDirs) {
        $root = Join-Path $p 'Rime'
        if (Test-Path -LiteralPath $root) {
            $exe = Get-ChildItem -LiteralPath $root -Recurse -Filter 'WeaselDeployer.exe' `
                                 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }

    # 4) 最后看 PATH
    $cmd = Get-Command 'WeaselDeployer.exe' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    return $null
}

function Invoke-Redeploy {
    if ($NoDeploy) { return }

    Write-Host ''
    Write-Host '下一步：重新部署（必须做，否则改动不生效）' -ForegroundColor Cyan

    $deployer = Find-WeaselDeployer
    if ($deployer) {
        if ($DryRun) {
            Write-Host "    [dry-run] & `"$deployer`" /deploy"
        } else {
            Write-Info "调用 $deployer /deploy"
            # WeaselDeployer 是 GUI 程序，/deploy 不阻塞；用 Start-Process 等待其退出，
            # 以便报告失败。部分旧版本会立即返回，此时视为已触发。
            $p = Start-Process -FilePath $deployer -ArgumentList '/deploy' -PassThru -ErrorAction SilentlyContinue
            if ($p) {
                if (-not $p.WaitForExit(30000)) {
                    Write-Info '已触发重新部署（部署进程仍在后台运行）'
                } elseif ($p.ExitCode -eq 0) {
                    Write-Info '已触发重新部署'
                } else {
                    Write-Warn "WeaselDeployer 返回退出码 $($p.ExitCode)，可能部署失败；请查看 `$env:TEMP 下的 rime.weasel.* 日志"
                }
            } else {
                Write-Warn '无法启动 WeaselDeployer，请手动重新部署'
            }
        }
    } else {
        Write-Warn '未找到 WeaselDeployer.exe，请手动重新部署：'
        Write-Host '  • 右键任务栏「中」图标 → 重新部署'
        Write-Host '  • 或 开始菜单 → 小狼毫输入法 → 【小狼毫】重新部署'
        Write-Host ''
        Write-Warn '若已安装小狼毫，可用 -WeaselDir 指定它的安装目录，例如：'
        Write-Host '    .\install.ps1 -WeaselDir "C:\Program Files\Rime"'
        Write-Host ''
        Write-Host '已尝试以下位置：'
        foreach ($c in $script:DeployerSearchPaths) { Write-Host "    $c" }
        Write-Host '  也可自行执行（把路径换成实际安装目录）：'
        Write-Host '    & "C:\Program Files\Rime\WeaselDeployer.exe" /deploy'
    }
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    $manifest = Join-Path $Target 'manifest.txt'
    if (-not (Test-Path $manifest)) {
        Write-Err "找不到 $manifest —— 无法确定哪些文件属于本项目。"
        Write-Host '    如果你是从 zip 手动解压的（旧版本不带 manifest.txt），请手动清理，'
        Write-Host '    或先用新版脚本覆盖安装一次后再卸载。'
        Stop-Script 1
    }

    Write-Info "读取清单: $manifest"
    $entries = Get-Content -LiteralPath $manifest -Encoding UTF8
    $removed = 0

    foreach ($rel in $entries) {
        $rel = $rel.Trim()
        if (-not $rel -or $rel -eq 'manifest.txt') { continue }
        if ($rel -match '^[/\\]' -or $rel -match '\.\.') {
            Write-Warn "跳过可疑条目: $rel"; continue
        }
        $full = Join-Path $Target ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Invoke-Step { Remove-Item -LiteralPath $full -Force }
            $removed++
        }
    }

    Invoke-Step { Remove-Item -LiteralPath $manifest -Force }
    Write-Info "已删除 $removed 个文件"

    # 清理空目录
    if (-not $DryRun) {
        Get-ChildItem -LiteralPath $Target -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\build($|\\)' } |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
    }

    if ($Purge) {
        Write-Warn '-Purge: 同时删除 build/ 缓存与用户词典（个人词频将丢失）'
        Invoke-Step { if (Test-Path (Join-Path $Target 'build')) { Remove-Item (Join-Path $Target 'build') -Recurse -Force } }
        Invoke-Step { Get-ChildItem -LiteralPath $Target -Filter '*.userdb*' -ErrorAction SilentlyContinue | Remove-Item -Force }
        Invoke-Step { if (Test-Path (Join-Path $Target 'sync')) { Remove-Item (Join-Path $Target 'sync') -Recurse -Force } }
    } else {
        Write-Info '已保留 build/ 缓存与用户词典；如需一并删除请加 -Purge'
    }

    Write-Info '卸载完成'
    Invoke-Redeploy
}

# ---------------------------------------------------------------------------
# 安装 / 更新
# ---------------------------------------------------------------------------
function Invoke-Install {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ohmrime-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    try {
        $zip = $null

        if ($From) {
            if (-not (Test-Path $From)) { throw "找不到本地压缩包: $From" }
            $zip = (Resolve-Path $From).Path
            Write-Info "使用本地压缩包: $zip"
        } else {
            $url = if ($Version -eq 'latest') {
                "https://github.com/$Repo/releases/latest/download/$AssetName"
            } else {
                "https://github.com/$Repo/releases/download/$Version/$AssetName"
            }
            $zip = Join-Path $tmp $AssetName
            Write-Info "下载: $url"
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        }

        $extract = Join-Path $tmp 'extract'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

        $manifest = Join-Path $extract 'manifest.txt'
        if (-not (Test-Path $manifest)) {
            throw '压缩包内缺少 manifest.txt，可能不是本项目产物'
        }

        New-Item -ItemType Directory -Path $Target -Force | Out-Null

        # --- 备份用户自定义配置 ---
        $backupNames = @('default.custom.yaml', 'squirrel.custom.yaml', 'weasel.custom.yaml',
                         'user.yaml', 'installation.yaml')
        $backupDir = Join-Path $Target ("backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $existing = $backupNames | Where-Object { Test-Path (Join-Path $Target $_) }
        if ($existing.Count -gt 0) {
            Write-Info "备份你的自定义配置到: $backupDir"
            Invoke-Step { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            foreach ($f in $existing) {
                Invoke-Step { Copy-Item (Join-Path $Target $f) -Destination $backupDir -Force }
            }
        }

        # --- 清理上一版安装的文件（避免改名后旧文件残留） ---
        $oldManifest = Join-Path $Target 'manifest.txt'
        if (Test-Path $oldManifest) {
            Write-Info '检测到已安装，执行更新'
            Write-Info '清理旧版本文件...'
            foreach ($rel in (Get-Content -LiteralPath $oldManifest -Encoding UTF8)) {
                $rel = $rel.Trim()
                if (-not $rel -or $rel -match '\.\.' -or $rel -match '^[/\\]') { continue }
                if ($rel -like '*.custom.yaml') { continue }   # 永不删除用户配置
                $full = Join-Path $Target ($rel -replace '/', '\')
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    Invoke-Step { Remove-Item -LiteralPath $full -Force }
                }
            }
            Invoke-Step { Remove-Item -LiteralPath $oldManifest -Force }
        }

        # --- 复制新文件 ---
        Write-Info "安装文件到: $Target"
        Invoke-Step { Copy-Item -LiteralPath (Join-Path $extract 'manifest.txt') -Destination (Join-Path $Target 'manifest.txt') -Force }
        $installed = 0
        foreach ($rel in (Get-Content -LiteralPath $manifest -Encoding UTF8)) {
            $rel = $rel.Trim()
            if (-not $rel) { continue }
            if ($rel -match '\.\.' -or $rel -match '^[/\\]') { throw "清单含非法路径: $rel" }

            $dest = Join-Path $Target ($rel -replace '/', '\')

            if ($rel -like '*.custom.yaml' -and (Test-Path -LiteralPath $dest)) {
                Write-Info "跳过已有自定义配置: $rel"
                continue
            }

            $destDir = Split-Path -Parent $dest
            Invoke-Step { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Invoke-Step { Copy-Item -LiteralPath (Join-Path $extract ($rel -replace '/', '\')) -Destination $dest -Force }
            $installed++
        }

        Write-Info "共安装 $installed 个文件（另含清单 manifest.txt，供卸载使用）"
        Write-Info '安装完成'
        Invoke-Redeploy
    }
    finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
if ($Uninstall) { Invoke-Uninstall } else { Invoke-Install }
