#Requires -Version 5.1
<#
    DeepSeek Harness 一键安装器（WPF GUI）

    流程：
      1. 环境检测  : choco / git / node / npm / pnpm
      2. 缺失修复  : 优先安装 Chocolatey，再用 choco 安装其它缺失环境
                     （每一步都在“全新的 PowerShell 进程”中执行，并从注册表重新读取 PATH，
                       否则刚装好的环境变量在当前进程里是看不到的）
      3. 选择目录  : 可选桌面快捷方式 / 自定义图标
      4. 安装      : git clone -> pnpm install -> pnpm run build
      5. 收尾      : 生成启动 .bat、生成带图标的桌面快捷方式

    说明：本脚本自身只使用 Windows 自带的 .NET / WPF，无需任何第三方依赖。
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,   # 自检模式：不显示窗口，只做语法/XAML/环境/产物的检查
    [switch]$Elevated    # 已由本脚本自行提权重启过（防止无限提权循环）
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 0. 常量 & 运行环境
# ---------------------------------------------------------------------------
$Script:Root      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Script:SelfPath  = Join-Path $Script:Root 'DSHInstaller.ps1'
$Script:RepoUrl   = 'https://github.com/deepseek-ai/deepseek-harness.git'
$Script:RepoName  = 'deepseek-harness'
$Script:WebUrl    = 'http://127.0.0.1:3080'
$Script:FishUrl   = 'https://platform.deepseek.com/usage'
$Script:Work      = Join-Path $env:TEMP ('dsh-installer-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$Script:IconSrc   = Join-Path $Script:Root 'deepseek.ico'
$Script:BatName   = '启动DSH-Web.bat'
$Script:LnkName   = 'DeepSeek Harness Web.lnk'
$Script:MinFreeGB = 6

$Script:PSExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $Script:PSExe)) { $Script:PSExe = 'powershell.exe' }

$Script:IsAdmin = $false
try {
    $Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# 1. 基础工具函数
# ---------------------------------------------------------------------------
function Write-Utf8File {
    param([string]$Path, [string]$Text, [switch]$NoBom)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding(-not $NoBom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Brush {
    param([string]$Hex)
    return ([System.Windows.Media.BrushConverter]::new()).ConvertFromString($Hex)
}

function Ctl {
    param([string]$Name)
    $c = $Script:Win.FindName($Name)
    if ($null -eq $c) { throw "界面元素不存在: $Name" }
    return $c
}

function Get-FixedDrives {
    $list = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -eq [System.IO.DriveType]::Fixed -and $d.IsReady) {
                $list += [pscustomobject]@{ Root = $d.Name; FreeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1) }
            }
        }
    } catch { }
    return $list
}

function Get-DefaultInstallDir {
    $drives = Get-FixedDrives
    if (-not $drives -or $drives.Count -eq 0) { return (Join-Path $env:SystemDrive 'DSH') }
    # 优先选非系统盘且剩余空间最大的盘；否则用系统盘
    $others = @($drives | Where-Object { $_.Root -ne $env:SystemDrive + '\' })
    $pick = $null
    if ($others.Count -gt 0) { $pick = ($others | Sort-Object FreeGB -Descending)[0] }
    else { $pick = ($drives | Sort-Object FreeGB -Descending)[0] }
    return (Join-Path $pick.Root 'DSH')
}

# ---------------------------------------------------------------------------
# 2. 子进程：每个步骤都在“新的 PowerShell”里跑，并刷新 PATH
# ---------------------------------------------------------------------------
$Script:Prologue = @'
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$ConfirmPreference     = 'None'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
$env:GIT_TERMINAL_PROMPT = '0'

# >>> 关键：从注册表重新读取 PATH，否则新装的程序在本进程里找不到 <<<
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
$allPath     = @()
if ($machinePath) { $allPath += $machinePath }
if ($userPath)    { $allPath += $userPath }
$env:Path = ($allPath -join ';')

function Info([string]$m) { Write-Host ('>> ' + $m) }
function Warn([string]$m) { Write-Host ('!! ' + $m) }
function Resolve-Tool {
    param([string[]]$Names, [string[]]$Fallbacks)
    foreach ($n in $Names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    if ($Fallbacks) {
        foreach ($f in $Fallbacks) { if ($f -and (Test-Path $f)) { return $f } }
    }
    return $null
}
$ChocoExe = Resolve-Tool -Names @('choco.exe') -Fallbacks @('C:\ProgramData\chocolatey\bin\choco.exe')
'@

function New-ChildScript {
    param([string]$Name, [string]$Body)
    if (-not (Test-Path $Script:Work)) { New-Item -ItemType Directory -Path $Script:Work -Force | Out-Null }
    $path = Join-Path $Script:Work ($Name + '.ps1')
    # 结尾写入 .status 作为“成功完成”的标记：脚本中途 exit 1 时不会执行到这一行
    $epilogue = @'

try {
    $DshStatusFile = [System.IO.Path]::ChangeExtension($PSCommandPath, '.status')
    [System.IO.File]::WriteAllText($DshStatusFile, '0', (New-Object System.Text.UTF8Encoding($false)))
} catch { }
'@
    Write-Utf8File -Path $path -Text ($Script:Prologue + "`r`n" + $Body + "`r`n" + $epilogue)
    return $path
}

# 同步执行（用于环境探测，速度快、不需要实时日志）
function Invoke-ChildSync {
    param([string]$ScriptPath, [int]$TimeoutSec = 120)
    $spArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'))
    $p = Start-Process -FilePath $Script:PSExe -ArgumentList $spArgs -WindowStyle Hidden -PassThru `
                       -RedirectStandardOutput (Join-Path $Script:Work 'sync.out') `
                       -RedirectStandardError  (Join-Path $Script:Work 'sync.err') `
                       -WorkingDirectory $Script:Work
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { & taskkill /T /F /PID $p.Id 2>&1 | Out-Null } catch { }
        return ''
    }
    $o = ''
    foreach ($f in @('sync.out', 'sync.err')) {
        $fp = Join-Path $Script:Work $f
        if (Test-Path $fp) { $o += (Get-Content -Path $fp -Raw -Encoding UTF8) }
    }
    return $o
}

# ---------------------------------------------------------------------------
# 3. 环境探测
# ---------------------------------------------------------------------------
$Script:EnvDefs = @(
    [pscustomobject]@{ Key = 'choco'; Name = 'Chocolatey';  Desc = 'Windows 包管理器，用于自动安装下面缺失的环境' }
    [pscustomobject]@{ Key = 'git';   Name = 'Git';         Desc = '用于克隆 deepseek-harness 源码' }
    [pscustomobject]@{ Key = 'node';  Name = 'Node.js';     Desc = '运行时，要求 22.19 以上或 24 以上' }
    [pscustomobject]@{ Key = 'npm';   Name = 'npm';         Desc = 'Node 包管理器（随 Node.js 一起安装）' }
    [pscustomobject]@{ Key = 'pnpm';  Name = 'pnpm';        Desc = 'DSH 工作区使用的包管理器与构建工具' }
)

function Get-EnvironmentReport {
    $jsonPath = Join-Path $Script:Work 'env.json'
    $body = @'
$targets = @(
    @{ key = 'choco'; cands = @('choco.exe');          arg = '--version'; fallback = 'C:\ProgramData\chocolatey\bin\choco.exe' },
    @{ key = 'git';   cands = @('git.exe');            arg = '--version'; fallback = "$env:ProgramFiles\Git\cmd\git.exe" },
    @{ key = 'node';  cands = @('node.exe');           arg = '-v';        fallback = "$env:ProgramFiles\nodejs\node.exe" },
    @{ key = 'npm';   cands = @('npm.cmd','npm.exe');  arg = '-v';        fallback = '' },
    @{ key = 'pnpm';  cands = @('pnpm.cmd','pnpm.exe');arg = '-v';        fallback = '' }
)
$result = [ordered]@{}
foreach ($t in $targets) {
    $path = $null
    foreach ($c in $t.cands) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { $path = $cmd.Source; break }
    }
    if (-not $path -and $t.fallback -and (Test-Path $t.fallback)) { $path = $t.fallback }
    if (-not $path) {
        $result[$t.key] = [ordered]@{ ok = $false; version = ''; path = '' }
        continue
    }
    $ver = ''
    try {
        $ver = (& $path $t.arg 2>&1 | Out-String).Trim()
        $ver = ($ver -split "`r?`n")[0]
        if ($ver.Length -gt 120) { $ver = $ver.Substring(0, 120) }
    } catch { $ver = '' }
    $result[$t.key] = [ordered]@{ ok = $true; version = $ver; path = $path }
}
$json = $result | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText('__JSON__', $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'detect done'
'@
    $body = $body.Replace('__JSON__', $jsonPath)
    $script = New-ChildScript -Name 'detect' -Body $body
    Invoke-ChildSync -ScriptPath $script -TimeoutSec 180 | Out-Null
    if (-not (Test-Path $jsonPath)) { return $null }
    try { return (Get-Content -Path $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# 判断 node 版本是否满足 DSH 要求： ^22.19.0 || >=24.0.0
function Test-NodeVersion {
    param([string]$VersionText)
    if ([string]::IsNullOrWhiteSpace($VersionText)) { return @{ Ok = $false; Reason = '无法获取版本号' } }
    $m = [regex]::Match($VersionText, '(\d+)\.(\d+)\.(\d+)')
    if (-not $m.Success) { return @{ Ok = $false; Reason = '无法解析版本号' } }
    $major = [int]$m.Groups[1].Value
    $minor = [int]$m.Groups[2].Value
    if ($major -eq 22 -and $minor -ge 19) { return @{ Ok = $true; Reason = '' } }
    if ($major -ge 24) { return @{ Ok = $true; Reason = '' } }
    return @{ Ok = $false; Reason = ("当前 v$major.$minor，需要 22.19+ 或 24+" ) }
}

function Set-EnvRow {
    param([string]$Key, [string]$State, [string]$Detail)
    $map = @{
        'pending' = @('#FF2A3040', '#FFB9C2D4', '等待检测')
        'ok'      = @('#FF123A2C', '#FF3FD69B', '已安装')
        'missing' = @('#FF3A1D22', '#FFFF6B6B', '缺失')
        'warn'    = @('#FF3A2E15', '#FFF5B547', '需升级')
        'busy'    = @('#FF1B2A45', '#FF7A93FF', '处理中')
    }
    $s = $map[$State]
    if (-not $s) { $s = $map['pending'] }
    $badge = Ctl ("Env_${Key}_Badge")
    $text = Ctl ("Env_${Key}_Text")
    $ver = Ctl ("Env_${Key}_Ver")
    $badge.Background = Brush $s[0]
    $text.Foreground = Brush $s[1]
    $text.Text = $s[2]
    if ($Detail) { $ver.Text = $Detail } else { $ver.Text = '' }
}

# 用探测结果刷新界面，返回需要修复的项
function Update-EnvPage {
    param($Report)
    $need = New-Object System.Collections.ArrayList
    if ($null -eq $Report) {
        foreach ($d in $Script:EnvDefs) { Set-EnvRow -Key $d.Key -State 'missing' -Detail '检测失败，请点击“重新检测”' ; [void]$need.Add($d.Key) }
        $Script:NeedFix = @($need)
        (Ctl 'EnvSub').Text = '环境检测失败：无法启动检测进程。'
        return $Script:NeedFix
    }
    foreach ($d in $Script:EnvDefs) {
        $item = $Report.($d.Key)
        $ok = $false; $ver = ''; $path = ''
        if ($item) { $ok = [bool]$item.ok; $ver = [string]$item.version; $path = [string]$item.path }
        if ($d.Key -eq 'node' -and $ok) {
            $t = Test-NodeVersion -VersionText $ver
            if ($t.Ok) { Set-EnvRow -Key 'node' -State 'ok' -Detail ("$ver    $path") }
            else {
                Set-EnvRow -Key 'node' -State 'warn' -Detail ($ver + '  ' + $t.Reason)
                [void]$need.Add('node')
            }
            continue
        }
        if ($d.Key -eq 'npm' -and $ok) { Set-EnvRow -Key 'npm' -State 'ok' -Detail ("v$ver    随 Node.js 提供"); continue }
        if ($ok) { Set-EnvRow -Key $d.Key -State 'ok' -Detail ("$ver    $path") }
        else {
            Set-EnvRow -Key $d.Key -State 'missing' -Detail '未检测到'
            [void]$need.Add($d.Key)
        }
    }
    # node 缺失时 npm 必然缺失，避免重复提示
    if ($need -contains 'node' -and $need -contains 'npm') { $need.Remove('npm') }
    $Script:NeedFix = @($need)
    $names = @()
    foreach ($k in $Script:NeedFix) { $names += ($Script:EnvDefs | Where-Object { $_.Key -eq $k }).Name }
    if ($Script:NeedFix.Count -eq 0) {
        (Ctl 'EnvSub').Text = '环境检查通过，可以继续安装。'
    } else {
        (Ctl 'EnvSub').Text = ('发现 ' + $Script:NeedFix.Count + ' 项需要处理：' + ($names -join '、'))
    }
    return $Script:NeedFix
}

# ---------------------------------------------------------------------------
# 4. 日志：读取子进程输出文件并显示
# ---------------------------------------------------------------------------
function Strip-Ansi {
    param([string]$Text)
    return [regex]::Replace($Text, "`e\[[0-9;?]*[a-zA-Z]", '')
}

function Get-ProgressKey {
    param([string]$Line)
    $m = [regex]::Match($Line, '^\s*(Receiving objects|Resolving deltas|Counting objects|Compressing objects|Enumerating objects|Updating files|Checking out files|remote: Counting objects|remote: Compressing objects|remote: Enumerating objects|Progress: resolved|Downloading|Resolving|Fetching)\b')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Add-LogLine {
    param([string]$Line)
    $tb = Ctl('Log')
    if ($tb.Text.Length -gt 240000) {
        $tb.Text = $tb.Text.Substring(120000)
        $Script:LastStart = $tb.Text.Length
        $Script:LastKey = $null
    }
    $key = Get-ProgressKey -Line $Line
    # 同类进度行只保留最新一条，避免刷屏
    if ($key -and $key -eq $Script:LastKey -and $Script:LastStart -ge 0 -and $Script:LastStart -le $tb.Text.Length) {
        $tb.Text = $tb.Text.Substring(0, $Script:LastStart)
    } else {
        $Script:LastStart = $tb.Text.Length
    }
    $Script:LastKey = $key
    $tb.AppendText($Line + "`r`n")
    $tb.ScrollToEnd()
}

function Add-LogText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $t = Strip-Ansi -Text $Text
    $t = $t.Replace("`r`n", "`n").Replace("`r", "`n")
    foreach ($line in $t.Split("`n")) {
        if ($line.Trim().Length -eq 0) { continue }
        Add-LogLine -Line $line.TrimEnd()
    }
}

function Read-ChildOutput {
    foreach ($f in @($Script:CurOut, $Script:CurErr)) {
        if (-not $f -or -not (Test-Path $f)) { continue }
        $off = 0
        if ($Script:Offsets.ContainsKey($f)) { $off = $Script:Offsets[$f] }
        try {
            $fs = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        } catch { continue }
        try {
            if ($fs.Length -le $off) { continue }
            $fs.Position = $off
            $len = [int]($fs.Length - $off)
            $buf = New-Object byte[] $len
            $read = $fs.Read($buf, 0, $len)
            # 回退可能被截断的多字节 UTF-8 序列
            $cut = $read
            for ($k = 1; $k -le 3 -and $k -le $read; $k++) {
                $b = $buf[$read - $k]
                if ($b -lt 0x80) { break }
                if ($b -ge 0xC0) {
                    $needBytes = if ($b -ge 0xF0) { 4 } elseif ($b -ge 0xE0) { 3 } else { 2 }
                    if ($k -lt $needBytes) { $cut = $read - $k }
                    break
                }
            }
            $Script:Offsets[$f] = $off + $cut
            if ($cut -gt 0) { Add-LogText -Text ([System.Text.Encoding]::UTF8.GetString($buf, 0, $cut)) }
        } catch {
        } finally { $fs.Dispose() }
    }
}

function Clear-Log {
    $tb = Ctl('Log')
    $tb.Text = ''
    $Script:LastKey = $null
    $Script:LastStart = 0
}

# ---------------------------------------------------------------------------
# 5. 任务引擎（环境修复 / 安装 都复用它）
# ---------------------------------------------------------------------------
function Start-Task {
    param(
        [string]$Title,
        [array]$Steps,
        [scriptblock]$OnSuccess,
        [scriptblock]$OnFailure
    )
    if ($Script:TaskRunning) { return }
    $Script:TaskRunning = $true
    $Script:TaskTitle = $Title
    $Script:TaskSteps = $Steps
    $Script:TaskIndex = -1
    $Script:TaskOnSuccess = $OnSuccess
    $Script:TaskOnFailure = $OnFailure
    $Script:Cancelled = $false
    Clear-Log
    Show-Page 3
    (Ctl 'TaskTitle').Text = $Title
    (Ctl 'Prog').Maximum = [Math]::Max($Steps.Count, 1)
    (Ctl 'Prog').Value = 0
    Add-LogLine ("===== " + $Title + " =====")
    Start-NextStep
}

function Start-NextStep {
    $Script:TaskIndex++
    if ($Script:TaskIndex -ge $Script:TaskSteps.Count) {
        $Script:TaskRunning = $false
        (Ctl 'StepLabel').Text = '全部完成'
        $cb = $Script:TaskOnSuccess
        if ($cb) { & $cb }
        return
    }
    $step = $Script:TaskSteps[$Script:TaskIndex]
    (Ctl 'StepLabel').Text = ('步骤 ' + ($Script:TaskIndex + 1) + '/' + $Script:TaskSteps.Count + '：' + $step.Name)
    Add-LogLine ('===== ' + $step.Name + ' =====')
    $path = New-ChildScript -Name ('step-' + $Script:TaskIndex) -Body $step.Body
    $Script:CurOut = Join-Path $Script:Work ('step-' + $Script:TaskIndex + '.out')
    $Script:CurErr = Join-Path $Script:Work ('step-' + $Script:TaskIndex + '.err')
    $Script:CurStatus = [System.IO.Path]::ChangeExtension($path, '.status')
    foreach ($f in @($Script:CurOut, $Script:CurErr, $Script:CurStatus)) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
    $Script:Offsets = @{}
    $Script:LastKey = $null
    $Script:LastStart = 0
    $wd = $Script:Work
    if ($step.WorkDir -and (Test-Path $step.WorkDir)) { $wd = $step.WorkDir }
    $spArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $path + '"'))
    $Script:Proc = Start-Process -FilePath $Script:PSExe -ArgumentList $spArgs -WindowStyle Hidden -PassThru `
                                 -RedirectStandardOutput $Script:CurOut -RedirectStandardError $Script:CurErr `
                                 -WorkingDirectory $wd
}

function Fail-Task {
    param([string]$Message)
    $Script:TaskRunning = $false
    $Script:TaskError = $Message
    Add-LogLine ('!! ' + $Message)
    $cb = $Script:TaskOnFailure
    if ($cb) { & $cb $Message }
}

function Cancel-Task {
    if ($Script:Proc) {
        try { & taskkill /T /F /PID $Script:Proc.Id 2>&1 | Out-Null } catch { }
        $Script:Proc = $null
    }
    $Script:Cancelled = $true
    $Script:TaskRunning = $false
    Add-LogLine '!! 用户取消了当前任务'
}

function On-Tick {
    try {
        if (-not $Script:TaskRunning) { return }
        Read-ChildOutput
        $p = $Script:Proc
        if ($null -eq $p) { return }
        if ($p.HasExited) {
            Read-ChildOutput
            $Script:Proc = $null
            if ($Script:Cancelled) { return }
            # 子脚本正常跑完才会写 .status；中途 exit 1 则不会写 => 判定失败
            if (Test-Path $Script:CurStatus) {
                (Ctl 'Prog').Value = $Script:TaskIndex + 1
                Start-NextStep
            } else {
                Fail-Task -Message ('步骤“' + $Script:TaskSteps[$Script:TaskIndex].Name + '”执行失败，请查看上方日志。')
            }
        }
    } catch {
        Add-LogLine ('!! 内部错误：' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 6. 环境修复步骤（全部在新 PowerShell 进程中执行）
# ---------------------------------------------------------------------------
function Get-RepairSteps {
    param([array]$Need)
    $steps = New-Object System.Collections.ArrayList

    if ($Need -contains 'choco') {
        [void]$steps.Add([pscustomobject]@{ Name = '安装 Chocolatey'; Body = @'
Info '正在下载 Chocolatey 安装脚本…'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$installed = $false
foreach ($url in @('https://community.chocolatey.org/install.ps1', 'https://chocolatey.org/install.ps1')) {
    try {
        Info ('下载 ' + $url)
        $text = (New-Object Net.WebClient).DownloadString($url)
        Info '执行安装脚本…'
        Invoke-Expression $text
        $installed = $true
        break
    } catch {
        Warn ('失败：' + $_.Exception.Message)
    }
}
if (Test-Path 'C:\ProgramData\chocolatey\bin\choco.exe') {
    Info 'Chocolatey 已安装：'
    & 'C:\ProgramData\chocolatey\bin\choco.exe' --version
} elseif ($installed) {
    Info '安装脚本执行完毕，但未找到 choco.exe，稍后重新检测确认。'
} else {
    Warn 'Chocolatey 安装失败：请检查网络或代理设置。'
    exit 1
}
'@ })
    }

    if ($Need -contains 'git') {
        [void]$steps.Add([pscustomobject]@{ Name = '使用 Chocolatey 安装 Git'; Body = @'
if (-not $ChocoExe) { Warn '未找到 choco.exe'; exit 1 }
Info 'choco install git -y --no-progress'
& $ChocoExe install git -y --no-progress
if ($LASTEXITCODE -ne 0) { Warn ('choco 退出码 ' + $LASTEXITCODE); exit 1 }
Info 'Git 安装完成'
'@ })
    }

    if ($Need -contains 'node' -or $Need -contains 'npm') {
        [void]$steps.Add([pscustomobject]@{ Name = '使用 Chocolatey 安装 / 升级 Node.js'; Body = @'
if (-not $ChocoExe) { Warn '未找到 choco.exe'; exit 1 }
$hasNode = $null -ne (Get-Command node.exe -ErrorAction SilentlyContinue)
if ($hasNode) {
    Info '检测到已有 Node.js，尝试升级到 LTS 版本…'
    & $ChocoExe upgrade nodejs-lts -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        Warn ('choco upgrade 退出码 ' + $LASTEXITCODE + '，尝试直接安装…')
        & $ChocoExe install nodejs-lts -y --no-progress
    }
} else {
    Info 'choco install nodejs-lts -y --no-progress'
    & $ChocoExe install nodejs-lts -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        Warn 'nodejs-lts 安装失败，尝试 nodejs…'
        & $ChocoExe install nodejs -y --no-progress
    }
}
if ($LASTEXITCODE -ne 0) { Warn ('choco 退出码 ' + $LASTEXITCODE); exit 1 }
$node = Resolve-Tool -Names @('node.exe') -Fallbacks @("$env:ProgramFiles\nodejs\node.exe")
if ($node) { Info ('node 版本：' + (& $node -v)) } else { Warn '未找到 node.exe，请重启后重新检测。' }
'@ })
    }

    if ($Need -contains 'pnpm') {
        [void]$steps.Add([pscustomobject]@{ Name = '安装 pnpm'; Body = @'
$npm = Resolve-Tool -Names @('npm.cmd','npm.exe') -Fallbacks @("$env:ProgramFiles\nodejs\npm.cmd")
if (-not $npm) { Warn '未找到 npm，请先安装 Node.js'; exit 1 }
Info 'npm install -g pnpm@latest'
& $npm install -g pnpm@latest
if ($LASTEXITCODE -ne 0) { Warn ('npm 退出码 ' + $LASTEXITCODE); exit 1 }
$pnpm = Resolve-Tool -Names @('pnpm.cmd','pnpm.exe') -Fallbacks @()
if ($pnpm) { Info ('pnpm 版本：' + (& $pnpm -v)) } else { Info 'pnpm 安装完成（PATH 需在下一步的新进程中刷新）' }
'@ })
    }

    return $steps
}

# ---------------------------------------------------------------------------
# 7. 安装步骤
# ---------------------------------------------------------------------------
function Get-InstallSteps {
    param([string]$Dir, [string]$IconPath)
    $repo = Join-Path $Dir $Script:RepoName
    $steps = New-Object System.Collections.ArrayList

    # --- 准备目录 / 长路径支持 ---
    [void]$steps.Add([pscustomobject]@{ Name = '准备安装目录'; Body = @'
$dir = '__DIR__'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null; Info ('已创建目录 ' + $dir) }
else { Info ('安装目录已存在：' + $dir) }

# DSH 依赖树很深，必须打开 Windows 长路径支持，否则会出现“路径过长”错误
try {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    $cur = (Get-ItemProperty -Path $key -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($cur -ne 1) {
        Set-ItemProperty -Path $key -Name LongPathsEnabled -Value 1 -Type DWord
        Info '已启用 Windows 长路径支持（LongPathsEnabled = 1）'
    } else {
        Info 'Windows 长路径支持已启用'
    }
} catch { Warn ('无法启用长路径支持：' + $_.Exception.Message) }

$git = Resolve-Tool -Names @('git.exe') -Fallbacks @("$env:ProgramFiles\Git\cmd\git.exe")
if ($git) {
    & $git config --system core.longpaths true
    Info 'git core.longpaths = true'
} else { Warn '未找到 git，下一步会失败。' }
'@.Replace('__DIR__', $Dir) })

    # --- 克隆 / 更新 ---
    [void]$steps.Add([pscustomobject]@{ Name = '获取源码（git clone）'; Body = @'
$dir  = '__DIR__'
$repo = '__REPO__'
$git  = Resolve-Tool -Names @('git.exe') -Fallbacks @("$env:ProgramFiles\Git\cmd\git.exe")
if (-not $git) { Warn '未找到 git.exe'; exit 1 }
Set-Location $dir
if (Test-Path (Join-Path $repo '.git')) {
    Info '已存在仓库，执行 git pull --ff-only 更新…'
    & $git -C $repo pull --ff-only
} else {
    if (Test-Path $repo) { Info '目录已存在但不是仓库，先删除…'; Remove-Item $repo -Recurse -Force }
    Info ('git clone ' + '__URL__')
    & $git clone --progress '__URL__' $repo
}
if ($LASTEXITCODE -ne 0) { Warn ('git 退出码 ' + $LASTEXITCODE); exit 1 }
Info '源码就绪'
'@.Replace('__DIR__', $Dir).Replace('__REPO__', $repo).Replace('__URL__', $Script:RepoUrl) })

    # --- 对齐 pnpm 版本 ---
    [void]$steps.Add([pscustomobject]@{ Name = '对齐 pnpm 版本'; Body = @'
$repo = '__REPO__'
$pkg  = Join-Path $repo 'package.json'
$want = ''
if (Test-Path $pkg) {
    try {
        $json = Get-Content $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.packageManager -and $json.packageManager -like 'pnpm@*') { $want = $json.packageManager.Substring(5) }
    } catch { }
}
$pnpm = Resolve-Tool -Names @('pnpm.cmd','pnpm.exe') -Fallbacks @()
$have = ''
if ($pnpm) { try { $have = (& $pnpm -v).Trim() } catch { $have = '' } }
Info ('当前 pnpm: ' + $(if ($have) { $have } else { '未安装' }) + ' / 仓库要求: ' + $(if ($want) { $want } else { '未指定' }))
if ($want -and $have -ne $want) {
    $npm = Resolve-Tool -Names @('npm.cmd','npm.exe') -Fallbacks @("$env:ProgramFiles\nodejs\npm.cmd")
    if (-not $npm) { Warn '未找到 npm，跳过 pnpm 版本对齐。'; exit 0 }
    Info ('npm install -g pnpm@' + $want)
    & $npm install -g ('pnpm@' + $want)
    if ($LASTEXITCODE -ne 0) { Warn ('npm 退出码 ' + $LASTEXITCODE + '，继续使用当前 pnpm。') }
} else {
    Info 'pnpm 版本已符合要求，无需变更。'
}
'@.Replace('__REPO__', $repo) })

    # --- pnpm install ---
    [void]$steps.Add([pscustomobject]@{ Name = '安装依赖（pnpm install）'; Body = @'
$repo = '__REPO__'
Set-Location $repo
$pnpm = Resolve-Tool -Names @('pnpm.cmd','pnpm.exe') -Fallbacks @()
if (-not $pnpm) { Warn '未找到 pnpm'; exit 1 }
Info 'pnpm install（首次安装依赖较多，请耐心等待）'
& $pnpm install
if ($LASTEXITCODE -ne 0) {
    Warn ('pnpm install 退出码 ' + $LASTEXITCODE)
    Warn '若提示 Ignored build scripts，可稍后在仓库目录手动执行 pnpm rebuild'
    exit 1
}
Info '依赖安装完成'
'@.Replace('__REPO__', $repo) })

    # --- pnpm run build ---
    [void]$steps.Add([pscustomobject]@{ Name = '构建（pnpm run build）'; Body = @'
$repo = '__REPO__'
Set-Location $repo
$pnpm = Resolve-Tool -Names @('pnpm.cmd','pnpm.exe') -Fallbacks @()
if (-not $pnpm) { Warn '未找到 pnpm'; exit 1 }
Info 'pnpm run build'
& $pnpm run build
if ($LASTEXITCODE -ne 0) { Warn ('pnpm run build 退出码 ' + $LASTEXITCODE); exit 1 }
Info '构建完成'
'@.Replace('__REPO__', $repo) })

    return $steps
}

# ---------------------------------------------------------------------------
# 8. 收尾：生成 .bat、快捷方式、图标
# ---------------------------------------------------------------------------
function Write-LauncherBat {
    param([string]$Dir)
    $repo  = Join-Path $Dir $Script:RepoName
    $drive = (Split-Path -Qualifier $Dir)
    $bat   = Join-Path $Dir $Script:BatName
    $text = @"
@echo off
chcp 65001 >nul
title DeepSeek Harness Web
echo Starting DeepSeek Harness Web UI ...
echo.
cd /d $drive\
cd /d "$repo"
call pnpm dsh web
echo.
echo [DSH] server stopped.
pause
"@
    Write-Utf8File -Path $bat -Text $text -NoBom
    return $bat
}

function Convert-ImageToIco {
    param([string]$Source, [string]$Target)
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($Source)
    try {
        $size = 256
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList $size, $size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $scale = [Math]::Min($size / $img.Width, $size / $img.Height)
            $w = [int]($img.Width * $scale); $h = [int]($img.Height * $scale)
            $g.DrawImage($img, [int](($size - $w) / 2), [int](($size - $h) / 2), $w, $h)
        } finally { $g.Dispose() }
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $png = $ms.ToArray()
        $ms.Dispose(); $bmp.Dispose()

        $fs = [System.IO.File]::Create($Target)
        $bw = New-Object System.IO.BinaryWriter($fs)
        try {
            $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)  # ICONDIR
            $bw.Write([Byte]0); $bw.Write([Byte]0)      # 256x256
            $bw.Write([Byte]0); $bw.Write([Byte]0)      # 调色板 / 保留
            $bw.Write([UInt16]1); $bw.Write([UInt16]32) # 平面 / 位深
            $bw.Write([UInt32]$png.Length)
            $bw.Write([UInt32]22)                       # 数据偏移 = 6 + 16
            $bw.Write($png)
        } finally { $bw.Dispose(); $fs.Dispose() }
    } finally { $img.Dispose() }
    return $Target
}

function New-Shortcut {
    param([string]$ShortcutPath, [string]$BatPath, [string]$WorkDir, [string]$IconPath)
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($ShortcutPath)
    $lnk.TargetPath = $BatPath
    $lnk.WorkingDirectory = $WorkDir
    $lnk.Description = 'DeepSeek Harness Web UI'
    $lnk.WindowStyle = 1
    if ($IconPath -and (Test-Path $IconPath)) { $lnk.IconLocation = ($IconPath + ',0') }
    $lnk.Save()
    return $ShortcutPath
}

function Get-DesktopPath {
    $d = ''
    try { $d = [Environment]::GetFolderPath('Desktop') } catch { }
    if (-not $d -or -not (Test-Path $d)) {
        $d = Join-Path $env:USERPROFILE 'Desktop'
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    return $d
}

function Complete-Install {
    param([string]$Dir)
    $repo = Join-Path $Dir $Script:RepoName

    # 1) 图标：复制到安装目录，保证快捷方式长期有效
    $icon = ''
    if ($Script:CustomIcon -and (Test-Path $Script:CustomIcon)) { $icon = $Script:CustomIcon }
    elseif ($Script:IconSrc -and (Test-Path $Script:IconSrc)) { $icon = $Script:IconSrc }
    elseif (Test-Path (Join-Path $repo 'deepseek.ico')) { $icon = Join-Path $repo 'deepseek.ico' }
    $iconDest = Join-Path $Dir 'dsh.ico'
    if ($icon) {
        try {
            if ($icon -ne $iconDest) { Copy-Item -Path $icon -Destination $iconDest -Force }
            $icon = $iconDest
            Add-LogLine ('图标：' + $icon)
        } catch { Add-LogLine ('!! 图标复制失败：' + $_.Exception.Message) }
    }

    # 2) 启动 bat
    $bat = Write-LauncherBat -Dir $Dir
    Add-LogLine ('已生成启动脚本：' + $bat)

    # 3) 桌面快捷方式
    $lnkPath = ''
    if ((Ctl 'ChkShortcut').IsChecked) {
        try {
            $lnkPath = New-Shortcut -ShortcutPath (Join-Path (Get-DesktopPath) $Script:LnkName) -BatPath $bat -WorkDir $repo -IconPath $icon
            Add-LogLine ('已创建桌面快捷方式：' + $lnkPath)
        } catch { Add-LogLine ('!! 快捷方式创建失败：' + $_.Exception.Message) }
    }

    # 4) 安装日志
    $log = Join-Path $Dir 'install.log'
    try { Write-Utf8File -Path $log -Text ((Ctl 'Log').Text) } catch { $log = '' }

    $Script:ResultDir = $Dir
    $Script:ResultBat = $bat
    $Script:ResultLnk = $lnkPath
    $Script:ResultRepo = $repo

    (Ctl 'ResIconBox').Background = Brush '#FF123A2C'
    (Ctl 'ResIcon').Text = '✓'
    (Ctl 'ResIcon').Foreground = Brush '#FF3FD69B'
    (Ctl 'ResTitle').Text = '安装完成'
    (Ctl 'ResDesc').Text = 'DeepSeek Harness 已就绪，双击桌面快捷方式或运行启动脚本即可打开 Web 界面。'
    (Ctl 'SumDir').Text = $repo
    (Ctl 'SumBat').Text = $bat
    (Ctl 'SumLink').Text = $(if ($lnkPath) { $lnkPath } else { '未创建（可在下方重新创建）' })
    (Ctl 'SumLog').Text = $(if ($log) { $log } else { '未写入' })
    (Ctl 'SumTip').Text = ('提示：Web UI 默认地址 ' + $Script:WebUrl + '。启动脚本里已写入固定路径，移动安装目录后请重新运行本安装器。')
    (Ctl 'BtnLaunch').Visibility = 'Visible'
    (Ctl 'BtnCopyLink').Visibility = 'Visible'
    (Ctl 'BtnRetry').Visibility = 'Collapsed'
    Show-Page 4

    if ((Ctl 'ChkLaunch').IsChecked) { Start-Installed }
}

function Start-Installed {
    $bat = $Script:ResultBat
    if (-not $bat -or -not (Test-Path $bat)) { return }
    Start-Process -FilePath $bat -WorkingDirectory (Split-Path -Parent $bat)
}

# ---------------------------------------------------------------------------
# 9. 界面 XAML
# ---------------------------------------------------------------------------
function Get-EnvRowsXaml {
    $sb = New-Object System.Text.StringBuilder
    foreach ($d in $Script:EnvDefs) {
        [void]$sb.Append(@"
<Border Background="#FF1A1F2A" CornerRadius="10" Padding="16,8" Margin="0,0,0,5">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <StackPanel Grid.Column="0" VerticalAlignment="Center">
      <TextBlock Text="$($d.Name)" Foreground="#FFE8EDF7" FontWeight="SemiBold" FontSize="13.5"/>
      <TextBlock Text="$($d.Desc)" Foreground="#FF7C8698" FontSize="11" Margin="0,2,0,0" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="Env_$($d.Key)_Ver" Foreground="#FF6B7488" FontSize="11" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <Border x:Name="Env_$($d.Key)_Badge" Grid.Column="1" CornerRadius="10" Background="#FF2A3040" Padding="12,4" VerticalAlignment="Center" MinWidth="84">
      <TextBlock x:Name="Env_$($d.Key)_Text" Text="等待检测" Foreground="#FFB9C2D4" FontSize="12" HorizontalAlignment="Center"/>
    </Border>
  </Grid>
</Border>
"@)
    }
    return $sb.ToString()
}

function Get-MainXaml {
    $rows = Get-EnvRowsXaml
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DeepSeek Harness 安装向导"
        Width="960" Height="712" MinWidth="960" MinHeight="712"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="True"
        FontFamily="Microsoft YaHei UI, Microsoft YaHei, Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Height" Value="38"/>
      <Setter Property="MinWidth" Value="110"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#FF4D6BFE"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Height" Value="38"/>
      <Setter Property="MinWidth" Value="96"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Foreground" Value="#FFC7D0E0"/>
      <Setter Property="Background" Value="#FF1E2430"/>
      <Setter Property="BorderBrush" Value="#FF2C3444"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF28303F"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF161B24"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FishButton" TargetType="Button">
      <Setter Property="Height" Value="38"/>
      <Setter Property="MinWidth" Value="96"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Foreground" Value="#FFF7C15A"/>
      <Setter Property="Background" Value="#FF241E0E"/>
      <Setter Property="BorderBrush" Value="#FF4A3A12"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF33290F"/><Setter TargetName="bd" Property="BorderBrush" Value="#FF6B5518"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF1B160A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CaptionButton" TargetType="Button">
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#FFAEB8CC"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#22FFFFFF"/><Setter Property="Foreground" Value="#FFE8EDF7"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkTextBox" TargetType="TextBox">
      <Setter Property="Background" Value="#FF0F131A"/>
      <Setter Property="Foreground" Value="#FFE8EDF7"/>
      <Setter Property="BorderBrush" Value="#FF2C3444"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush" Value="#FF4D6BFE"/>
      <Setter Property="SelectionBrush" Value="#FF4D6BFE"/>
    </Style>
    <Style x:Key="DarkCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFC7D0E0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,5,0,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="16" Height="16" CornerRadius="4" Background="#FF1E2430" BorderBrush="#FF39425A" BorderThickness="1" VerticalAlignment="Center">
                <TextBlock x:Name="tick" Text="✓" FontSize="11" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="#FF4D6BFE"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#FF4D6BFE"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="Vertical">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb"><Border x:Name="tb" Background="#3DFFFFFF" CornerRadius="4" Margin="2"/></ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter TargetName="PART_Track" Property="Orientation" Value="Horizontal"/>
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Border x:Name="RootCard" Margin="22" CornerRadius="16" Background="#FF11141B" BorderBrush="#FF262C3A" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.55" Color="#FF000000"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="52"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="72"/>
      </Grid.RowDefinitions>

      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" Margin="18,0,0,0" VerticalAlignment="Center">
          <Image x:Name="AppIcon" Width="20" Height="20" Stretch="Uniform"/>
          <TextBlock Text="DeepSeek Harness 安装向导" Foreground="#FFE8EDF7" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="AdminTag" Text="管理员模式" Foreground="#FF3FD69B" FontSize="11" Margin="14,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0">
          <Button x:Name="BtnMin" Content="—" Style="{StaticResource CaptionButton}"/>
          <Button x:Name="BtnClose" Content="✕" Style="{StaticResource CaptionButton}"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="30,2,30,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="62"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border x:Name="Dot1" Width="26" Height="26" CornerRadius="13" Background="#FF4D6BFE">
              <TextBlock x:Name="DotTxt1" Text="1" Foreground="White" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="Lbl1" Text="环境检测" Margin="8,0,0,0" VerticalAlignment="Center" Foreground="#FFE8EDF7"/>
          </StackPanel>
          <Border x:Name="Line1" Width="42" Height="2" Background="#FF262C3A" Margin="14,0" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border x:Name="Dot2" Width="26" Height="26" CornerRadius="13" Background="#FF232936">
              <TextBlock x:Name="DotTxt2" Text="2" Foreground="White" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="Lbl2" Text="安装位置" Margin="8,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7488"/>
          </StackPanel>
          <Border x:Name="Line2" Width="42" Height="2" Background="#FF262C3A" Margin="14,0" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border x:Name="Dot3" Width="26" Height="26" CornerRadius="13" Background="#FF232936">
              <TextBlock x:Name="DotTxt3" Text="3" Foreground="White" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="Lbl3" Text="执行安装" Margin="8,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7488"/>
          </StackPanel>
          <Border x:Name="Line3" Width="42" Height="2" Background="#FF262C3A" Margin="14,0" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border x:Name="Dot4" Width="26" Height="26" CornerRadius="13" Background="#FF232936">
              <TextBlock x:Name="DotTxt4" Text="4" Foreground="White" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="Lbl4" Text="完成" Margin="8,0,0,0" VerticalAlignment="Center" Foreground="#FF6B7488"/>
          </StackPanel>
        </StackPanel>

        <Grid Grid.Row="1">
          <!-- ============ 第 1 步：环境检测 ============ -->
          <Grid x:Name="Page1">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Margin="0,0,0,12">
              <TextBlock Text="环境检测" FontSize="19" FontWeight="Bold" Foreground="#FFE8EDF7"/>
              <TextBlock x:Name="EnvSub" Text="正在检测本机环境…" Foreground="#FF8A93A6" Margin="0,5,0,0" TextWrapping="Wrap"/>
            </StackPanel>
            <Border Grid.Row="1" CornerRadius="12" Background="#FF171B24" BorderBrush="#FF232936" BorderThickness="1" Padding="8">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="EnvList" Margin="4">
                  __ENVROWS__
                </StackPanel>
              </ScrollViewer>
            </Border>
          </Grid>

          <!-- ============ 第 2 步：安装位置 ============ -->
          <Grid x:Name="Page2" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Margin="0,0,0,14">
              <TextBlock Text="选择安装位置" FontSize="20" FontWeight="Bold" Foreground="#FFE8EDF7"/>
              <TextBlock Text="源码与依赖会安装到该目录下的 deepseek-harness 文件夹中，建议使用较短的纯英文路径。" Foreground="#FF8A93A6" Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>

            <Border Grid.Row="1" Background="#FF171B24" CornerRadius="12" BorderBrush="#FF232936" BorderThickness="1" Padding="16" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="安装目录" Foreground="#FF9AA4B8" FontSize="12" Margin="0,0,0,8"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox x:Name="TxtDir" Grid.Column="0" Style="{StaticResource DarkTextBox}"/>
                  <Button x:Name="BtnBrowse" Grid.Column="1" Content="浏览…" Style="{StaticResource GhostButton}" Margin="10,0,0,0"/>
                  <Button x:Name="BtnDefaultDir" Grid.Column="2" Content="默认位置" Style="{StaticResource GhostButton}" Margin="0,0,0,0"/>
                </Grid>
                <TextBlock x:Name="TxtDirInfo" Foreground="#FF7C8698" FontSize="11" Margin="0,10,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>

            <Border Grid.Row="2" Background="#FF171B24" CornerRadius="12" BorderBrush="#FF232936" BorderThickness="1" Padding="16" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="安装选项" Foreground="#FF9AA4B8" FontSize="12" Margin="0,0,0,6"/>
                  <CheckBox x:Name="ChkShortcut" Style="{StaticResource DarkCheck}" Content="在桌面创建快捷方式（带图标）" IsChecked="True"/>
                  <CheckBox x:Name="ChkLaunch" Style="{StaticResource DarkCheck}" Content="安装完成后立即启动 DSH Web"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
                  <Border Width="44" Height="44" CornerRadius="10" Background="#FF0F131A" BorderBrush="#FF2C3444" BorderThickness="1">
                    <Image x:Name="IconPreview" Width="32" Height="32" Stretch="Uniform"/>
                  </Border>
                  <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="快捷方式图标" Foreground="#FF9AA4B8" FontSize="12"/>
                    <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                      <Button x:Name="BtnIcon" Content="导入图标…" Style="{StaticResource GhostButton}" Height="30" MinWidth="88" Padding="12,0"/>
                      <Button x:Name="BtnIconReset" Content="恢复默认" Style="{StaticResource GhostButton}" Height="30" MinWidth="80" Padding="12,0" Margin="0"/>
                    </StackPanel>
                  </StackPanel>
                </StackPanel>
              </Grid>
            </Border>

            <TextBlock x:Name="TxtWarn" Grid.Row="3" Foreground="#FFF5B547" FontSize="11" TextWrapping="Wrap" VerticalAlignment="Top"/>
          </Grid>

          <!-- ============ 第 3 步：执行 ============ -->
          <Grid x:Name="Page3" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Margin="0,0,0,12">
              <TextBlock x:Name="TaskTitle" Text="正在安装" FontSize="20" FontWeight="Bold" Foreground="#FFE8EDF7"/>
              <TextBlock x:Name="StepLabel" Text="" Foreground="#FF8A93A6" Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>
            <ProgressBar x:Name="Prog" Grid.Row="1" Height="8" Minimum="0" Maximum="5" Value="0"
                         Foreground="#FF4D6BFE" Background="#FF232936" BorderThickness="0" Margin="0,0,0,14">
              <ProgressBar.Template>
                <ControlTemplate TargetType="ProgressBar">
                  <Border Background="{TemplateBinding Background}" CornerRadius="4" ClipToBounds="True">
                    <Grid x:Name="PART_Track">
                      <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="4" HorizontalAlignment="Left"/>
                    </Grid>
                  </Border>
                </ControlTemplate>
              </ProgressBar.Template>
            </ProgressBar>
            <Border Grid.Row="2" CornerRadius="12" Background="#FF0B0E13" BorderBrush="#FF232936" BorderThickness="1" Padding="4">
              <TextBox x:Name="Log" IsReadOnly="True" AcceptsReturn="True" AcceptsTab="True"
                       TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                       FontFamily="Consolas, Cascadia Mono, Courier New" FontSize="12"
                       Background="Transparent" Foreground="#FFC8D2E4" BorderThickness="0" Padding="10"/>
            </Border>
          </Grid>

          <!-- ============ 第 4 步：完成 ============ -->
          <Grid x:Name="Page4" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal">
              <Border x:Name="ResIconBox" Width="50" Height="50" CornerRadius="25" Background="#FF123A2C">
                <TextBlock x:Name="ResIcon" Text="✓" FontSize="26" Foreground="#FF3FD69B" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Margin="16,0,0,0" VerticalAlignment="Center" MaxWidth="700">
                <TextBlock x:Name="ResTitle" Text="安装完成" FontSize="20" FontWeight="Bold" Foreground="#FFE8EDF7"/>
                <TextBlock x:Name="ResDesc" Foreground="#FF8A93A6" Margin="0,6,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </StackPanel>
            <Border Grid.Row="1" Margin="0,20,0,0" Background="#FF171B24" CornerRadius="12" BorderBrush="#FF232936" BorderThickness="1" Padding="18">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="96"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="安装位置" Foreground="#FF7C8698" Margin="0,0,0,8"/>
                <TextBlock x:Name="SumDir" Grid.Row="0" Grid.Column="1" Foreground="#FFD7DEEA" Margin="0,0,0,8" TextWrapping="Wrap"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Text="启动脚本" Foreground="#FF7C8698" Margin="0,0,0,8"/>
                <TextBlock x:Name="SumBat" Grid.Row="1" Grid.Column="1" Foreground="#FFD7DEEA" Margin="0,0,0,8" TextWrapping="Wrap"/>
                <TextBlock Grid.Row="2" Grid.Column="0" Text="桌面快捷" Foreground="#FF7C8698" Margin="0,0,0,8"/>
                <TextBlock x:Name="SumLink" Grid.Row="2" Grid.Column="1" Foreground="#FFD7DEEA" Margin="0,0,0,8" TextWrapping="Wrap"/>
                <TextBlock Grid.Row="3" Grid.Column="0" Text="Web 地址" Foreground="#FF7C8698" Margin="0,0,0,8"/>
                <TextBlock Grid.Row="3" Grid.Column="1" Text="http://127.0.0.1:3080" Foreground="#FFD7DEEA" Margin="0,0,0,8"/>
                <TextBlock Grid.Row="4" Grid.Column="0" Text="日志文件" Foreground="#FF7C8698" Margin="0,0,0,8"/>
                <TextBlock x:Name="SumLog" Grid.Row="4" Grid.Column="1" Foreground="#FFD7DEEA" Margin="0,0,0,8" TextWrapping="Wrap"/>
                <TextBlock x:Name="SumTip" Grid.Row="5" Grid.Column="0" Grid.ColumnSpan="2" Foreground="#FF8A93A6" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>
              </Grid>
            </Border>
          </Grid>
        </Grid>
      </Grid>

      <Grid Grid.Row="2" Margin="30,0,30,20">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="FooterHint" Grid.Column="0" VerticalAlignment="Center" Foreground="#FF6B7488" FontSize="11" TextWrapping="Wrap" MaxWidth="440" HorizontalAlignment="Left"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Right">
          <Button x:Name="BtnRecheck"   Content="重新检测"     Style="{StaticResource GhostButton}"   Visibility="Collapsed"/>
          <Button x:Name="BtnFix"       Content="一键修复环境" Style="{StaticResource GhostButton}"   Visibility="Collapsed"/>
          <Button x:Name="BtnBack"      Content="上一步"       Style="{StaticResource GhostButton}"   Visibility="Collapsed"/>
          <Button x:Name="BtnRetry"     Content="返回重试"     Style="{StaticResource GhostButton}"   Visibility="Collapsed"/>
          <Button x:Name="BtnCancel"    Content="取消"         Style="{StaticResource GhostButton}"   Visibility="Collapsed"/>
          <Button x:Name="BtnOpenDir"   Content="打开目录"     Style="{StaticResource GhostButton}"   Visibility="Collapsed"/>
          <Button x:Name="BtnCopyLink"  Content="重建快捷方式" Style="{StaticResource GhostButton}"   Visibility="Collapsed"/>
          <Button x:Name="BtnFish"      Content="购买鱼粮"     Style="{StaticResource FishButton}"    Visibility="Collapsed" ToolTip="打开浏览器访问 https://platform.deepseek.com/usage"/>
          <Button x:Name="BtnLaunch"    Content="启动 DSH Web" Style="{StaticResource PrimaryButton}" Visibility="Collapsed"/>
          <Button x:Name="BtnNext"      Content="下一步"       Style="{StaticResource PrimaryButton}" Visibility="Collapsed" Margin="0"/>
          <Button x:Name="BtnStart"     Content="开始安装"     Style="{StaticResource PrimaryButton}" Visibility="Collapsed" Margin="0"/>
          <Button x:Name="BtnFinish"    Content="完成"         Style="{StaticResource PrimaryButton}" Visibility="Collapsed" Margin="0"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
'@
    return $xaml.Replace('__ENVROWS__', $rows)
}

# ---------------------------------------------------------------------------
# 10. 页面切换 & 交互
# ---------------------------------------------------------------------------
function Show-Page {
    param([int]$Index)
    for ($i = 1; $i -le 4; $i++) {
        if ($i -eq $Index) { (Ctl "Page$i").Visibility = 'Visible' } else { (Ctl "Page$i").Visibility = 'Collapsed' }
    }
    for ($i = 1; $i -le 4; $i++) {
        $dot = Ctl("Dot$i"); $txt = Ctl("DotTxt$i"); $lbl = Ctl("Lbl$i")
        if ($i -lt $Index) {
            $dot.Background = Brush '#FF1F5F49'; $txt.Text = '✓'; $lbl.Foreground = Brush '#FF7FD9B4'
        } elseif ($i -eq $Index) {
            $dot.Background = Brush '#FF4D6BFE'; $txt.Text = "$i"; $lbl.Foreground = Brush '#FFE8EDF7'
        } else {
            $dot.Background = Brush '#FF232936'; $txt.Text = "$i"; $lbl.Foreground = Brush '#FF6B7488'
        }
    }
    for ($i = 1; $i -le 3; $i++) {
        if ($i -lt $Index) { (Ctl "Line$i").Background = Brush '#FF1F5F49' } else { (Ctl "Line$i").Background = Brush '#FF262C3A' }
    }
    $all = @('BtnRecheck', 'BtnFix', 'BtnBack', 'BtnRetry', 'BtnCancel', 'BtnOpenDir', 'BtnCopyLink', 'BtnFish', 'BtnLaunch', 'BtnNext', 'BtnStart', 'BtnFinish')
    foreach ($b in $all) { (Ctl $b).Visibility = 'Collapsed' }
    switch ($Index) {
        1 {
            (Ctl 'BtnRecheck').Visibility = 'Visible'
            if ($Script:NeedFix.Count -gt 0) { (Ctl 'BtnFix').Visibility = 'Visible'; (Ctl 'BtnNext').IsEnabled = $false }
            else { (Ctl 'BtnNext').IsEnabled = $true }
            (Ctl 'BtnNext').Visibility = 'Visible'
            (Ctl 'FooterHint').Text = '环境全部就绪后才能进入下一步；缺失项可点击“一键修复环境”自动安装。'
        }
        2 {
            (Ctl 'BtnBack').Visibility = 'Visible'
            (Ctl 'BtnStart').Visibility = 'Visible'
            (Ctl 'FooterHint').Text = '安装过程需要联网下载依赖，耗时取决于网速，请保持窗口打开。'
        }
        3 {
            (Ctl 'BtnCancel').Visibility = 'Visible'
            (Ctl 'FooterHint').Text = '正在执行，请勿关闭窗口。日志会实时输出。'
        }
        4 {
            (Ctl 'BtnOpenDir').Visibility = 'Visible'
            (Ctl 'BtnCopyLink').Visibility = 'Visible'
            (Ctl 'BtnFish').Visibility = 'Visible'
            (Ctl 'BtnLaunch').Visibility = 'Visible'
            (Ctl 'BtnFinish').Visibility = 'Visible'
            (Ctl 'FooterHint').Text = '可以关闭本窗口，之后通过桌面快捷方式启动。'
        }
    }
}

function Start-Detect {
    (Ctl 'EnvSub').Text = '正在检测本机环境…'
    (Ctl 'BtnRecheck').IsEnabled = $false
    (Ctl 'BtnFix').IsEnabled = $false
    foreach ($d in $Script:EnvDefs) { Set-EnvRow -Key $d.Key -State 'pending' -Detail '检测中…' }
    # 让界面先刷新出来，再执行阻塞式检测
    try { $Script:Win.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ }) } catch { }
    $report = Get-EnvironmentReport
    $need = Update-EnvPage -Report $report
    (Ctl 'BtnRecheck').IsEnabled = $true
    (Ctl 'BtnFix').IsEnabled = ($need.Count -gt 0)
    if ($Script:Page -eq 1) { Show-Page 1 }
}

function Start-Repair {
    $need = $Script:NeedFix
    if (-not $need -or $need.Count -eq 0) { return }
    $steps = Get-RepairSteps -Need $need
    if ($steps.Count -eq 0) { return }
    if (-not $Script:IsAdmin) {
        [System.Windows.MessageBox]::Show('自动安装环境需要管理员权限（Chocolatey 安装软件需要提权）。请右键“以管理员身份运行”后重试。', '需要管理员权限', 'OK', 'Warning') | Out-Null
        return
    }
    $onOk = {
        Start-Detect
        Show-Page 1
        if ($Script:NeedFix.Count -eq 0) { Show-Page 2 }
    }
    $onFail = {
        param($msg)
        [System.Windows.MessageBox]::Show(('环境修复失败：' + $msg + "`r`n`r`n" + '请查看日志，或手动安装后点击 [重新检测]。'), '环境修复失败', 'OK', 'Error') | Out-Null
        Show-Page 1
        Start-Detect
    }
    Start-Task -Title '正在修复运行环境' -Steps $steps -OnSuccess $onOk -OnFailure $onFail
}

function Validate-Dir {
    param([string]$Path)
    $warns = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Path)) { return @{ Ok = $false; Msg = '请填写安装目录'; Warn = @() } }
    if ($Path -notmatch '^[A-Za-z]:\\') { return @{ Ok = $false; Msg = '请填写完整路径，例如 D:\DSH'; Warn = @() } }
    $q = Split-Path -Qualifier $Path
    $root = $q + '\'
    if (-not (Test-Path $root)) { return @{ Ok = $false; Msg = ('盘符不存在：' + $q); Warn = @() } }
    if ($Path -match '[^\x20-\x7E]') { [void]$warns.Add('路径包含中文或特殊字符，个别工具可能出错，建议使用纯英文路径。') }
    try {
        $di = New-Object System.IO.DriveInfo($root)
        $free = [math]::Round($di.AvailableFreeSpace / 1GB, 1)
        if ($free -lt $Script:MinFreeGB) { [void]$warns.Add(('剩余空间仅 ' + $free + ' GB，安装依赖建议至少 ' + $Script:MinFreeGB + ' GB。')) }
    } catch { }
    $repo = Join-Path $Path $Script:RepoName
    if (Test-Path $repo) {
        if (Test-Path (Join-Path $repo '.git')) { [void]$warns.Add('目标目录已存在同名仓库，安装时会执行 git pull 更新。') }
        else { [void]$warns.Add('目标目录已存在 deepseek-harness 文件夹但不是 git 仓库，安装时会先删除它。') }
    }
    return @{ Ok = $true; Msg = ''; Warn = @($warns) }
}

function Refresh-DirInfo {
    $dir = (Ctl 'TxtDir').Text.Trim()
    $v = Validate-Dir -Path $dir
    if (-not $v.Ok) {
        (Ctl 'TxtDirInfo').Foreground = Brush '#FFFF6B6B'
        (Ctl 'TxtDirInfo').Text = $v.Msg
        (Ctl 'TxtWarn').Text = ''
        (Ctl 'BtnStart').IsEnabled = $false
        return
    }
    $q = (Split-Path -Qualifier $dir) + '\'
    $free = ''
    try { $di = New-Object System.IO.DriveInfo($q); $free = [math]::Round($di.AvailableFreeSpace / 1GB, 1) } catch { }
    $repo = Join-Path $dir $Script:RepoName
    (Ctl 'TxtDirInfo').Foreground = Brush '#FF7C8698'
    (Ctl 'TxtDirInfo').Text = ('源码将安装到：' + $repo + '    可用空间：' + $free + ' GB')
    (Ctl 'TxtWarn').Text = ($v.Warn -join "`r`n")
    (Ctl 'BtnStart').IsEnabled = $true
}

function Start-Install {
    $dir = (Ctl 'TxtDir').Text.Trim()
    $v = Validate-Dir -Path $dir
    if (-not $v.Ok) {
        [System.Windows.MessageBox]::Show($v.Msg, '安装目录无效', 'OK', 'Warning') | Out-Null
        return
    }
    $repo = Join-Path $dir $Script:RepoName
    if ((Test-Path $repo) -and (Test-Path (Join-Path $repo '.git'))) {
        $r = [System.Windows.MessageBox]::Show("目标目录已存在仓库：`r`n$repo`r`n`r`n是 = 直接复用并更新（git pull）`r`n否 = 删除后重新克隆`r`n取消 = 返回修改路径", '目录已存在', 'YesNoCancel', 'Question')
        if ($r -eq 'Cancel') { return }
        if ($r -eq 'No') {
            try { Remove-Item $repo -Recurse -Force } catch {
                [System.Windows.MessageBox]::Show('删除失败：' + $_.Exception.Message, '错误', 'OK', 'Error') | Out-Null
                return
            }
        }
    }
    $steps = Get-InstallSteps -Dir $dir -IconPath $Script:CustomIcon
    $onOk = { Complete-Install -Dir $Script:InstallDir }
    $onFail = {
        param($msg)
        (Ctl 'ResIconBox').Background = Brush '#FF3A1D22'
        (Ctl 'ResIcon').Text = '✕'
        (Ctl 'ResIcon').Foreground = Brush '#FFFF6B6B'
        (Ctl 'ResTitle').Text = '安装失败'
        (Ctl 'ResDesc').Text = $msg
        (Ctl 'SumDir').Text = (Join-Path $Script:InstallDir $Script:RepoName)
        (Ctl 'SumBat').Text = '未生成'
        (Ctl 'SumLink').Text = '未生成'
        (Ctl 'SumLog').Text = $Script:Work
        (Ctl 'SumTip').Text = '常见原因：网络中断、代理未配置、磁盘空间不足、pnpm 未安装。修复后可返回上一步重试（已下载的内容会复用）。'
        # 先切页再定制按钮：Show-Page 4 会重置一遍可见性
        Show-Page 4
        (Ctl 'BtnLaunch').Visibility = 'Collapsed'
        (Ctl 'BtnCopyLink').Visibility = 'Collapsed'
        (Ctl 'BtnFish').Visibility = 'Collapsed'
        (Ctl 'BtnRetry').Visibility = 'Visible'
    }
    $Script:InstallDir = $dir
    Start-Task -Title '正在安装 DeepSeek Harness' -Steps $steps -OnSuccess $onOk -OnFailure $onFail
}

function Select-Folder {
    param([string]$Initial)
    # 优先使用 Windows 自带的现代文件夹选择器
    try {
        if (-not ('DshFolderPicker' -as [type])) {
            $code = @'
using System;
using System.Runtime.InteropServices;
public static class DshFolderPicker {
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] private class FileOpenDialogRCW { }
    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);
    public static string Pick(string title, string initial) {
        var dlg = (IFileDialog)new FileOpenDialogRCW();
        uint opts;
        dlg.GetOptions(out opts);
        dlg.SetOptions(opts | 0x00000020u | 0x00000040u | 0x00000800u | 0x00000008u);
        dlg.SetTitle(title);
        dlg.SetOkButtonLabel("选择此文件夹");
        if (!string.IsNullOrEmpty(initial)) {
            try {
                IShellItem item;
                Guid guid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                SHCreateItemFromParsingName(initial, IntPtr.Zero, ref guid, out item);
                dlg.SetFolder(item);
            } catch { }
        }
        int hr = dlg.Show(IntPtr.Zero);
        if (hr != 0) return null;
        IShellItem result;
        dlg.GetResult(out result);
        IntPtr ptr;
        result.GetDisplayName(0x80058000u, out ptr);
        string path = Marshal.PtrToStringUni(ptr);
        Marshal.FreeCoTaskMem(ptr);
        return path;
    }
}
'@
            Add-Type -TypeDefinition $code -ErrorAction Stop
        }
        return [DshFolderPicker]::Pick('选择 DSH 安装目录', $Initial)
    } catch {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择 DSH 安装目录'
        $dlg.ShowNewFolderButton = $true
        if ($Initial -and (Test-Path $Initial)) { $dlg.SelectedPath = $Initial }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return $null
    }
}

# ---------------------------------------------------------------------------
# 11. 界面事件绑定
# ---------------------------------------------------------------------------
function Initialize-Ui {
    $Script:Win = [Windows.Markup.XamlReader]::Parse((Get-MainXaml))
    $Script:Page = 1
    $Script:NeedFix = @()
    $Script:TaskRunning = $false
    $Script:Proc = $null
    $Script:Offsets = @{}
    $Script:LastKey = $null
    $Script:LastStart = 0
    $Script:CustomIcon = ''
    $Script:InstallDir = ''
    $Script:ResultBat = ''
    $Script:ResultLnk = ''
    $Script:ResultDir = ''
    $Script:ResultRepo = ''

    # 窗口图标
    if (Test-Path $Script:IconSrc) {
        try {
            $bmp = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$Script:IconSrc)
            $Script:Win.Icon = $bmp
            (Ctl 'AppIcon').Source = $bmp
            (Ctl 'IconPreview').Source = $bmp
        } catch { }
    }
    if (-not $Script:IsAdmin) { (Ctl 'AdminTag').Text = '非管理员' ; (Ctl 'AdminTag').Foreground = Brush '#FFF5B547' }

    # 拖动 / 最小化 / 关闭
    (Ctl 'TitleBar').Add_MouseLeftButtonDown({ try { $Script:Win.DragMove() } catch { } })
    (Ctl 'BtnMin').Add_Click({ $Script:Win.WindowState = 'Minimized' })
    (Ctl 'BtnClose').Add_Click({ $Script:Win.Close() })
    $Script:Win.Add_Closing({
        param($sender, $e)
        if ($Script:TaskRunning) {
            $r = [System.Windows.MessageBox]::Show('安装任务正在执行，确定要退出吗？未完成的安装需要重新开始。', '确认退出', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $e.Cancel = $true; return }
            Cancel-Task
        }
    })

    # 第 1 步
    (Ctl 'BtnRecheck').Add_Click({ Start-Detect })
    (Ctl 'BtnFix').Add_Click({ Start-Repair })
    (Ctl 'BtnNext').Add_Click({ Show-Page 2; Refresh-DirInfo })
    # 第 2 步
    (Ctl 'BtnBack').Add_Click({ Show-Page 1 })
    (Ctl 'BtnBrowse').Add_Click({
        $cur = (Ctl 'TxtDir').Text.Trim()
        $initial = ''
        try {
            if ($cur -and (Test-Path $cur)) { $initial = $cur }
            elseif ($cur -match '^[A-Za-z]:') { $initial = (Split-Path -Qualifier $cur) + '\' }
        } catch { }
        $p = Select-Folder -Initial $initial
        if ($p) { (Ctl 'TxtDir').Text = $p; Refresh-DirInfo }
    })
    (Ctl 'BtnDefaultDir').Add_Click({ (Ctl 'TxtDir').Text = (Get-DefaultInstallDir); Refresh-DirInfo })
    (Ctl 'TxtDir').Add_TextChanged({ Refresh-DirInfo })
    (Ctl 'BtnIcon').Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = '选择图标文件'
        $dlg.Filter = '图标/图片 (*.ico;*.png;*.jpg;*.jpeg;*.bmp)|*.ico;*.png;*.jpg;*.jpeg;*.bmp|所有文件 (*.*)|*.*'
        if ($dlg.ShowDialog() -eq $true) {
            $src = $dlg.FileName
            try {
                if ([System.IO.Path]::GetExtension($src).ToLower() -eq '.ico') {
                    $Script:CustomIcon = $src
                } else {
                    $dst = Join-Path $Script:Work 'custom-icon.ico'
                    Convert-ImageToIco -Source $src -Target $dst | Out-Null
                    $Script:CustomIcon = $dst
                }
                $bmp = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$Script:CustomIcon)
                (Ctl 'IconPreview').Source = $bmp
            } catch {
                [System.Windows.MessageBox]::Show('图标导入失败：' + $_.Exception.Message, '错误', 'OK', 'Error') | Out-Null
            }
        }
    })
    (Ctl 'BtnIconReset').Add_Click({
        $Script:CustomIcon = ''
        if (Test-Path $Script:IconSrc) {
            try { (Ctl 'IconPreview').Source = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$Script:IconSrc) } catch { }
        }
    })
    (Ctl 'BtnStart').Add_Click({ Start-Install })
    # 第 3 步
    (Ctl 'BtnCancel').Add_Click({
        $r = [System.Windows.MessageBox]::Show('确定取消当前任务吗？', '取消确认', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Cancel-Task; Show-Page 1; (Ctl 'BtnFix').IsEnabled = $true }
    })
    # 第 4 步
    (Ctl 'BtnRetry').Add_Click({ Show-Page 2; Refresh-DirInfo })
    (Ctl 'BtnOpenDir').Add_Click({
        $d = $Script:ResultDir
        if ($d -and (Test-Path $d)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $d + '"') }
    })
    (Ctl 'BtnCopyLink').Add_Click({
        try {
            $icon = Join-Path $Script:ResultDir 'dsh.ico'
            $lnk = New-Shortcut -ShortcutPath (Join-Path (Get-DesktopPath) $Script:LnkName) -BatPath $Script:ResultBat -WorkDir $Script:ResultRepo -IconPath $icon
            $Script:ResultLnk = $lnk
            (Ctl 'SumLink').Text = $lnk
            [System.Windows.MessageBox]::Show('已重新创建桌面快捷方式：' + $lnk, '完成', 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show('创建失败：' + $_.Exception.Message, '错误', 'OK', 'Error') | Out-Null
        }
    })
    (Ctl 'BtnFish').Add_Click({
        try {
            Start-Process -FilePath $Script:FishUrl
        } catch {
            [System.Windows.MessageBox]::Show('打开浏览器失败，请手动访问：' + $Script:FishUrl, '提示', 'OK', 'Warning') | Out-Null
        }
    })
    (Ctl 'BtnLaunch').Add_Click({ Start-Installed })
    (Ctl 'BtnFinish').Add_Click({ $Script:Win.Close() })

    # 定时器：刷新子进程日志
    $Script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:Timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Script:Timer.Add_Tick({ On-Tick })
}

# ---------------------------------------------------------------------------
# 12. 自检模式
# ---------------------------------------------------------------------------
function Invoke-SelfTest {
    Write-Host '=== DSH 安装器自检 ==='
    Write-Host ('PowerShell : ' + $PSVersionTable.PSVersion.ToString())
    Write-Host ('Apartment  : ' + [Threading.Thread]::CurrentThread.GetApartmentState())
    Write-Host ('Root       : ' + $Script:Root)
    Write-Host ('Admin      : ' + $Script:IsAdmin)

    Write-Host ''
    Write-Host '[1/5] 检查图标'
    Write-Host ('  deepseek.ico : ' + (Test-Path $Script:IconSrc))

    Write-Host '[2/5] 解析 XAML'
    $xaml = Get-MainXaml
    $win = $null
    try {
        $win = [Windows.Markup.XamlReader]::Parse($xaml)
        Write-Host '  XAML 解析成功'
    } catch {
        Write-Host ('  XAML 解析失败: ' + $_.Exception.Message)
        return 1
    }
    $needNames = @('Page1', 'Page2', 'Page3', 'Page4', 'TxtDir', 'TxtDirInfo', 'TxtWarn', 'Log', 'Prog', 'StepLabel',
                   'TaskTitle', 'ChkShortcut', 'ChkLaunch', 'IconPreview', 'EnvSub', 'EnvList',
                   'ResIconBox', 'ResIcon', 'ResTitle', 'ResDesc', 'SumDir', 'SumBat', 'SumLink', 'SumLog', 'SumTip',
                   'BtnMin', 'BtnClose', 'BtnRecheck', 'BtnFix', 'BtnNext', 'BtnBack', 'BtnBrowse', 'BtnDefaultDir',
                   'BtnIcon', 'BtnIconReset', 'BtnStart', 'BtnCancel', 'BtnRetry', 'BtnOpenDir', 'BtnCopyLink',
                   'BtnFish', 'BtnLaunch', 'BtnFinish', 'TitleBar', 'FooterHint', 'AdminTag')
    foreach ($d in $Script:EnvDefs) { $needNames += @("Env_$($d.Key)_Badge", "Env_$($d.Key)_Text", "Env_$($d.Key)_Ver") }
    $missing = @()
    foreach ($n in $needNames) { if (-not $win.FindName($n)) { $missing += $n } }
    if ($missing.Count -gt 0) { Write-Host ('  缺少元素: ' + ($missing -join ', ')); return 1 }
    Write-Host ('  界面元素检查通过（' + $needNames.Count + ' 个）')
    Write-Host ('  “购买鱼粮”按钮 -> ' + $win.FindName('BtnFish').ToolTip)

    Write-Host '[3/5] 环境探测'
    New-Item -ItemType Directory -Path $Script:Work -Force | Out-Null
    $report = Get-EnvironmentReport
    if ($null -eq $report) { Write-Host '  探测失败'; return 1 }
    foreach ($d in $Script:EnvDefs) {
        $i = $report.($d.Key)
        Write-Host ('  ' + $d.Name.PadRight(12) + ' ' + $(if ($i.ok) { 'OK  ' } else { 'MISS' }) + ' ' + $i.version + '  ' + $i.path)
    }

    Write-Host '[4/5] 生成启动脚本（临时目录）'
    $tmpDir = Join-Path $Script:Work 'out'
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $bat = Write-LauncherBat -Dir $tmpDir
    Write-Host ('  ' + $bat)
    Get-Content $bat | ForEach-Object { Write-Host ('  | ' + $_) }

    Write-Host '[5/5] 生成快捷方式（临时目录）'
    $lnk = New-Shortcut -ShortcutPath (Join-Path $tmpDir 'test.lnk') -BatPath $bat -WorkDir $tmpDir -IconPath $Script:IconSrc
    Write-Host ('  ' + $lnk + '  exists=' + (Test-Path $lnk))
    $ws = New-Object -ComObject WScript.Shell
    $chk = $ws.CreateShortcut($lnk)
    Write-Host ('  target=' + $chk.TargetPath)
    Write-Host ('  icon  =' + $chk.IconLocation)

    Write-Host ''
    Write-Host '=== 自检通过 ==='
    return 0
}

# ---------------------------------------------------------------------------
# 13. 主入口
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml -ErrorAction SilentlyContinue

if ($SelfTest) {
    exit (Invoke-SelfTest)
}

# 被点源加载时（. .\DSHInstaller.ps1）只注册函数，方便自动化测试
if ($MyInvocation.InvocationName -eq '.') { return }

# 非管理员：自动提权重启（提权后桌面/环境变量才是正确的用户上下文）
if (-not $Script:IsAdmin -and -not $Elevated) {
    try {
        $spArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $Script:SelfPath + '"'), '-Elevated')
        Start-Process -FilePath $Script:PSExe -Verb RunAs -ArgumentList $spArgs | Out-Null
        exit 0
    } catch { }
}

New-Item -ItemType Directory -Path $Script:Work -Force | Out-Null

try {
    Initialize-Ui
    (Ctl 'TxtDir').Text = Get-DefaultInstallDir
    Show-Page 1
    $Script:Timer.Start()
    $Script:Win.Add_ContentRendered({
        Start-Detect
    })
    $Script:Win.ShowDialog() | Out-Null
    $Script:Timer.Stop()
    if ($Script:Proc) { Cancel-Task }
} catch {
    $msg = $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace
    try {
        if ($Script:Work) { Write-Utf8File -Path (Join-Path $Script:Work 'fatal.txt') -Text $msg }
    } catch { }
    [System.Windows.MessageBox]::Show($msg, 'DSH 安装器发生错误', 'OK', 'Error') | Out-Null
    exit 1
}
exit 0
