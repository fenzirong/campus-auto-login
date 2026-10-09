<#
.SYNOPSIS
    注册 Windows 计划任务：每次开机自动运行 CampusNetLogin.exe 完成校园网认证。

.DESCRIPTION
    默认 -Mode Boot：开机后以 SYSTEM 身份运行 CampusNetLogin.exe，无需用户登录 Windows。
    exe 自身的行为（由 config.json 控制）：
      * 在 connectDeadlineSeconds（默认 15）秒预算内完成认证
      * 后台静默运行：WinExe 子系统，无控制台窗口、无弹窗
      * 认证成功后保持 autoExitSeconds（默认 300）秒，然后自动退出

    密码方案（按 Mode 选）：
      * Boot 模式以 SYSTEM 身份运行，无法解密 DPAPI CurrentUser 密文，二选一：
          - 推荐：.\Set-PortalCredential.ps1 -Machine     写入 DPAPI LocalMachine 密文，无明文落盘
          - 备选：.\Set-PortalCredential.ps1 -PlainText   写入明文，必须限制文件权限
      * Logon 模式以当前用户身份运行，可直接用默认的 DPAPI CurrentUser 密文。

    失败重试：任务带 RestartCount/RestartInterval。开机瞬间网络可能还没起来，
    第一次没连上会自动重试，无需人工干预。

.EXAMPLE
    .\Install-AutoLogin.ps1
.EXAMPLE
    .\Install-AutoLogin.ps1 -Mode Logon
.EXAMPLE
    .\Install-AutoLogin.ps1 -KeepAliveMinutes 10
.EXAMPLE
    .\Install-AutoLogin.ps1 -Uninstall
#>
#Requires -Version 3.0
[CmdletBinding()]
param(
    [string]$ScriptDir,
    [string]$TaskName = 'CampusNet-AutoLogin',
    [ValidateSet('Boot', 'Logon')]
    [string]$Mode = 'Boot',
    [int]$BootDelaySeconds = 5,
    [int]$LogonDelaySeconds = 20,
    [int]$KeepAliveMinutes = 0,
    [switch]$Uninstall,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'

# 带 [CmdletBinding()] 时 $PSScriptRoot 在 param() 默认值里是空字符串，目录必须在函数体解析
if ([string]::IsNullOrEmpty($ScriptDir)) {
    # $PSScriptRoot 本身已经是目录；只有退回到"脚本文件路径"时才需要取父目录
    $ScriptDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($ScriptDir)) {
        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Definition }
        if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
        if (-not [string]::IsNullOrEmpty($scriptPath)) { $ScriptDir = Split-Path -Parent $scriptPath }
    }
    if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = (Get-Location).Path }
}

function Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Good { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Uninstall) {
    if (-not $isAdmin) { throw '卸载计划任务需要管理员权限，请用「以管理员身份运行」的 PowerShell 执行。' }
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Good ('已删除计划任务：{0}' -f $TaskName)
    } else {
        Warn ('没有找到名为 {0} 的计划任务。' -f $TaskName)
    }
    exit 0
}

if (-not $isAdmin) {
    throw '注册计划任务需要管理员权限。请右键 PowerShell →「以管理员身份运行」后重新执行本脚本。'
}

$configPath = Join-Path $ScriptDir 'config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "找不到 $configPath，请先运行 Get-PortalConfig.ps1 与 Set-PortalCredential.ps1。"
}

# ---- 选择运行体：优先 exe，其次 PowerShell 脚本 ----
$exePath    = Join-Path $ScriptDir 'CampusNetLogin.exe'
$loginScript = Join-Path $ScriptDir 'CampusNetLogin.ps1'

if (Test-Path -LiteralPath $exePath) {
    $action = New-ScheduledTaskAction -Execute $exePath -WorkingDirectory $ScriptDir
    Info ('运行体：{0}（WinExe，后台静默无窗口）' -f $exePath)
} elseif (Test-Path -LiteralPath $loginScript) {
    Warn '没找到 CampusNetLogin.exe，回退到 PowerShell 版（会有一个隐藏的 powershell.exe 进程）。'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
    $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $loginScript
    $action  = New-ScheduledTaskAction -Execute $psExe -Argument $argLine -WorkingDirectory $ScriptDir
} else {
    throw "既没有 CampusNetLogin.exe 也没有 CampusNetLogin.ps1，目录：$ScriptDir"
}

# ---- 密码方案校验 ----
$cfgText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
$hasMachineEnc = $cfgText -match '"passwordEncMachine"\s*:\s*"[^"]+"'
$hasPlain      = $cfgText -match '"password"\s*:\s*"[^"]+"'
$hasUserEnc    = $cfgText -match '"passwordEnc"\s*:\s*"[^"]+"'

if ($Mode -eq 'Boot') {
    if (-not $hasMachineEnc -and -not $hasPlain) {
        Warn 'Boot 模式以 SYSTEM 身份运行，无法解密 DPAPI CurrentUser 密文。'
        throw '请先执行下列之一，然后重新注册：`n  .\Set-PortalCredential.ps1 -Machine    （推荐，无明文落盘）`n  .\Set-PortalCredential.ps1 -PlainText  （须限制 config.json 权限）'
    }
    if ($hasPlain -and -not $hasMachineEnc) {
        Warn '当前使用明文密码。强烈建议限制配置文件权限：'
        Write-Host ('    icacls "{0}" /inheritance:r /grant:r "SYSTEM:(R)" "Administrators:(R)"' -f $configPath) -ForegroundColor Yellow
    }
    if ($hasMachineEnc) { Good '检测到 passwordEncMachine（DPAPI LocalMachine 密文），SYSTEM 身份可直接解密。' }
} else {
    if (-not $hasUserEnc -and -not $hasPlain) {
        Warn 'Logon 模式以当前用户身份运行，需要 DPAPI CurrentUser 密文或明文密码。'
        throw '请先执行：.\Set-PortalCredential.ps1 -User 你的学号'
    }
}

# ---- 触发器 ----
$triggers = New-Object System.Collections.ArrayList

if ($Mode -eq 'Boot') {
    $t = New-ScheduledTaskTrigger -AtStartup
    try { $t.Delay = ('PT{0}S' -f [Math]::Max(0, $BootDelaySeconds)) } catch { }
    [void]$triggers.Add($t)
    Info ('触发器：开机后 {0} 秒（SYSTEM 身份，无需用户登录）' -f $BootDelaySeconds)
} else {
    $t = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    try { $t.Delay = ('PT{0}S' -f [Math]::Max(0, $LogonDelaySeconds)) } catch { }
    [void]$triggers.Add($t)
    Info ('触发器：用户 {0}\{1} 登录后 {2} 秒' -f $env:USERDOMAIN, $env:USERNAME, $LogonDelaySeconds)
}

if ($KeepAliveMinutes -gt 0) {
    $interval = New-TimeSpan -Minutes $KeepAliveMinutes
    $tRep = $null
    try {
        $tRep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                    -RepetitionInterval $interval -RepetitionDuration ([TimeSpan]::MaxValue)
    } catch {
        $tRep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                    -RepetitionInterval $interval -RepetitionDuration (New-TimeSpan -Days 3650)
    }
    [void]$triggers.Add($tRep)
    Info ('附加触发器：每 {0} 分钟再跑一次（用于中途掉线自愈；exe 每次仍会在保持期结束后自行退出）' -f $KeepAliveMinutes)
} else {
    Info '未启用保活触发器：仅在开机时运行一次。中途掉线不会被自动补认证（如需保活请加 -KeepAliveMinutes 10）。'
}

# ---- 设置 ----
# 失败重试：开机瞬间网络可能尚未就绪，靠这里自动补跑，无需人工干预
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1)

try { $settings.DisallowStartIfOnBatteries = $false } catch { }
try { $settings.WakeToRun = $true } catch { }

# ---- 身份 ----
if ($Mode -eq 'Boot') {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
} else {
    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
                    -LogonType Interactive -RunLevel Highest
}

# ---- 注册 ----
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Info ('已存在同名任务，将覆盖：{0}' -f $TaskName)
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings -Principal $principal `
    -Description '校园网 Portal 自动登录：每次开机自动认证，成功后保持一段时间再退出。' | Out-Null

Good ('计划任务已注册：{0}' -f $TaskName)

Write-Host ''
Info '当前任务信息：'
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize | Out-String | Write-Host
Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object LastRunTime, LastTaskResult, NextRunTime | Format-List | Out-String | Write-Host

if ($RunNow) {
    Info '立即触发一次...'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 5
    Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object LastRunTime, LastTaskResult | Format-List | Out-String | Write-Host
    Info ('日志：{0}' -f (Join-Path $ScriptDir ('logs\campus-net-' + (Get-Date -Format 'yyyyMMdd') + '.log')))
}

Write-Host ''
Info '常用命令：'
Write-Host ('    手动跑一次   : Start-ScheduledTask -TaskName "{0}"' -f $TaskName)
Write-Host ('    查看执行结果 : Get-ScheduledTaskInfo -TaskName "{0}"' -f $TaskName)
Write-Host ('    查看日志     : Get-Content "{0}\logs\campus-net-*.log" -Tail 50' -f $ScriptDir)
Write-Host ('    先自检 exe   : .\Test-CampusNetLogin.ps1')
Write-Host '    卸载         : .\Install-AutoLogin.ps1 -Uninstall'
Write-Host ''
Info '退出码含义：0=成功（含本来就已联网）；1=配置/密码解密问题；2=预算内未连上；3=拿不到可用网络。'
