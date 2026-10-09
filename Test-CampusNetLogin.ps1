<#
.SYNOPSIS
    CampusNetLogin.exe 自检：在本地起一个 mock Portal，验证 exe 的各项关键行为。

.DESCRIPTION
    不联网、不碰真实校园网，全程只访问 127.0.0.1。验证内容：

      1. --dry-run     能否正确解密 DPAPI 密码并把请求体拼对
      2. 成功路径      能否在时间预算内连上、并在保持 N 秒后自动退出
      3. 失败路径      能否在 connectDeadlineSeconds 预算内放弃并以退出码 2 结束
      4. GBK 响应      能否按 responseEncoding=gbk 正确解码中文并命中失败关键词
      5. --diagnose    诊断输出是否完整

    全部通过返回 0，任一失败返回 1。部署到新机器后建议先跑一遍本脚本。

.EXAMPLE
    .\Test-CampusNetLogin.ps1
.EXAMPLE
    .\Test-CampusNetLogin.ps1 -ExePath .\CampusNetLogin.exe
#>
#Requires -Version 3.0
[CmdletBinding()]
param(
    [string]$ExePath,
    [string]$WorkDir
)

$ErrorActionPreference = 'Stop'

# ---------- 目录解析（[CmdletBinding()] 下 $PSScriptRoot 在 param 默认值里为空）----------
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Definition }
    if (-not [string]::IsNullOrEmpty($scriptPath)) { $ScriptDir = Split-Path -Parent $scriptPath }
}
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = (Get-Location).Path }

if ([string]::IsNullOrEmpty($ExePath)) { $ExePath = Join-Path $ScriptDir 'CampusNetLogin.exe' }
if ([string]::IsNullOrEmpty($WorkDir)) { $WorkDir = Join-Path $ScriptDir '_selftest_tmp' }

function Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Good { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Bad  { param([string]$m) Write-Host "[-] $m" -ForegroundColor Red }
function Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $ExePath)) { throw "找不到 exe：$ExePath（先运行 build-exe.ps1）" }
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
[void](New-Item -ItemType Directory -Path $WorkDir -Force)
$logDir    = Join-Path $WorkDir 'logs'
$stateFile = Join-Path $WorkDir 'state.txt'
[System.IO.File]::WriteAllText($stateFile, '', (New-Object System.Text.UTF8Encoding($false)))

$results = New-Object System.Collections.ArrayList

# ============================================================
#  mock Portal（纯 TcpListener，不依赖 HTTP.sys）
# ============================================================
$port = 18080
$tcp = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), $port
try { $tcp.Start() } catch { throw "无法监听 127.0.0.1:$port —— $($_.Exception.Message)" }
Info ("mock Portal 已启动：http://127.0.0.1:{0}/" -f $port)

$workerScript = {
    param($tcp, $stateFile)
    while ($true) {
        $client = $null
        try { $client = $tcp.AcceptTcpClient() } catch { break }
        try {
            $stream = $client.GetStream()
            $buf = New-Object byte[] 4096
            $all = New-Object System.IO.MemoryStream
            $headText = ''
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $all.Write($buf, 0, $n)
                $headText = [System.Text.Encoding]::ASCII.GetString($all.ToArray())
                if ($headText.Contains("`r`n`r`n")) { break }
            }
            $idx   = $headText.IndexOf("`r`n`r`n")
            $head  = $headText.Substring(0, $idx)
            $rest  = $headText.Substring($idx + 4)
            $lines = $head -split "`r`n"
            $path  = ($lines[0] -split ' ')[1]
            $clen  = 0
            foreach ($l in $lines) { if ($l -match '(?i)^content-length:\s*(\d+)') { $clen = [int]$Matches[1] } }
            $bodyMs = New-Object System.IO.MemoryStream
            if ($rest.Length -gt 0) { $b0 = [System.Text.Encoding]::UTF8.GetBytes($rest); $bodyMs.Write($b0, 0, $b0.Length) }
            while ($bodyMs.Length -lt $clen) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $bodyMs.Write($buf, 0, $n)
            }
            $body = [System.Text.Encoding]::UTF8.GetString($bodyMs.ToArray())

            $status = '200 OK'
            $enc    = [System.Text.Encoding]::UTF8
            if ($path -eq '/portal/index.html') {
                $resp = 'var token = "TK12345";'
            } elseif ($path -eq '/login') {
                if ($body -match 'token=TK12345' -and $body -match 'userName=20230001') {
                    [System.IO.File]::WriteAllText($stateFile, 'online', (New-Object System.Text.UTF8Encoding($false)))
                    $resp = '{"success":true,"msg":"\u767b\u5f55\u6210\u529f"}'
                } else {
                    $resp = '{"success":false,"msg":"\u5bc6\u7801\u9519\u8bef"}'
                }
            } elseif ($path -eq '/login-gbk') {
                $enc  = [System.Text.Encoding]::GetEncoding(936)
                $resp = '{"success":false,"msg":"密码错误"}'
            } elseif ($path -eq '/connecttest.txt') {
                $state = ''
                if (Test-Path -LiteralPath $stateFile) { $state = [System.IO.File]::ReadAllText($stateFile) }
                if ($state -eq 'online') { $resp = 'Microsoft Connect Test' } else { $resp = '<html>portal login page</html>' }
            } else {
                $resp = 'not found'; $status = '404 Not Found'
            }

            $rb = $enc.GetBytes($resp)
            $headOut = "HTTP/1.1 $status`r`nContent-Type: text/html; charset=$($enc.WebName)`r`nContent-Length: $($rb.Length)`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($headOut)
            $stream.Write($hb, 0, $hb.Length)
            $stream.Write($rb, 0, $rb.Length)
            $stream.Flush()
        } catch { }
        try { $client.Close() } catch { }
    }
}
$worker = [powershell]::Create()
[void]$worker.AddScript($workerScript).AddArgument($tcp).AddArgument($stateFile)
$async = $worker.BeginInvoke()
Start-Sleep -Milliseconds 400

# ============================================================
#  辅助
# ============================================================
function New-TestConfig {
    param(
        [string]$Path, [string]$User, [string]$LoginUrl,
        [string]$Enc = 'utf8', [int]$Deadline = 15, [string]$PassEnc = ''
    )
    $o = [ordered]@{
        portalName             = 'selftest-mock'
        responseEncoding       = $Enc
        verifyUrl              = ("http://127.0.0.1:{0}/connecttest.txt" -f $port)
        verifyExpect           = 'Microsoft Connect Test'
        connectDeadlineSeconds = $Deadline
        autoExitSeconds        = 300
        holdCheckSeconds       = 30
        successKeywords        = @('成功', 'success')
        failureKeywords        = @('失败', '错误', '密码')
        credentials            = [ordered]@{
            user        = $User
            password    = $(if ($PassEnc) { '' } else { 'abc123@' })
            passwordEnc = $PassEnc
        }
        preRequests            = @(
            [ordered]@{
                name = 'token'; url = ("http://127.0.0.1:{0}/portal/index.html" -f $port)
                method = 'GET'; regex = 'token\s*=\s*"([^"]+)"'; group = 1; encoding = 'utf8'
            }
        )
        login                  = [ordered]@{
            url         = $LoginUrl
            method      = 'POST'
            contentType = 'application/x-www-form-urlencoded'
            body        = [ordered]@{ userName = '{user}'; passWord = '{pass}'; token = '{token}'; ip = '{ip}' }
        }
    }
    $o | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Exe {
    param([string[]]$ExeArgs)
    # 自检只验证运行行为，不注册计划任务（避免触发 UAC / 改动系统）
    $ExeArgs = @($ExeArgs) + @('--no-install')
    # 注意：exe 是 GUI 子系统（无控制台窗口）：
    #   1) PowerShell 用 & 调用不会等待它，会立刻返回且 $LASTEXITCODE 为空；
    #   2) Start-Process 在受限会话下可能被系统拒绝（"操作被用户取消"）。
    # 因此直接用 System.Diagnostics.Process + UseShellExecute=$false，最可靠。
    $argLine = ($ExeArgs | ForEach-Object {
        $a = [string]$_
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $ExePath
    $psi.Arguments              = $argLine
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError  = $false

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } catch {
        $sw.Stop()
        return [pscustomobject]@{
            ExitCode = -1
            Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            Output   = ("启动失败：" + $_.Exception.Message)
        }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
    $sw.Stop()
    return [pscustomobject]@{
        ExitCode = $code
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        Output   = ''
    }
}

function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    [void]$results.Add([pscustomobject]@{ 检查项 = $Name; 结果 = $(if ($Pass) { 'PASS' } else { 'FAIL' }); 说明 = $Detail })
    if ($Pass) {
        Good ("{0} —— {1}" -f $Name, $Detail)
    } else {
        Bad ("{0} —— {1}" -f $Name, $Detail)
        # 失败时把日志尾部打出来，便于直接定位原因
        $tail = @((Get-LogText) -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 10
        foreach ($l in $tail) { Write-Host ('      | ' + $l) -ForegroundColor DarkGray }
    }
}

$todayLog = Join-Path $logDir ('campus-net-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
function Get-LogText { if (Test-Path -LiteralPath $todayLog) { return (Get-Content -LiteralPath $todayLog -Raw -Encoding UTF8) } return '' }

$cfgOk    = Join-Path $WorkDir 'c-ok.json'
$cfgBad   = Join-Path $WorkDir 'c-bad.json'
$cfgGbk   = Join-Path $WorkDir 'c-gbk.json'
$cfgDpapi = Join-Path $WorkDir 'c-dpapi.json'

New-TestConfig -Path $cfgOk    -User '20230001' -LoginUrl ("http://127.0.0.1:{0}/login"     -f $port) -Deadline 15
New-TestConfig -Path $cfgBad   -User '99999999' -LoginUrl ("http://127.0.0.1:{0}/login"     -f $port) -Deadline 15
New-TestConfig -Path $cfgGbk   -User '20230001' -LoginUrl ("http://127.0.0.1:{0}/login-gbk" -f $port) -Enc 'gbk' -Deadline 6
$sec = ConvertTo-SecureString 'abc123@' -AsPlainText -Force
New-TestConfig -Path $cfgDpapi -User '20230001' -LoginUrl ("http://127.0.0.1:{0}/login"     -f $port) -Deadline 15 -PassEnc (ConvertFrom-SecureString $sec)

try {
    # ---- 1. DPAPI 解密 + 请求体拼装 ----
    $r1 = Invoke-Exe @('--config', $cfgDpapi, '--log', $logDir, '--dry-run', '--force')
    $log1 = Get-LogText
    $ok1 = ($r1.ExitCode -eq 0) -and ($log1 -match 'passWord=abc123%40') -and ($log1 -match 'userName=20230001') -and ($log1 -match 'token=TK12345')
    Add-Result 'DPAPI 解密 + 请求体拼装' $ok1 ("退出码 {0}；Body 含账号/密码/token = {1}" -f $r1.ExitCode, ($log1 -match 'passWord=abc123%40'))

    # ---- 2. 成功路径 + 保持期自动退出 ----
    [System.IO.File]::WriteAllText($stateFile, '', (New-Object System.Text.UTF8Encoding($false)))
    $r2 = Invoke-Exe @('--config', $cfgOk, '--log', $logDir, '--force', '--exit-after', '4')
    $state = [System.IO.File]::ReadAllText($stateFile)
    $ok2 = ($r2.ExitCode -eq 0) -and ($state -eq 'online') -and ($r2.Seconds -ge 4) -and ($r2.Seconds -le 12)
    Add-Result '成功路径 + 保持 4 秒后自动退出' $ok2 ("退出码 {0}；耗时 {1}s；mock 状态 {2}" -f $r2.ExitCode, $r2.Seconds, $state)

    # ---- 3. 时间预算内失败退出 ----
    [System.IO.File]::WriteAllText($stateFile, '', (New-Object System.Text.UTF8Encoding($false)))
    $r3 = Invoke-Exe @('--config', $cfgBad, '--log', $logDir, '--force', '--once')
    $ok3 = ($r3.ExitCode -eq 2) -and ($r3.Seconds -le 16.5) -and ($r3.Seconds -ge 10)
    Add-Result '失败路径在 15 秒预算内退出' $ok3 ("退出码 {0}；耗时 {1}s（应 ≤15s）" -f $r3.ExitCode, $r3.Seconds)

    # ---- 4. GBK 响应解码 ----
    $r4 = Invoke-Exe @('--config', $cfgGbk, '--log', $logDir, '--force', '--once')
    $log4 = Get-LogText
    $ok4 = ($log4 -match '密码错误') -and ($log4 -match '命中失败关键词')
    Add-Result 'GBK 响应解码 + 失败关键词命中' $ok4 ("退出码 {0}；日志含正确中文 = {1}" -f $r4.ExitCode, ($log4 -match '密码错误'))

    # ---- 5. 诊断模式 ----
    $r5 = Invoke-Exe @('--config', $cfgOk, '--log', $logDir, '--diagnose')
    $log5 = Get-LogText
    $ok5 = ($r5.ExitCode -eq 0) -and ($log5 -match '本机 IP') -and ($log5 -match 'Portal 可达') -and ($log5 -match '凭据解密')
    Add-Result '--diagnose 诊断输出' $ok5 ("退出码 {0}；含网卡/Portal/凭据 = {1}" -f $r5.ExitCode, ($log5 -match '凭据解密'))
}
finally {
    try { $tcp.Stop() } catch { }
    try { $worker.Stop() } catch { }
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '================ 自检结果 ================' -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$failed = @($results | Where-Object { $_.结果 -eq 'FAIL' })
if ($failed.Count -eq 0) {
    Good ('全部 {0} 项通过。' -f $results.Count)
    exit 0
} else {
    Bad ('{0}/{1} 项失败。' -f $failed.Count, $results.Count)
    exit 1
}
