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
# Git 状态探测
# ---------------------------------------------------------------------------
# 运行原生命令并原样输出 stdout/stderr，返回退出码。
#
# 为什么需要它：Windows PowerShell 5.1 会把原生命令写到 stderr 的内容
# 包装成 ErrorRecord；当 $ErrorActionPreference = 'Stop' 时会直接抛
# NativeCommandError 终止脚本。而 git 的进度信息（如 pull 的
# "From https://..."）正常就写到 stderr，于是出现"git : From ..."这种
# 假报错。PS 7.2+ 才改掉这个行为。
#
# 解决办法：临时把 ErrorActionPreference 降为 Continue，并显式读取
# 退出码。这样 stderr 只当作普通输出打印，不影响流程。
function Invoke-Git {
    param([string[]] $CmdArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @CmdArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

# 静默版：只关心退出码，不要输出（用于探测性命令）
function Invoke-GitQuiet {
    param([string[]] $CmdArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @CmdArgs 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-GitIdentity {
    # 首次 commit 需要 user.name / user.email；Git for Windows 装完通常没配。
    $name = (git config --get user.name 2>$null)
    $mail = (git config --get user.email 2>$null)
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($mail)) {
        return $false
    }
    return $true
}

function Test-UnbornBranch {
    # 真：仓库已有 .git，但当前分支还没有任何提交
    $null = git -C $Repo rev-parse --verify HEAD 2>$null
    return ($LASTEXITCODE -ne 0)
}

function Test-HasStagedChanges {
    # 真：暂存区里已有 add 但未 commit 的内容
    $rc = Invoke-GitQuiet @('-C', $Repo, 'diff', '--cached', '--quiet')
    return ($rc -ne 0)
}

function Assert-GitIdentity {
    if (Test-GitIdentity) { return $true }
    Write-Err 'Git 尚未配置提交身份，无法创建提交'
    Write-Host '    请先执行（把值换成你自己的）：'
    Write-Host '        git config --global user.name  "你的名字"'
    Write-Host '        git config --global user.email "你的邮箱"'
    Write-Host '    然后重新运行本脚本。'
    return $false
}

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

    # WeaselDeployer 用 WeaselDeployerExclusiveMutex 保证单实例：
    # 只要已有一个实例在运行（例如开着「方案选单设定」窗口），
    # 新进程会直接以退出码 1 静默退出，不写日志、不产生任何文件。
    $busy = @(Get-Process -Name 'WeaselDeployer' -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) {
        Write-Warn "已有 WeaselDeployer 进程在运行（PID: $($busy.Id -join ', ')）"
        Write-Host '    它会占用互斥锁，导致本次同步被静默拒绝。'
        Write-Host '    请关闭已打开的「小狼毫」设置窗口后重试。'
        Write-Host '    若确认没有窗口，可先结束残留进程：'
        Write-Host '        taskkill /f /im WeaselDeployer.exe'
        return $false
    }

    # 不能用 Start-Process -ArgumentList：它会给参数加字面引号，
    # 使进程收到 ""/sync"" 而非 /sync。而 WeaselDeployer 用
    # wcscmp(L"/sync", lpCmdLine) 做【完全相等】比较，带引号就不匹配，
    # 于是落到最后的 configurator.Run()，弹出「方案选单设定」窗口而非同步。
    # 直接用 ProcessStartInfo 精确控制命令行，等价于手动执行。
    $started = $false
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $deployer
        $psi.Arguments = '/sync'
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $started = $true
    } catch {
        Write-Warn "无法启动 WeaselDeployer: $($_.Exception.Message)"
    }

    if (-not $started) {
        Write-Host '    可手动操作：在 CMD 里执行'
        Write-Host "        `"$deployer`" /sync"
        return $false
    }

    if (-not $proc.WaitForExit(60000)) {
        Write-Info '同步进程仍在后台运行'
        return $true
    }

    if ($proc.ExitCode -ne 0) {
        Write-Warn "WeaselDeployer 返回退出码 $($proc.ExitCode)"
        # 退出码 1 常见于：另一个 WeaselDeployer 实例在运行（占用了
        # WeaselDeployerExclusiveMutex），此时它会静默退出、不写日志。
        $others = Get-Process -Name 'WeaselDeployer' -ErrorAction SilentlyContinue
        if ($others) {
            Write-Host '    检测到仍有 WeaselDeployer 进程在运行（可能是已打开的设置窗口）：'
            $others | ForEach-Object { Write-Host "        进程 $($_.Id)" }
            Write-Host '    请关闭所有 WeaselDeployer 窗口后重试，或手动执行：'
        } else {
            Write-Host '    可查看日志：'
        }
        Write-Host "        `"$deployer`" /sync"
        Write-Host "        dir `"$env:TEMP\rime.weasel`""
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
    Write-Host ''

    # 首次提交需要 Git 身份；Git for Windows 装完通常没配，是最常见的踩坑点。
    if (-not (Test-GitIdentity)) {
        Write-Warn '检测到 Git 还没配置提交身份，上一步的 git commit 会失败'
        Write-Host '    请先执行（把值换成你自己的）：'
        Write-Host '        git config --global user.name  "你的名字"'
        Write-Host '        git config --global user.email "你的邮箱"'
    }
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

    $hasRemote = (Invoke-GitQuiet @('-C', $Repo, 'remote', 'get-url', 'origin')) -eq 0

    if (-not $hasRemote) {
        Write-Info '未配置 origin，跳过 pull'
        return $true
    }

    # 空分支（还没有任何提交）时 git pull 会直接报
    # "Updating an unborn branch with changes added to the index"，
    # 且此时 pull 本身没有意义——没有本地历史可 rebase。跳过即可。
    if (Test-UnbornBranch) {
        Write-Info '当前分支还没有首次提交，跳过 pull'
        Write-Host '    （首次提交后，后续运行才会真正拉取其他设备的快照）'
        return $true
    }

    $rc = Invoke-Git @('-C', $Repo, 'pull', '--rebase', '--autostash')
    if ($rc -ne 0) {
        Write-Warn 'git pull 失败'
        Write-Host '    若是冲突，处理建议：'
        Write-Host "      cd $Repo"
        Write-Host '      git status                              # 看冲突文件'
        Write-Host "      git checkout --theirs -- '*.userdb.txt' # 或 --ours"
        Write-Host '      git add -A; git rebase --continue'
        Write-Host '    若是远程仓库为空/无跟踪分支，可先完成首次提交再重试。'
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

    # 空分支 + 暂存区已有内容时，git 会拒绝 pull/rebase；
    # 这里先把已有暂存内容提交掉，避免留下"半初始化"状态。
    if (Test-UnbornBranch) {
        Write-Info '当前分支还没有首次提交，先完成首次提交'
    }

    if (-not (Assert-GitIdentity)) { return $false }

    Write-Step '提交快照'
    $addRc = Invoke-GitQuiet @('-C', $Repo, 'add', '-A')
    if ($addRc -ne 0) {
        Write-Warn 'git add 失败'
        return $false
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $commitRc = Invoke-GitQuiet @('-C', $Repo, 'commit', '-q', '-m', "sync: $env:COMPUTERNAME $stamp")
    if ($commitRc -ne 0) {
        Write-Warn "git commit 失败（退出码 $commitRc）"
        Write-Host "      cd $Repo; git status   ## 查看原因"
        return $false
    }
    Write-Info '已提交'

    if ($NoPush) {
        Write-Info '按 -NoPush 保留在本地'
        return $true
    }

    $hasRemote = (Invoke-GitQuiet @('-C', $Repo, 'remote', 'get-url', 'origin')) -eq 0

    if (-not $hasRemote) {
        Write-Info '未配置 origin，已提交到本地'
        return $true
    }

    Write-Step '推送到远程'

    # 判断当前分支是否已设置上游（首次 push 时没有）
    $hasUpstream = (Invoke-GitQuiet @('-C', $Repo, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')) -eq 0

    if ($hasUpstream) {
        $null = Invoke-Git @('-C', $Repo, 'push', '-q')
    } else {
        # 远程已有内容（例如另一台设备先推过）时，--set-upstream 会因历史
        # 无关被拒。先尝试 rebase 合并，再设置上游推送。
        $branch = (& git -C $Repo rev-parse --abbrev-ref HEAD 2>$null)
        Write-Info "首次推送，设置上游 origin/$branch"

        $fetchRc = Invoke-GitQuiet @('-C', $Repo, 'fetch', '-q', 'origin')
        if ($fetchRc -eq 0) {
            if ((Invoke-GitQuiet @('-C', $Repo, 'rev-parse', '--verify', "origin/$branch")) -eq 0) {
                # 远程该分支已存在 -> 先 rebase
                $rc = Invoke-Git @('-C', $Repo, 'rebase', "origin/$branch")
                if ($rc -ne 0) {
                    Write-Warn "与 origin/$branch 合并出现冲突"
                    Write-Host '    处理建议：'
                    Write-Host "      cd $Repo"
                    Write-Host '      git status'
                    Write-Host "      # 快照文件可直接取远端版本：git checkout --theirs -- '*.userdb.txt'"
                    Write-Host '      git add -A; git rebase --continue'
                    Write-Host "      git push -u origin $branch"
                    return $false
                }
            }
        }
        $null = Invoke-Git @('-C', $Repo, 'push', '-q', '--set-upstream', 'origin', $branch)
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'push 失败。若是首次推送且远端已有历史，请手动处理：'
        Write-Host "      cd $Repo"
        Write-Host '      git fetch origin'
        Write-Host '      git rebase origin/main       # 或 git pull --rebase'
        Write-Host '      git push -u origin main'
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
    # 记录同步前的快照文件数，用于事后验证 Rime 是否真的写出了东西。
    # 只检查 WeaselDeployer 的退出码是不够的——它可能被互斥锁挡住
    # 或参数没传对而静默走错分支。
    $beforeCount = 0
    if (Test-Path -LiteralPath $Repo) {
        $beforeCount = @(Get-ChildItem -LiteralPath $Repo -Recurse -File -ErrorAction SilentlyContinue).Count
    }

    if (-not (Invoke-RimeSync)) { $rimeSynced = $false }

    if ($rimeSynced -and (Test-Path -LiteralPath $Repo)) {
        $afterFiles = @(Get-ChildItem -LiteralPath $Repo -Recurse -File -ErrorAction SilentlyContinue)
        $afterCount = $afterFiles.Count
        $delta = $afterCount - $beforeCount
        if ($delta -gt 0) {
            Write-Info "同步产生 $delta 个新文件"
        } else {
            # 文件数没变：可能是没有新数据（正常），也可能是同步根本没跑起来
            $ownDir = Join-Path $Repo $installId
            if (Test-Path -LiteralPath $ownDir) {
                $snap = @(Get-ChildItem -LiteralPath $ownDir -Filter '*.userdb.txt' -ErrorAction SilentlyContinue)
                if ($snap.Count -gt 0) {
                    Write-Info "快照已就绪（$($snap.Count) 个 userdb 快照），本次无新增"
                } else {
                    Write-Warn "同步目录存在但没有 .userdb.txt 快照"
                    Write-Host "    可能是本机还没有产生用户词典数据（需正常打字并被记录）"
                }
            } else {
                Write-Warn "Rime 没有在同步目录下创建本机快照目录："
                Write-Host "        $ownDir"
                Write-Host '    → 说明同步未真正执行。常见原因：'
                Write-Host '      • 有其它 WeaselDeployer 窗口占用了互斥锁'
                Write-Host "      • 手动验证：`"$(Find-WeaselDeployer)`" /sync"
                $rimeSynced = $false
            }
        }
    }
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
