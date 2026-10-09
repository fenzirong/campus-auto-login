<#
.SYNOPSIS
    把 CampusNetLogin.cs 编译成单文件 CampusNetLogin.exe（WinExe，无控制台窗口）。

.DESCRIPTION
    使用 Windows 自带的 .NET Framework 编译器 csc.exe，无需联网、无需装任何 SDK。
    产物是纯 .NET Framework 4.x 程序，Win10/11 开箱即用。

    -target:winexe 是关键：编译出的程序是 GUI 子系统，双击或由计划任务启动都不会
    弹出黑窗口，真正做到后台静默运行。

.PARAMETER EmbedConfig
    把当前 config.json 内容编译进 exe，生成"单文件"版本（可脱离 config.json 独立运行）。
    注意：内置后改账号密码需要重新编译。exe 的优先级是"外部 config.json 优先，找不到才用内置"，
    所以放一份外部 config.json 仍然可以覆盖内置值。

.PARAMETER IconPath
    可选：给 exe 加图标（.ico）。

.EXAMPLE
    .\build-exe.ps1
.EXAMPLE
    .\build-exe.ps1 -EmbedConfig
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Source2,
    [string]$OutFile,
    [string]$ConfigPath,
    [switch]$EmbedConfig,
    [string]$IconPath
)

$ErrorActionPreference = 'Stop'

# 带 [CmdletBinding()] 时 $PSScriptRoot 在 param() 默认值里是空字符串，目录必须在函数体解析
# $PSScriptRoot 本身已经是目录；只有退回到"脚本文件路径"时才需要取父目录
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Definition }
    if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
    if (-not [string]::IsNullOrEmpty($scriptPath)) { $ScriptDir = Split-Path -Parent $scriptPath }
}
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = (Get-Location).Path }

if ([string]::IsNullOrEmpty($Source))     { $Source     = Join-Path $ScriptDir 'CampusNetLogin.cs' }
if ([string]::IsNullOrEmpty($Source2))    { $Source2    = Join-Path $ScriptDir 'SetupWizard.cs' }
if ([string]::IsNullOrEmpty($OutFile))    { $OutFile    = Join-Path $ScriptDir 'CampusNetLogin.exe' }
if ([string]::IsNullOrEmpty($ConfigPath)) { $ConfigPath = Join-Path $ScriptDir 'config.json' }

function Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Good { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }

# ---------- 1. 找编译器 ----------
$cscCandidates = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $csc) {
    throw '找不到 csc.exe（.NET Framework 4.x 编译器）。请先安装 .NET Framework 4.8：https://dotnet.microsoft.com/download/dotnet-framework/net48'
}
Info ('编译器: {0}' -f $csc)

if (-not (Test-Path -LiteralPath $Source)) { throw "找不到源码：$Source" }

# ---------- 2. 准备源码（必要时注入内置配置） ----------
$srcText = [System.IO.File]::ReadAllText($Source, (New-Object System.Text.UTF8Encoding($false)))

if ($EmbedConfig) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "要 -EmbedConfig 但找不到 $ConfigPath，请先运行 Get-PortalConfig.ps1 与 Set-PortalCredential.ps1。"
    }
    $json = [System.IO.File]::ReadAllText($ConfigPath, (New-Object System.Text.UTF8Encoding($false)))
    # C# 原样字符串（@"..."）里，双引号用两个双引号表示
    $escaped = $json.Replace('"', '""')
    $marker = '__EMBEDDED_CONFIG__'
    if ($srcText.IndexOf($marker) -lt 0) { throw "源码里找不到占位符 $marker" }
    $srcText = $srcText.Replace($marker, $escaped)
    Info ('已注入内置配置（{0} 字节）' -f $json.Length)
} else {
    Warn '未使用 -EmbedConfig：exe 运行时需要同目录的 config.json。'
}

# 统一写成 UTF-8 with BOM 的临时文件，配合 /codepage:65001 双保险，避免中文源码被按 GBK 解析
$tmpCs = Join-Path ([System.IO.Path]::GetTempPath()) ('CampusNetLogin.build.' + [Guid]::NewGuid().ToString('N') + '.cs')
[System.IO.File]::WriteAllText($tmpCs, $srcText, (New-Object System.Text.UTF8Encoding($true)))

try {
    # ---------- 3. 编译 ----------
    $cscArgs = @(
        '/nologo'
        '/target:winexe'
        '/platform:anycpu'
        '/optimize+'
        '/codepage:65001'
        '/reference:System.dll'
        '/reference:System.Core.dll'
        '/reference:System.Security.dll'
        '/reference:System.Web.Extensions.dll'
        '/reference:System.Windows.Forms.dll'
        '/reference:System.Drawing.dll'
        ('/out:' + $OutFile)
    )
    if ($IconPath) {
        if (-not (Test-Path -LiteralPath $IconPath)) { throw "找不到图标文件：$IconPath" }
        $cscArgs += ('/win32icon:' + $IconPath)
    }
    $cscArgs += $tmpCs
    if (Test-Path -LiteralPath $Source2) {
        $cscArgs += $Source2
        Info ('附加源文件: {0}' -f $Source2)
    } else {
        Warn ('未找到 {0}：将编译出不带配置向导的版本（缺少一键安装能力）。' -f $Source2)
    }

    Info '编译中...'
    $output = & $csc @cscArgs 2>&1
    $output | ForEach-Object { Write-Host ('    ' + $_) }

    if ($LASTEXITCODE -ne 0) { throw ('编译失败，csc 退出码 {0}' -f $LASTEXITCODE) }
    if (-not (Test-Path -LiteralPath $OutFile)) { throw '编译返回成功但没有生成 exe。' }
}
finally {
    if (Test-Path -LiteralPath $tmpCs) { Remove-Item -LiteralPath $tmpCs -Force -ErrorAction SilentlyContinue }
}

# ---------- 4. 校验产物 ----------
$fi = Get-Item -LiteralPath $OutFile
Good ('已生成 {0}（{1:N0} 字节）' -f $fi.FullName, $fi.Length)

# 读取 PE 头确认子系统 = 2（Windows GUI），这是"无控制台窗口"的硬证据
try {
    $fs = [System.IO.File]::OpenRead($OutFile)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $peOffset = $br.ReadInt32()
        $fs.Position = $peOffset + 0x5C
        $subsystem = $br.ReadUInt16()      # 2 = GUI, 3 = Console
        $name = switch ($subsystem) {
            2       { 'Windows GUI（无控制台窗口）' }
            3       { 'Console（有黑窗口）' }
            default { "未知($subsystem)" }
        }
        Good ('PE 子系统 = {0}  ->  {1}' -f $subsystem, $name)
        if ($subsystem -ne 2) { Warn '产物不是 GUI 子系统，运行时可能弹出控制台窗口。' }
    }
    finally { $fs.Dispose() }
} catch {
    Warn ('无法校验 PE 子系统：{0}' -f $_.Exception.Message)
}

Write-Host ''
Info '下一步：'
Write-Host ('  1) 自检      : .\{0} --diagnose' -f $fi.Name)
Write-Host ('  2) 看请求体  : .\{0} --dry-run --force' -f $fi.Name)
Write-Host ('  3) 实测一次  : .\{0} --force --once' -f $fi.Name)
Write-Host '  4) 注册开机任务: .\Install-AutoLogin.ps1 -Mode Boot'
