<#
    把 DSHInstaller.ps1 + deepseek.ico 打包成单文件 exe。

    只用 .NET Framework 自带的 csc.exe（C# 5）编译，不需要装任何 SDK / 模块 / 联网。

    用法：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-exe.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-exe.ps1 -AsInvoker
#>
[CmdletBinding()]
param(
    # 默认请求管理员权限（安装器需要提权装 Chocolatey）；
    # 加 -AsInvoker 则改由脚本自己按需提权（未提权也能打开界面）。
    [switch]$AsInvoker,
    [string]$OutputName = 'DSH安装器.exe'
)

$ErrorActionPreference = 'Stop'

$BuildDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = Split-Path -Parent $BuildDir
$ScriptPath = Join-Path $RootDir 'DSHInstaller.ps1'
$IconPath = Join-Path $RootDir 'deepseek.ico'
$LauncherPath = Join-Path $BuildDir 'Launcher.cs'
$ManifestPath = Join-Path $BuildDir 'app.manifest'
$OutputPath = Join-Path $RootDir $OutputName

Write-Host '=== 打包 DSH 安装器为 exe ===' -ForegroundColor Cyan

# --- 1. 检查输入 ---
foreach ($f in @($ScriptPath, $IconPath, $LauncherPath)) {
    if (-not (Test-Path $f)) { throw "缺少文件：$f" }
}
$scriptBytes = [System.IO.File]::ReadAllBytes($ScriptPath)
$hasBom = ($scriptBytes.Length -ge 3 -and $scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF)
if (-not $hasBom) {
    Write-Host '警告：DSHInstaller.ps1 缺少 UTF-8 BOM，Windows PowerShell 5.1 会按 ANSI 读取，中文会乱码。' -ForegroundColor Yellow
    Write-Host '      正在自动补上 BOM ...' -ForegroundColor Yellow
    $text = [System.IO.File]::ReadAllText($ScriptPath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($ScriptPath, $text, (New-Object System.Text.UTF8Encoding($true)))
}
Write-Host ("脚本 : {0} ({1:N0} 字节)" -f $ScriptPath, (Get-Item $ScriptPath).Length)
Write-Host ("图标 : {0} ({1:N0} 字节)" -f $IconPath, (Get-Item $IconPath).Length)

# --- 2. 找编译器 ---
$csc = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    throw '找不到 csc.exe（.NET Framework 4.x 自带）。请确认系统已安装 .NET Framework 4.0 以上版本。'
}
Write-Host ("编译器: {0}" -f $csc)

# --- 3. 生成应用程序清单 ---
$level = if ($AsInvoker) { 'asInvoker' } else { 'requireAdministrator' }
$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity type="win32" name="DeepSeekHarness.Installer" version="1.0.0.0" processorArchitecture="*" />
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <requestedExecutionLevel level="$level" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{e2011457-1546-43c5-a5fe-008deee3d3f0}" />
      <supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}" />
      <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}" />
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}" />
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}" />
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </windowsSettings>
  </application>
</assembly>
"@
[System.IO.File]::WriteAllText($ManifestPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("清单 : {0}（{1}）" -f $ManifestPath, $level)

# --- 4. 编译 ---
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

$cscArgs = @(
    '/nologo'
    '/target:winexe'
    '/platform:anycpu'
    '/optimize+'
    '/codepage:65001'
    ('/out:' + $OutputPath)
    ('/win32icon:' + $IconPath)
    ('/win32manifest:' + $ManifestPath)
    ('/resource:' + $ScriptPath + ',DSHInstaller.ps1')
    ('/resource:' + $IconPath + ',deepseek.ico')
    $LauncherPath
)

Write-Host ''
& $csc @cscArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputPath)) {
    throw ("编译失败，csc 退出码 " + $LASTEXITCODE)
}

# --- 5. 校验产物 ---
$outBytes = [System.IO.File]::ReadAllBytes($OutputPath)
$size = $outBytes.Length
Write-Host ''
Write-Host '=== 打包完成 ===' -ForegroundColor Green
Write-Host ("输出 : {0}" -f $OutputPath)
Write-Host ("大小 : {0:N0} 字节（{1:N2} MB）" -f $size, ($size / 1MB))

$info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($OutputPath)
Write-Host ("版本 : {0} / {1}" -f $info.ProductName, $info.FileVersion)

# 清单是否真的嵌进去了
$ascii = [System.Text.Encoding]::ASCII.GetString($outBytes)
$manifestOk = $ascii.Contains($level) -and $ascii.Contains('requestedExecutionLevel')
Write-Host ("清单 : " + $(if ($manifestOk) { "已嵌入（$level）" } else { '未找到，请检查' }))

# 嵌入资源是否都在
$resources = @('DSHInstaller.ps1', 'deepseek.ico')
foreach ($r in $resources) {
    $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($r)
    $found = $false
    for ($i = 0; $i -le $outBytes.Length - $nameBytes.Length; $i++) {
        if ($outBytes[$i] -eq $nameBytes[0]) {
            $ok = $true
            for ($j = 1; $j -lt $nameBytes.Length; $j++) {
                if ($outBytes[$i + $j] -ne $nameBytes[$j]) { $ok = $false; break }
            }
            if ($ok) { $found = $true; break }
        }
    }
    Write-Host ("资源 : {0} {1}" -f $r, $(if ($found) { '已嵌入' } else { '未找到' }))
}

if (-not $manifestOk) { exit 1 }
Write-Host ''
Write-Host '自检命令： .\DSH安装器.exe -SelfTest' -ForegroundColor Cyan
