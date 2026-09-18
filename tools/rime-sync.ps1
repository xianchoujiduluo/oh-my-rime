<#
.SYNOPSIS
  Rime 用户词典 Git 同步（Windows / 小狼毫 Weasel）

.DESCRIPTION
  原理：Rime 把用户词典导出成 <sync_dir>\<installation_id>\*.userdb.txt 快照，
        本脚本把这个目录当成 Git 仓库来传输。
        合并由 Rime 自己完成（按时间衰减加权），Git 只负责搬文件。

.EXAMPLE
  # 首次设置（建仓库、写 .gitignore/.gitattributes）
  .\rime-sync.ps1 -Init

  # 同步：pull → 触发 Rime 同步 → commit & push
  .\rime-sync.ps1

  # 只看状态
  .\rime-sync.ps1 -Status

  # 同步到本地但不 push
  .\rime-sync.ps1 -NoPush

  # 不触发 Rime 同步，只提交并推送已有改动
  .\rime-sync.ps1 -PushOnly

  # 手动指定路径
  .\rime-sync.ps1 -Target "$env:APPDATA\Rime" -Repo "D:\rime-sync"

.NOTES
  前置条件：
    1. 在 <Rime 用户目录>\installation.yaml 里设置 sync_dir 指向本 Git 仓库
    2. 每台设备的 installation_id 必须不同
    3. 已安装 Git，且 git 在 PATH 中

  若提示脚本被禁止运行：
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  或单次绕过：
    powershell -ExecutionPolicy Bypass -File .\rime-sync.ps1
#>

[CmdletBinding()]
param(
    # Rime 用户目录；默认 %APPDATA%\Rime
    [string] $Target,

    # Git 仓库目录；默认读 installation.yaml 的 sync_dir
    [string] $Repo,

    # 小狼毫安装目录（含 WeaselDeployer.exe），自动查找失败时用
    [string] $WeaselDir,

    # 首次设置
    [switch] $Init,

    # 只看状态
    [switch] $Status,

    # 不 push
    [switch] $NoPush,

    # 不触发 Rime 同步
    [switch] $PushOnly,

    # 只打印将执行的命令
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 输出 helper
# ---------------------------------------------------------------------------
function Write-Info { param($m) Write-Host "[*] $m" -ForegroundColor Green }
function Write-Step { param($m) Write-Host "[>] $m" -ForegroundColor Cyan }
function Write-Warn { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "[x] $m" -ForegroundColor Red }

# 注意：参数名不能用 $Args —— 那是 PowerShell 的自动变量，会导致实参被吞掉。
function Invoke-Cmd {
    param([string] $Exe, [string[]] $CmdArgs, [string] $WorkDir)
    $shown = "$Exe $($CmdArgs -join ' ')"
    if ($DryRun) {
        Write-Host "    [dry-run] $shown" -ForegroundColor DarkGray
        return 0
    }
    if ($WorkDir) {
        Push-Location $WorkDir
        try { & $Exe @CmdArgs } finally { Pop-Location }
    } else {
        & $Exe @CmdArgs
    }
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# UTF-8 无 BOM 写入
# 注意：PowerShell 5.1 的 Set-Content -Encoding UTF8 会写入 BOM，
# 而 .gitignore / .gitattributes 带 BOM 会让首行规则失效。
# ---------------------------------------------------------------------------
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-GitignoreText {
    return @'
# 只追踪 Rime 导出的快照文本，忽略临时文件与二进制
*.tmp
*.log
.DS_Store
Thumbs.db
desktop.ini
*.userdb
*.userdb/
*.ldb
*.sst
'@
}

function Get-GitattributesText {
    return @'
# 用户词典快照：冲突时保留双方，交给 Rime 合并
*.userdb.txt merge=union
'@
}

# ---------------------------------------------------------------------------
# 检查 git
# ---------------------------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 git，请先安装 Git for Windows 并确保它在 PATH 中'
    exit 1
}

# ---------------------------------------------------------------------------
# 定位 Rime 用户目录
# ---------------------------------------------------------------------------
if (-not $Target) {
    $base = if ($env:APPDATA) { $env:APPDATA } else { $HOME }
    $Target = Join-Path $base 'Rime'
}
$Target = [System.IO.Path]::GetFullPath($Target)
if (-not (Test-Path -LiteralPath $Target)) {
    Write-Err "Rime 用户目录不存在: $Target"
    exit 1
}

$installYaml = Join-Path $Target 'installation.yaml'
if (-not (Test-Path -LiteralPath $installYaml)) {
    Write-Err "找不到 $installYaml"
    Write-Host '    Rime 首次部署后才会生成，请先启动小狼毫并重新部署一次。'
    exit 1
}

# ---------------------------------------------------------------------------
# 从 installation.yaml 读取 sync_dir / installation_id
# 只做简单解析，不引入 YAML 依赖
# ---------------------------------------------------------------------------
function Get-YamlValue {
    param([string] $Key, [string] $File)
    $line = Get-Content -LiteralPath $File -Encoding UTF8 |
            Where-Object { $_ -match "^\s*$Key\s*:" } |
            Select-Object -First 1
    if (-not $line) { return $null }
    $val = ($line -split ':', 2)[1].Trim()
    # 去掉可能的引号
    $val = $val -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
    return $val
}

$syncDir = Get-YamlValue -Key 'sync_dir' -File $installYaml
$installId = Get-YamlValue -Key 'installation_id' -File $installYaml

if (-not $Repo) { $Repo = $syncDir }

if (-not $installId) {
    Write-Err "installation.yaml 里没有 installation_id"
    exit 1
}

Write-Info "Rime 用户目录: $Target"
Write-Info "installation_id: $installId"

if (-not $Repo) {
    Write-Warn 'installation.yaml 里没有设置 sync_dir，且未用 -Repo 指定'
    Write-Host '    请先添加一行（路径按需修改）：'
    Write-Host "        sync_dir: D:\rime-sync"
    Write-Err '缺少 sync_dir'
    exit 1
}

# 展开环境变量（如 %USERPROFILE%）
$Repo = [System.Environment]::ExpandEnvironmentVariables($Repo)
$Repo = [System.IO.Path]::GetFullPath($Repo)
Write-Info "同步仓库: $Repo"

# ---------------------------------------------------------------------------
# 查找 WeaselDeployer.exe（与 install.ps1 相同的策略）
# ---------------------------------------------------------------------------
function Find-WeaselDeployer {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($WeaselDir -and (Test-Path -LiteralPath $WeaselDir)) {
        $candidates.Add((Join-Path $WeaselDir 'WeaselDeployer.exe'))
    }

    foreach ($regPath in 'HKLM:\SOFTWARE\Rime\Weasel', 'HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel') {
        foreach ($valueName in 'InstallDir', 'WeaselRoot') {
            try {
                $dir = (Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop).$valueName
                if ($dir) { $candidates.Add((Join-Path $dir 'WeaselDeployer.exe')) }
            } catch { }
        }
    }

    $progDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) |
                Where-Object { $_ } | Select-Object -Unique
    foreach ($p in $progDirs) {
        $candidates.Add((Join-Path $p 'Rime\WeaselDeployer.exe'))
    }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Rime\WeaselDeployer.exe'))
    }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 触发 Rime 同步
# ---------------------------------------------------------------------------
function Invoke-RimeSync {
    $deployer = Find-WeaselDeployer
    if (-not $deployer) {
        Write-Warn '找不到 WeaselDeployer.exe，无法自动同步'
        Write-Host '    可手动操作：右键托盘「中」图标 → 同步用户数据'
        Write-Host '    或用 -WeaselDir 指定安装目录，例如：'
        Write-Host '        .\rime-sync.ps1 -WeaselDir "C:\Program Files\Rime"'
        return $false
    }

    Write-Step "触发同步: $deployer /sync"
    if ($DryRun) {
        Write-Host "    [dry-run] & `"$deployer`" /sync" -ForegroundColor DarkGray
        return $true
    }

    $p = Start-Process -FilePath $deployer -ArgumentList '/sync' -PassThru -ErrorAction SilentlyContinue
    if (-not $p) {
        Write-Warn '无法启动 WeaselDeployer'
        return $false
    }
    if (-not $p.WaitForExit(60000)) {
        Write-Info '同步进程仍在后台运行'
    } elseif ($p.ExitCode -ne 0) {
        Write-Warn "WeaselDeployer 返回退出码 $($p.ExitCode)"
        Write-Host "    可查看 `$env:TEMP 下的 rime.weasel.* 日志"
        return $false
    }
    # 给文件写入留一点时间，避免紧接着 git add 抓不到新快照
    Start-Sleep -Milliseconds 800
    return $true
}

# ---------------------------------------------------------------------------
# --Init
# ---------------------------------------------------------------------------
function Invoke-Init {
    if (-not (Test-Path -LiteralPath $Repo)) {
        if ($DryRun) { Write-Host "    [dry-run] 创建 $Repo" -ForegroundColor DarkGray }
        else { New-Item -ItemType Directory -Path $Repo -Force | Out-Null }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
        Write-Step '初始化 Git 仓库'
        Invoke-Cmd git @('init', '-q') $Repo | Out-Null
    } else {
        Write-Step '仓库已存在，跳过 git init'
    }

    $gitignore = Join-Path $Repo '.gitignore'
    if (-not (Test-Path -LiteralPath $gitignore)) {
        Write-Step '写入 .gitignore'
        if ($DryRun) {
            Write-Host "    [dry-run] 创建 $gitignore" -ForegroundColor DarkGray
        } else {
            [System.IO.File]::WriteAllText($gitignore, (Get-GitignoreText), $script:Utf8NoBom)
        }
    }

    $gitattrs = Join-Path $Repo '.gitattributes'
    if (-not (Test-Path -LiteralPath $gitattrs)) {
        Write-Step '写入 .gitattributes'
        if ($DryRun) {
            Write-Host "    [dry-run] 创建 $gitattrs" -ForegroundColor DarkGray
        } else {
            [System.IO.File]::WriteAllText($gitattrs, (Get-GitattributesText), $script:Utf8NoBom)
        }
    }

    Write-Info '初始化完成。后续步骤：'
    Write-Host "    1. cd $Repo"
    Write-Host '    2. git remote add origin <你的私有仓库>'
    Write-Host "    3. git add -A; git commit -m 'init'; git push -u origin main"
    Write-Host '    4. 在每台设备上运行 .\rime-sync.ps1'
}

# ---------------------------------------------------------------------------
# --Status
# ---------------------------------------------------------------------------
function Invoke-Status {
    Write-Host '=== Rime 用户词典同步状态 ===' -ForegroundColor White
    Write-Host "  Rime 用户目录   : $Target"
    Write-Host "  installation_id : $installId"
    Write-Host "  sync_dir        : $(if ($syncDir) { $syncDir } else { '（未设置）' })"
    Write-Host "  仓库            : $Repo"
    Write-Host ''

    if (Test-Path -LiteralPath (Join-Path $Repo '.git')) {
        Write-Host 'Git 状态' -ForegroundColor White
        & git -C $Repo status --short --branch
        Write-Host ''
        Write-Host '最近的提交' -ForegroundColor White
        & git -C $Repo log --oneline -5
        Write-Host ''
        Write-Host '远程' -ForegroundColor White
        & git -C $Repo remote -v
    } else {
        Write-Warn "$Repo 不是 Git 仓库，先运行: .\rime-sync.ps1 -Init"
    }

    Write-Host ''
    Write-Host '快照目录' -ForegroundColor White
    $own = Join-Path $Repo $installId
    if (Test-Path -LiteralPath $own) {
        Get-ChildItem -LiteralPath $own | Format-Table Name, Length, LastWriteTime -AutoSize | Out-String | Write-Host
    } else {
        Write-Host "  $own 尚不存在（还没同步过）"
    }

    Write-Host '所有设备的快照' -ForegroundColor White
    Get-ChildItem -LiteralPath $Repo -Recurse -Depth 1 -Filter '*.userdb.txt' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  $($_.FullName.Substring($Repo.Length + 1))" }
}

# ---------------------------------------------------------------------------
# Git 操作
# ---------------------------------------------------------------------------
function Invoke-GitPull {
    Write-Step '拉取其他设备的更新'
    if ($DryRun) {
        Write-Host "    [dry-run] git -C $Repo pull --rebase --autostash" -ForegroundColor DarkGray
        return $true
    }

    $hasRemote = $false
    try {
        git -C $Repo remote get-url origin 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $hasRemote = $true }
    } catch { }

    if (-not $hasRemote) {
        Write-Info '未配置 origin，跳过 pull'
        return $true
    }

    git -C $Repo pull --rebase --autostash 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'git pull 失败（可能有冲突）'
        Write-Host '    处理建议：'
        Write-Host "      cd $Repo"
        Write-Host '      git status                              # 看冲突文件'
        Write-Host "      git checkout --theirs -- '*.userdb.txt' # 或 --ours"
        Write-Host '      git add -A; git rebase --continue'
        return $false
    }
    return $true
}

function Invoke-GitCommitPush {
    if ($DryRun) {
        Write-Host "    [dry-run] git -C $Repo add -A; commit; push" -ForegroundColor DarkGray
        return $true
    }

    $changes = git -C $Repo status --porcelain
    if (-not $changes) {
        Write-Info '无变化，无需提交'
        return $true
    }

    Write-Step '提交快照'
    git -C $Repo add -A
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    git -C $Repo commit -q -m "sync: $env:COMPUTERNAME $stamp"
    Write-Info '已提交'

    if ($NoPush) {
        Write-Info '按 -NoPush 保留在本地'
        return $true
    }

    $hasRemote = $false
    try {
        git -C $Repo remote get-url origin 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $hasRemote = $true }
    } catch { }

    if (-not $hasRemote) {
        Write-Info '未配置 origin，已提交到本地'
        return $true
    }

    Write-Step '推送到远程'
    git -C $Repo push -q 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'push 失败（远程可能有新提交）。请重试本脚本'
        return $false
    }
    Write-Info '已推送'
    return $true
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if ($Init)   { Invoke-Init;   exit 0 }
if ($Status) { Invoke-Status; exit 0 }

if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
    Write-Err "$Repo 不是 Git 仓库。先运行: .\rime-sync.ps1 -Init"
    exit 1
}

$gitOk = $true
$rimeSynced = $true

if (-not (Invoke-GitPull)) { $gitOk = $false }

if (-not $PushOnly) {
    if (-not (Invoke-RimeSync)) { $rimeSynced = $false }
}

if (-not (Invoke-GitCommitPush)) { $gitOk = $false }

Write-Host ''
if (-not $gitOk) {
    Write-Warn 'Git 操作失败，请查看上面的提示'
    exit 1
}

if ($rimeSynced) {
    Write-Info '同步完成'
} else {
    # git 部分已成功，只是没能自动触发 Rime 同步
    Write-Warn 'Git 已同步，但未能自动触发 Rime 同步'
    Write-Host '    → 快照可能是旧的。请手动同步一次：'
    Write-Host '        右键托盘「中」图标 → 同步用户数据'
    Write-Host '    → 然后重新运行本脚本以提交最新快照'
    exit 0
}
