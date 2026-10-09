<#
.SYNOPSIS
    校园网 Portal 自动登录脚本（配合任务计划可实现开机 / 登录后自动联网）。

.DESCRIPTION
    执行顺序（每一步都可核对，不靠猜）：
      1) 先探测当前是否真的能上外网 —— 已联网直接退出，不做无用请求。
      2) 未联网则等待默认网关就绪（开机时网卡要几秒到几十秒才拿到 IP）。
      3) 按 config.json 执行 preRequests（可选，用于取 token / challenge 等动态值）。
      4) 提交登录请求（form 表单 或 JSON 原始体）。
      5) 用真实外网探测验证结果，而不是只看服务器返回的文案。
      6) 失败按递增退避重试。

.PARAMETER ConfigPath
    config.json 路径，默认与脚本同目录。
.PARAMETER Force
    即使当前已联网也强制提交一次登录（用于调试或需要续期的场景）。
.PARAMETER DryRun
    只打印将要发送的请求内容，不真正发送。首次部署强烈建议先跑这个。
.PARAMETER Diagnose
    打印本机网络信息 + 外网探测 + Portal 可达性，然后退出。

.EXAMPLE
    .\CampusNetLogin.ps1 -Diagnose
.EXAMPLE
    .\CampusNetLogin.ps1 -DryRun -Force
.EXAMPLE
    .\CampusNetLogin.ps1 -Force
#>
#Requires -Version 3.0
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$LogDir,
    [int]$WaitNetworkSeconds = 180,
    [int]$MaxAttempts        = 5,
    [int]$RetryDelaySeconds  = 5,
    [int]$VerifySeconds      = 25,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Diagnose,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# 注意：带 [CmdletBinding()] 的脚本里，$PSScriptRoot 在 param() 默认值中是空字符串，
# 所以脚本目录必须在函数体里解析。这里做多级兜底，兼容 -File / 相对路径 / 点源等调用方式。
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
if ([string]::IsNullOrEmpty($LogDir))     { $LogDir     = Join-Path $ScriptDir 'logs' }

$script:LogFile = $null
$script:Quiet   = [bool]$Quiet

# Windows PowerShell 5.1 在旧系统上默认可能只启用 TLS 1.0，现代 Portal 会直接拒连。
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor
        [Net.SecurityProtocolType]::Tls11 -bor
        [Net.SecurityProtocolType]::Tls
} catch { }

# 不发送 Expect: 100-continue，避免部分老旧 Portal 处理不当导致登录请求体发不出去。
try { [Net.ServicePointManager]::Expect100Continue = $false } catch { }

# ============================================================
#  基础工具
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if (-not $script:Quiet) {
        $color = 'Gray'
        switch ($Level) {
            'OK'    { $color = 'Green' }
            'WARN'  { $color = 'Yellow' }
            'ERROR' { $color = 'Red' }
            'STEP'  { $color = 'Cyan' }
        }
        Write-Host $line -ForegroundColor $color
    }
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Initialize-Log {
    param([string]$Dir)
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $script:LogFile = Join-Path $Dir ('campus-net-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Get-ChildItem -LiteralPath $Dir -Filter 'campus-net-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        $script:LogFile = $null
    }
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Read-TextFileAuto {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($bytes)
    } catch {
        return [System.Text.Encoding]::GetEncoding('GB18030').GetString($bytes)
    }
}

function Get-TextEncoding {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'utf8' }
    switch -Regex ($Name) {
        '^(?i)\s*(gbk|gb2312|gb18030)\s*$' { return [System.Text.Encoding]::GetEncoding('GB18030') }
        '^(?i)\s*utf-?8\s*$'               { return (New-Object System.Text.UTF8Encoding($false)) }
        '^(?i)\s*ascii\s*$'                { return [System.Text.Encoding]::ASCII }
        '^(?i)\s*(utf-?16|unicode)\s*$'    { return [System.Text.Encoding]::Unicode }
        default                            { return (New-Object System.Text.UTF8Encoding($false)) }
    }
}

function Get-HashHex {
    param([string]$Text, [string]$Algorithm)
    if ($null -eq $Text) { $Text = '' }
    $algo  = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    $bytes = $algo.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-Base64 {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Expand-JsonEscapes {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    try {
        # 部分 Portal 返回 JSON 时把中文写成 \uXXXX，不还原就匹配不到中文关键词
        return [regex]::Replace($Text, '(?<!\\)\\u([0-9a-fA-F]{4})', {
            param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16)
        })
    } catch {
        return $Text
    }
}

function Expand-Template {
    param([string]$Text, $Vars)
    if ($null -eq $Text) { return $Text }
    $out = [string]$Text
    foreach ($k in @($Vars.Keys)) {
        $out = $out.Replace('{' + $k + '}', [string]$Vars[$k])
    }
    return $out
}

# ============================================================
#  HTTP 请求（HttpWebRequest，精确控制编码 / Cookie / 证书）
# ============================================================

function Invoke-PortalRequest {
    param(
        [string]$Url,
        [string]$Method = 'POST',
        $Headers,
        [string]$ContentType,
        [string]$BodyText,
        [string]$EncodingName = 'utf8',
        [System.Net.CookieContainer]$Cookies,
        [int]$TimeoutSec = 15,
        [switch]$AllowInvalidCert,
        [switch]$NoProxy,
        [switch]$UseSystemProxy
    )

    $enc = Get-TextEncoding $EncodingName
    if ($null -eq $Cookies) { $Cookies = New-Object System.Net.CookieContainer }

    $target = $Url
    if ($Method -eq 'GET' -and -not [string]::IsNullOrEmpty($BodyText)) {
        if ($target -match '\?') { $target = $target + '&' + $BodyText } else { $target = $target + '?' + $BodyText }
    }

    $req = [System.Net.HttpWebRequest]::Create($target)
    $req.Method            = $Method.ToUpper()
    $req.Timeout           = $TimeoutSec * 1000
    $req.ReadWriteTimeout  = $TimeoutSec * 1000
    $req.AllowAutoRedirect = $true
    $req.MaximumAutomaticRedirections = 10
    $req.CookieContainer   = $Cookies
    $req.UserAgent         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36'
    $req.Accept            = '*/*'
    $req.KeepAlive         = $true
    if ($NoProxy -and -not $UseSystemProxy) { $req.Proxy = $null }
    if ($AllowInvalidCert) { $req.ServerCertificateValidationCallback = { param($a, $b, $c, $d) return $true } }

    if ($Headers) {
        foreach ($p in $Headers.PSObject.Properties) {
            $name = $p.Name
            $val  = [string]$p.Value
            switch -Regex ($name) {
                '^(?i)user-agent$'   { $req.UserAgent = $val; continue }
                '^(?i)referer$'      { $req.Referer   = $val; continue }
                '^(?i)content-type$' { $ContentType   = $val; continue }
                '^(?i)host$'         { $req.Host      = $val; continue }
                '^(?i)accept$'       { $req.Accept    = $val; continue }
                '^(?i)connection$'   { continue }
            }
            try { $req.Headers[$name] = $val } catch { }
        }
    }

    if ($req.Method -eq 'POST') {
        if ([string]::IsNullOrEmpty($ContentType)) { $ContentType = 'application/x-www-form-urlencoded' }
        $req.ContentType = $ContentType
        $payload = ''
        if ($null -ne $BodyText) { $payload = [string]$BodyText }
        $bytes = $enc.GetBytes($payload)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
    }

    $ms = New-Object System.IO.MemoryStream
    try {
        $rs = $resp.GetResponseStream()
        if ($rs) { $rs.CopyTo($ms) }
    } catch { }
    $raw = $ms.ToArray()
    $ms.Dispose()

    $charset = $null
    try { $charset = $resp.CharacterSet } catch { }
    $decodeEnc = $enc
    if (-not [string]::IsNullOrWhiteSpace($charset)) { $decodeEnc = Get-TextEncoding $charset }
    $text = ''
    try { $text = $decodeEnc.GetString($raw) } catch { $text = $enc.GetString($raw) }

    $status = 0
    try { $status = [int]$resp.StatusCode } catch { }
    $location = ''
    try { $location = [string]$resp.Headers['Location'] } catch { }

    try { $resp.Close() } catch { }

    return [pscustomobject]@{
        StatusCode = $status
        Location   = $location
        Content    = $text
        Raw        = $raw
        Cookies    = $Cookies
        Url        = $target
    }
}

# ============================================================
#  网络状态
# ============================================================

function Get-LocalNetworkInfo {
    $info = @{ IP = ''; MAC = ''; Gateway = ''; DNS = @(); Adapter = '' }

    $cfg = $null
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop |
               Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
               Select-Object -First 1
    } catch { }

    if ($cfg) {
        try { $info.IP      = @($cfg.IPv4Address)[0].IPAddress } catch { }
        try { $info.Gateway = $cfg.IPv4DefaultGateway.NextHop } catch { }
        try { $info.DNS     = @($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses } | Select-Object -First 4) } catch { }
        try { $info.Adapter = $cfg.InterfaceAlias } catch { }
        try { $info.MAC     = (Get-NetAdapter -InterfaceIndex $cfg.InterfaceIndex -ErrorAction Stop).MacAddress } catch { }
        return $info
    }

    try {
        $w = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop |
             Where-Object { $_.DefaultIPGateway } | Select-Object -First 1
        if ($w) {
            $info.IP      = @($w.IPAddress)[0]
            $info.MAC     = $w.MACAddress
            $info.Gateway = @($w.DefaultIPGateway)[0]
            $info.DNS     = @($w.DNSServerSearchOrder)
            return $info
        }
    } catch { }

    # 3) 纯 .NET 回退：CIM/WMI 被禁用或权限受限（企业锁定、WMI 服务关闭）时仍然可用
    return (Get-NetInfoFromDotNet)
}

function Get-NetInfoFromDotNet {
    $best = $null
    $empty = @{ IP = ''; MAC = ''; Gateway = ''; DNS = @(); Adapter = '' }
    try {
        $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object {
                    $_.OperationalStatus -eq 'Up' -and
                    $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback
                }
        foreach ($nic in $nics) {
            $props = $null
            try { $props = $nic.GetIPProperties() } catch { continue }

            $ipv4 = @($props.UnicastAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            if ($ipv4.Count -eq 0) { continue }

            $ip = $ipv4[0].Address.IPAddressToString
            if ($ip -like '127.*' -or $ip -like '169.254.*') { continue }   # 跳过回环与 APIPA

            $gw = ''
            $gws = @($props.GatewayAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            if ($gws.Count -gt 0) { $gw = $gws[0].Address.IPAddressToString }

            $mac = ''
            try { $mac = $nic.GetPhysicalAddress().ToString() } catch { }
            if ($mac.Length -eq 12) { $mac = ($mac -replace '(.{2})(?=.)', '$1-') }

            $dns = @($props.DnsAddresses | Where-Object {
                $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.IPAddressToString })

            $cand = @{ IP = $ip; MAC = $mac; Gateway = $gw; DNS = $dns; Adapter = $nic.Name }
            if ($gw) { return $cand }        # 有网关的网卡优先
            if (-not $best) { $best = $cand }
        }
    } catch { }

    if ($best) { return $best }
    return $empty
}

function Test-Online {
    param($Config, [int]$TimeoutSec = 8)

    $url    = [string](Get-Prop $Config 'verifyUrl' 'http://www.msftconnecttest.com/connecttest.txt')
    $expect = [string](Get-Prop $Config 'verifyExpect' 'Microsoft Connect Test')

    try {
        $r = Invoke-PortalRequest -Url $url -Method GET -TimeoutSec $TimeoutSec `
                -EncodingName 'utf8' -AllowInvalidCert -NoProxy
        if ($r.StatusCode -eq 204) { return $true }
        if ($r.StatusCode -lt 200 -or $r.StatusCode -ge 400) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($expect)) {
            return ($r.Content -match [regex]::Escape($expect))
        }
        return $true
    } catch {
        return $false
    }
}

function Test-NetworkUsable {
    param($Net)
    if ($null -eq $Net) { return $false }
    # 有默认网关是最强信号；部分 Portal 网络在认证前不下发默认路由，
    # 此时"拿到有效 IPv4"也应视为就绪，否则脚本会一直等到超时。
    if ($Net.Gateway) { return $true }
    if ($Net.IP -and $Net.IP -notlike '127.*' -and $Net.IP -notlike '169.254.*') { return $true }
    return $false
}

function Wait-NetworkReady {
    param([int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    $first = $true
    while ((Get-Date) -lt $deadline) {
        $net = Get-LocalNetworkInfo
        if (Test-NetworkUsable $net) { return $net }
        if ($first) { Write-Log '等待网络就绪（开机后网卡需要时间拿 IP / 默认网关）...' 'STEP'; $first = $false }
        Start-Sleep -Seconds 3
    }
    return (Get-LocalNetworkInfo)
}

# ============================================================
#  配置解析
# ============================================================

function Get-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到配置文件：$Path" }
    $text = Read-TextFileAuto -Path $Path
    try { return ($text | ConvertFrom-Json) }
    catch { throw "config.json 解析失败：$($_.Exception.Message)" }
}

function Get-PlainPassword {
    param($Config)
    $creds = Get-Prop $Config 'credentials' $null
    if ($null -eq $creds) { return '' }

    $enc = [string](Get-Prop $creds 'passwordEnc' '')
    if (-not [string]::IsNullOrWhiteSpace($enc)) {
        try {
            $sec  = ConvertTo-SecureString $enc
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } catch {
            throw "passwordEnc 解密失败（DPAPI 密文与当前用户+当前机器绑定，换机器/换用户必须重新运行 Set-PortalCredential.ps1）：$($_.Exception.Message)"
        }
    }
    return [string](Get-Prop $creds 'password' '')
}

function New-TemplateVars {
    param($Config, $Net, $Extra)

    $user = [string](Get-Prop (Get-Prop $Config 'credentials' $null) 'user' '')
    $pass = Get-PlainPassword -Config $Config

    $vars = @{}
    $vars['user']        = $user
    $vars['pass']        = $pass
    $vars['user_b64']    = Get-Base64 $user
    $vars['user_md5']    = Get-HashHex $user 'MD5'
    $vars['pass_b64']    = Get-Base64 $pass
    $vars['pass_md5']    = Get-HashHex $pass 'MD5'
    $vars['pass_sha1']   = Get-HashHex $pass 'SHA1'
    $vars['pass_sha256'] = Get-HashHex $pass 'SHA256'
    $vars['pass_b64md5'] = Get-Base64 (Get-HashHex $pass 'MD5')
    $vars['ip']          = [string]$Net.IP
    $vars['mac']         = [string]$Net.MAC
    $vars['mac_plain']   = ([string]$Net.MAC -replace '[^0-9A-Fa-f]', '')
    $vars['gateway']     = [string]$Net.Gateway
    $vars['hostname']    = $env:COMPUTERNAME
    $vars['domain']      = $env:USERDOMAIN
    $vars['ts']          = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $vars['date']        = (Get-Date -Format 'yyyy-MM-dd')
    $vars['time']        = (Get-Date -Format 'HH:mm:ss')
    $unix = [int64]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
    $vars['ts_unix']     = [string]$unix
    $vars['ts_ms']       = [string]($unix * 1000)

    if ($Extra) { foreach ($k in $Extra.Keys) { $vars[$k] = $Extra[$k] } }
    return $vars
}

function Get-BodyString {
    param($LoginNode, $Vars, $EncodingName)

    $bodyRaw = [string](Get-Prop $LoginNode 'bodyRaw' '')
    if (-not [string]::IsNullOrWhiteSpace($bodyRaw)) { return (Expand-Template $bodyRaw $Vars) }

    $body = Get-Prop $LoginNode 'body' $null
    if ($null -eq $body) { return '' }

    $pairs = New-Object System.Collections.ArrayList
    foreach ($p in $body.PSObject.Properties) {
        $name = $p.Name
        $val  = Expand-Template ([string]$p.Value) $Vars
        if ($EncodingName -match '(?i)json') {
            $escaped = $val -replace '\\', '\\' -replace '"', '\"'
            [void]$pairs.Add('"' + $name + '":"' + $escaped + '"')
        } else {
            [void]$pairs.Add(([System.Uri]::EscapeDataString($name) + '=' + [System.Uri]::EscapeDataString($val)))
        }
    }
    if ($EncodingName -match '(?i)json') { return '{' + ($pairs -join ',') + '}' }
    return ($pairs -join '&')
}

# ============================================================
#  主流程
# ============================================================

Initialize-Log -Dir $LogDir
Write-Log '================ 校园网自动登录 ================'

# ---- 诊断模式 ----
if ($Diagnose) {
    $net = Get-LocalNetworkInfo
    Write-Log ('网卡      : {0}' -f $net.Adapter)
    Write-Log ('本机 IP   : {0}' -f $net.IP)
    Write-Log ('MAC       : {0}' -f $net.MAC)
    Write-Log ('默认网关  : {0}' -f $net.Gateway)
    Write-Log ('DNS       : {0}' -f ($net.DNS -join ', '))

    $cfgForDiag = $null
    try { $cfgForDiag = Get-Config -Path $ConfigPath } catch { Write-Log "配置文件未就绪：$($_.Exception.Message)" 'WARN' }

    if ($cfgForDiag) {
        Write-Log ('外网探测  : {0}  ->  {1}' -f (Get-Prop $cfgForDiag 'verifyUrl' 'http://www.msftconnecttest.com/connecttest.txt'), (Test-Online $cfgForDiag))
        $loginUrl = [string](Get-Prop (Get-Prop $cfgForDiag 'login' $null) 'url' '')
        if ($loginUrl) {
            try {
                $r = Invoke-PortalRequest -Url $loginUrl -Method GET -TimeoutSec 8 `
                        -AllowInvalidCert:([bool](Get-Prop $cfgForDiag 'allowInvalidCertificate' $false)) -NoProxy
                Write-Log ('Portal 可达: HTTP {0}' -f $r.StatusCode)
            } catch {
                Write-Log ('Portal 不可达: {0}' -f $_.Exception.Message) 'WARN'
            }
        }
    }
    Write-Log '诊断结束。'
    exit 0
}

# ---- 读取配置 ----
$config = $null
try { $config = Get-Config -Path $ConfigPath }
catch { Write-Log $_.Exception.Message 'ERROR'; exit 1 }

$allowBadCert = [bool](Get-Prop $config 'allowInvalidCertificate' $false)
$respEncoding = [string](Get-Prop $config 'responseEncoding' 'utf8')
$successWords = @(Get-Prop $config 'successKeywords' @('成功', 'success', '已上线'))
$failureWords = @(Get-Prop $config 'failureKeywords' @('失败', '错误', 'error'))
$portalName   = [string](Get-Prop $config 'portalName' '校园网')
$loginNode    = Get-Prop $config 'login' $null

if ($null -eq $loginNode -or [string]::IsNullOrWhiteSpace([string](Get-Prop $loginNode 'url' ''))) {
    Write-Log 'config.json 缺少 login.url，请先运行 Get-PortalConfig.ps1 生成配置。' 'ERROR'
    exit 1
}

Write-Log ('Portal    : {0}' -f $portalName)

# ---- 1. 已联网？ ----
if (-not $Force) {
    if (Test-Online -Config $config) {
        Write-Log '当前已联网，无需登录。' 'OK'
        exit 0
    }
    Write-Log '当前未联网，开始认证流程。' 'STEP'
} else {
    Write-Log 'Force 模式：跳过"已联网"判断。' 'STEP'
}

# ---- 2. 等网关 ----
$net = Wait-NetworkReady -Seconds $WaitNetworkSeconds
if (-not (Test-NetworkUsable $net)) {
    Write-Log ('等待 {0} 秒仍拿不到可用 IPv4 / 默认网关，放弃本次。' -f $WaitNetworkSeconds) 'ERROR'
    exit 3
}
Write-Log ('网络就绪：IP={0} 网关={1} 网卡={2}' -f $net.IP, $net.Gateway, $net.Adapter) 'OK'

# ---- 3. preRequests ----
$cookies   = New-Object System.Net.CookieContainer
$extraVars = @{}
$preReqs   = Get-Prop $config 'preRequests' $null
if ($preReqs) {
    $preVars = New-TemplateVars -Config $config -Net $net -Extra $null
    foreach ($pre in @($preReqs)) {
        $pname = [string](Get-Prop $pre 'name' '')
        $purl  = Expand-Template ([string](Get-Prop $pre 'url' '')) $preVars
        $pmeth = [string](Get-Prop $pre 'method' 'GET')
        if ([string]::IsNullOrWhiteSpace($purl)) { continue }
        try {
            $r = Invoke-PortalRequest -Url $purl -Method $pmeth -TimeoutSec 15 `
                    -EncodingName ([string](Get-Prop $pre 'encoding' $respEncoding)) `
                    -Cookies $cookies -AllowInvalidCert:$allowBadCert -NoProxy
            $pattern = [string](Get-Prop $pre 'regex' '')
            if (-not [string]::IsNullOrWhiteSpace($pattern)) {
                $grp = [int](Get-Prop $pre 'group' 1)
                $m = [regex]::Match($r.Content, $pattern)
                if ($m.Success) {
                    $val = $m.Groups[$grp].Value
                    $extraVars[$pname] = $val
                    $preVars[$pname]   = $val
                    Write-Log ('preRequest [{0}] 提取成功（长度 {1}）' -f $pname, $val.Length) 'OK'
                } else {
                    Write-Log ('preRequest [{0}] 正则未匹配，请检查 regex。' -f $pname) 'WARN'
                }
            } else {
                Write-Log ('preRequest [{0}] 已执行（仅取 Cookie，无正则）。' -f $pname)
            }
        } catch {
            Write-Log ('preRequest [{0}] 请求失败：{1}' -f $pname, $_.Exception.Message) 'WARN'
        }
    }
}

# ---- 4. 登录 ----
$attempt = 0
$ok = $false

while ($attempt -lt $MaxAttempts -and -not $ok) {
    $attempt++
    $vars = New-TemplateVars -Config $config -Net $net -Extra $extraVars

    $loginUrl = Expand-Template ([string](Get-Prop $loginNode 'url' '')) $vars
    $method   = ([string](Get-Prop $loginNode 'method' 'POST')).ToUpper()
    $ctype    = [string](Get-Prop $loginNode 'contentType' 'application/x-www-form-urlencoded')
    $ctype    = Expand-Template $ctype $vars
    $headers  = Get-Prop $loginNode 'headers' $null
    $bodyText = Get-BodyString -LoginNode $loginNode -Vars $vars -EncodingName $ctype

    if ($headers) {
        $ht = @{}
        foreach ($p in $headers.PSObject.Properties) { $ht[$p.Name] = (Expand-Template ([string]$p.Value) $vars) }
        $headers = [pscustomobject]$ht
    }

    Write-Log ('第 {0}/{1} 次尝试：{2} {3}' -f $attempt, $MaxAttempts, $method, $loginUrl) 'STEP'

    if ($DryRun) {
        Write-Log '----- DryRun：以下内容不会真正发送 -----' 'WARN'
        Write-Log ("URL         : {0}" -f $loginUrl)
        Write-Log ("Method      : {0}" -f $method)
        Write-Log ("Content-Type: {0}" -f $ctype)
        if ($headers) {
            foreach ($p in $headers.PSObject.Properties) { Write-Log ("Header      : {0}: {1}" -f $p.Name, $p.Value) }
        }
        Write-Log ("Body        : {0}" -f $bodyText)
        $masked = $bodyText
        if ($vars['pass']) { $masked = $masked -replace [regex]::Escape($vars['pass']), '********' }
        Write-Log ("Body(脱敏)  : {0}" -f $masked)
        Write-Log '----- DryRun 结束 -----' 'WARN'
        exit 0
    }

    try {
        $resp = Invoke-PortalRequest -Url $loginUrl -Method $method -Headers $headers `
                    -ContentType $ctype -BodyText $bodyText -EncodingName $respEncoding `
                    -Cookies $cookies -AllowInvalidCert:$allowBadCert -NoProxy -TimeoutSec 20

        # 先把 JSON 的 \uXXXX 还原成真实字符，否则中文关键词匹配不到；
        # 再剔除 "success":false / "ok":0 这类否定形态，避免把字段名当成成功标志。
        $readable  = Expand-JsonEscapes $resp.Content
        $matchText = [regex]::Replace($readable, '(?i)"?[a-z_]*success"?\s*:\s*(false|0)\b', ' ')

        $snippet = $readable
        if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + '...' }
        Write-Log ('响应 HTTP {0}：{1}' -f $resp.StatusCode, ($snippet -replace '\s+', ' '))

        $hitFailure = $null
        foreach ($w in $failureWords) {
            if ($w -and $matchText -match [regex]::Escape($w)) { $hitFailure = $w; break }
        }
        if ($hitFailure) {
            Write-Log ('响应命中失败关键词「{0}」，判定本次登录失败。' -f $hitFailure) 'WARN'
        }

        Write-Log '验证外网连通性...'
        $deadline = (Get-Date).AddSeconds($VerifySeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-Online -Config $config) { $ok = $true; break }
            Start-Sleep -Seconds 2
        }

        if ($ok) {
            Write-Log '外网连通性验证通过，认证成功。' 'OK'
        } else {
            Write-Log '登录请求已发出，但外网仍不通。' 'WARN'
            if (-not $hitFailure) {
                $hitSuccess = $null
                foreach ($w in $successWords) {
                    if ($w -and $matchText -match [regex]::Escape($w)) { $hitSuccess = $w; break }
                }
                if ($hitSuccess) { Write-Log ('响应命中成功关键词「{0}」，但网络未通，可能是账号已在线或网关延迟。' -f $hitSuccess) 'WARN' }
            }
        }
    } catch {
        Write-Log ('请求异常：{0}' -f $_.Exception.Message) 'ERROR'
    }

    if (-not $ok -and $attempt -lt $MaxAttempts) {
        $delay = $RetryDelaySeconds * $attempt
        Write-Log ('{0} 秒后重试...' -f $delay)
        Start-Sleep -Seconds $delay
    }
}

if ($ok) {
    Write-Log '本次任务完成：已联网。' 'OK'
    exit 0
} else {
    Write-Log ('已尝试 {0} 次，仍未联网。请运行 -Diagnose 检查配置。' -f $MaxAttempts) 'ERROR'
    exit 2
}
