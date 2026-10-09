<#
.SYNOPSIS
    把校园网账号密码写进 config.json。密码默认用 Windows DPAPI 加密（只有当前用户的当前机器能解），不落明文。

.DESCRIPTION
    - 默认写入 credentials.passwordEnc（DPAPI / CurrentUser），并清空 credentials.password。
    - 使用 -PlainText 才写明文（仅用于「以 SYSTEM 身份在开机未登录时运行」的场景）。
    - DPAPI 密文与「当前用户 + 当前机器」绑定：换机器 / 换用户 / 重装系统后必须重新运行本脚本。

.EXAMPLE
    .\Set-PortalCredential.ps1 -User 20230001
.EXAMPLE
    .\Set-PortalCredential.ps1 -User 20230001 -PlainText
#>
#Requires -Version 3.0
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$User,
    [switch]$PlainText,
    [switch]$Machine,
    [switch]$Show
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

if ([string]::IsNullOrEmpty($ConfigPath)) { $ConfigPath = Join-Path $ScriptDir 'config.json' }

function Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Good { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }

function Read-TextFileAuto {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($bytes)
    } catch {
        return [System.Text.Encoding]::GetEncoding('GB18030').GetString($bytes)
    }
}

function ConvertTo-JsonText {
    param($Object, [int]$Depth = 10)
    $json = $Object | ConvertTo-Json -Depth $Depth
    $json = [regex]::Replace($json, '(?<!\\)\\u([0-9a-fA-F]{4})', {
        param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16)
    })
    return $json
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "找不到 $ConfigPath。请先运行 Get-PortalConfig.ps1 生成配置。"
}

$cfg = (Read-TextFileAuto -Path $ConfigPath) | ConvertFrom-Json

if ($null -eq $cfg.PSObject.Properties['credentials'] -or $null -eq $cfg.credentials) {
    $cfg | Add-Member -NotePropertyName credentials -NotePropertyValue ([pscustomobject]@{ user = ''; password = ''; passwordEnc = ''; passwordEncMachine = '' }) -Force
}

if ($User) {
    $cfg.credentials.user = $User
    Good ('账号已设置：{0}' -f $User)
} elseif (-not $cfg.credentials.user) {
    $u = Read-Host '请输入校园网账号'
    $cfg.credentials.user = $u.Trim()
    Good ('账号已设置：{0}' -f $cfg.credentials.user)
} else {
    Info ('沿用已有账号：{0}（如需修改请加 -User 参数）' -f $cfg.credentials.user)
}

$sec  = Read-Host '请输入校园网密码（输入时不显示）' -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

if ([string]::IsNullOrEmpty($plain)) { throw '密码为空，已取消。' }

# 三个密码字段补齐，便于后续赋值
foreach ($fld in 'password', 'passwordEnc', 'passwordEncMachine') {
    if ($null -eq $cfg.credentials.PSObject.Properties[$fld]) {
        $cfg.credentials | Add-Member -NotePropertyName $fld -NotePropertyValue '' -Force
    }
}

if ($PlainText) {
    Warn '正在写入明文密码。任何能读该文件的账户都能看到它，请务必限制权限：'
    Write-Host ('    icacls "{0}" /inheritance:r /grant:r "SYSTEM:(R)" "Administrators:(R)"' -f $ConfigPath) -ForegroundColor Yellow
    $cfg.credentials.password           = $plain
    $cfg.credentials.passwordEnc        = ''
    $cfg.credentials.passwordEncMachine = ''
} elseif ($Machine) {
    # DPAPI LocalMachine：以 SYSTEM 身份在开机时运行的计划任务可以解密（CurrentUser 密文不行）。
    # 明文编码为 UTF-16LE，与 ConvertFrom-SecureString 的内部格式保持一致，exe 侧解码逻辑通用。
    # 注意：Windows PowerShell 5.1 不会自动加载 ProtectedData 所在的 System.Security，必须显式加载，
    # 否则 [System.Security.Cryptography.ProtectedData] 会报"找不到类型"。
    try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        throw '无法加载 System.Security.Cryptography.ProtectedData。请改用 -PlainText，或改用 -Mode Logon。'
    }
    $blob = [System.Text.Encoding]::Unicode.GetBytes($plain)
    $enc  = [System.Security.Cryptography.ProtectedData]::Protect(
                $blob, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    $hex  = -join ($enc | ForEach-Object { $_.ToString('x2') })
    $cfg.credentials.passwordEncMachine = $hex
    $cfg.credentials.password           = ''
    $cfg.credentials.passwordEnc        = ''
    Good '密码已用 DPAPI LocalMachine 加密写入（SYSTEM 身份可解密，无明文落盘）。'
    Warn 'LocalMachine 密文本机所有用户理论上都能解密，安全性弱于 CurrentUser；仅在需要开机自动认证时使用。'
} else {
    $cfg.credentials.passwordEnc        = ConvertFrom-SecureString $sec
    $cfg.credentials.password           = ''
    $cfg.credentials.passwordEncMachine = ''
    Good '密码已用 DPAPI CurrentUser 加密写入（仅当前用户 + 当前机器可解）。'
}

$plain = $null
$sec   = $null
[System.GC]::Collect()

$json = ConvertTo-JsonText -Object $cfg -Depth 10
# 带 BOM 写出，保证 PS 5.1 里 Get-Content / 记事本打开也能正常显示中文
[System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($true)))
Good ('配置已更新：{0}' -f $ConfigPath)

if ($Show) {
    Write-Host ''
    Info '当前 credentials 段：'
    Write-Host ('    user                = {0}' -f $cfg.credentials.user)
    if ($cfg.credentials.password) { Write-Host '    password            = <明文，已设置>' } else { Write-Host '    password            = <空>' }
    if ($cfg.credentials.passwordEnc) { Write-Host '    passwordEnc         = <DPAPI CurrentUser 密文，已设置>' } else { Write-Host '    passwordEnc         = <空>' }
    if ($cfg.credentials.passwordEncMachine) { Write-Host '    passwordEncMachine  = <DPAPI LocalMachine 密文，已设置>' } else { Write-Host '    passwordEncMachine  = <空>' }
}

Write-Host ''
Info '下一步：.\Test-CampusNetLogin.ps1 先自检，再 .\Install-AutoLogin.ps1 注册开机任务。'
