<#
.SYNOPSIS
    从浏览器"Copy as cURL"的登录请求中，自动生成 CampusNetLogin.ps1 所需的 config.json。

.DESCRIPTION
    为什么需要它：每个学校的 Portal 认证地址、字段名、编码方式都不一样，猜不出来。
    正确做法是让浏览器把"真实的那一次登录请求"完整交出来，再转成配置。

    抓取步骤（Chrome / Edge）：
      1. 打开校园网登录页，按 F12 打开开发者工具 → Network 面板。
      2. 勾选 "Preserve log"，然后在页面上正常输入账号密码并点击登录。
      3. 在请求列表里找到那条登录请求（通常叫 login / auth / doLogin / PortalLogin）。
      4. 右键该请求 → Copy → Copy as cURL (bash) 或 Copy as cURL (cmd)。
      5. 回到 PowerShell 执行：
             .\Get-PortalConfig.ps1 -FromClipboard
         或把内容存成 curl.txt 后：
             .\Get-PortalConfig.ps1 -CurlFile .\curl.txt

.PARAMETER FromClipboard
    直接读取剪贴板内容（最方便）。
.PARAMETER CurlFile
    从文件读取 curl 命令文本。
.PARAMETER CurlText
    直接传入 curl 命令字符串。
.PARAMETER OutFile
    输出路径，默认与脚本同目录的 config.json。已存在时会先备份。
.PARAMETER UserField / PassField
    自动识别不准时，手动指定账号字段名 / 密码字段名。
.PARAMETER User
    顺便把账号写进配置（密码请用 Set-PortalCredential.ps1 设置）。
#>
#Requires -Version 3.0
[CmdletBinding()]
param(
    [string]$CurlFile,
    [string]$CurlText,
    [switch]$FromClipboard,
    [string]$OutFile,
    [string]$UserField,
    [string]$PassField,
    [string]$User,
    [string]$PortalName,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

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

# ---------- 命令行分词（正确处理单/双引号与转义） ----------
function Split-CommandLine {
    param([string]$Text)
    $tokens = New-Object System.Collections.ArrayList
    $sb     = New-Object System.Text.StringBuilder
    $quote  = [char]0
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0; $i++; continue }
            if ($quote -eq [char]'"' -and $ch -eq '\' -and ($i + 1) -lt $Text.Length) {
                $nxt = $Text[$i + 1]
                if ($nxt -eq '"' -or $nxt -eq '\') { [void]$sb.Append($nxt); $i += 2; continue }
            }
            [void]$sb.Append($ch); $i++; continue
        }
        if ($ch -eq "'" -or $ch -eq '"') { $quote = $ch; $i++; continue }
        if ([char]::IsWhiteSpace($ch)) {
            if ($sb.Length -gt 0) { [void]$tokens.Add($sb.ToString()); [void]$sb.Clear() }
            $i++; continue
        }
        [void]$sb.Append($ch); $i++
    }
    if ($sb.Length -gt 0) { [void]$tokens.Add($sb.ToString()) }
    return $tokens
}

# ---------- 解析 curl ----------
function Parse-CurlCommand {
    param([string]$Raw)

    $text = $Raw -replace "`r`n", "`n"
    $text = $text -replace '\^\s*\n', ' '     # cmd 风格续行
    $text = $text -replace '\\\s*\n', ' '     # bash 风格续行
    $text = $text -replace '\n', ' '

    $tokens = Split-CommandLine -Text $text
    if ($tokens.Count -eq 0) { throw '内容为空，没解析到任何东西。' }

    $url     = $null
    $method  = $null
    $headers = New-Object System.Collections.Specialized.OrderedDictionary
    $body    = $null

    $i = 0
    while ($i -lt $tokens.Count) {
        $t = [string]$tokens[$i]
        switch -Regex ($t) {
            '^(?i)curl(\.exe)?$' { $i++; continue }
            '^(?i)(-H|--header)$' {
                $i++
                if ($i -lt $tokens.Count) {
                    $h = [string]$tokens[$i]
                    $idx = $h.IndexOf(':')
                    if ($idx -gt 0) {
                        $headers[$h.Substring(0, $idx).Trim()] = $h.Substring($idx + 1).Trim()
                    }
                }
                $i++; continue
            }
            '^(?i)(-d|--data|--data-raw|--data-binary|--data-ascii|--data-urlencode)$' {
                $i++
                if ($i -lt $tokens.Count) {
                    if ($null -eq $body) { $body = [string]$tokens[$i] }
                    else { $body = $body + '&' + [string]$tokens[$i] }
                }
                $i++; continue
            }
            '^(?i)(-X|--request)$' {
                $i++
                if ($i -lt $tokens.Count) { $method = ([string]$tokens[$i]).ToUpper() }
                $i++; continue
            }
            '^(?i)--url$' {
                $i++
                if ($i -lt $tokens.Count) { $url = [string]$tokens[$i] }
                $i++; continue
            }
            '^(?i)(-b|--cookie)$' {
                $i++
                if ($i -lt $tokens.Count) { $headers['Cookie'] = [string]$tokens[$i] }
                $i++; continue
            }
            '^(?i)(-e|--referer)$' {
                $i++
                if ($i -lt $tokens.Count) { $headers['Referer'] = [string]$tokens[$i] }
                $i++; continue
            }
            '^(?i)(-A|--user-agent)$' {
                $i++
                if ($i -lt $tokens.Count) { $headers['User-Agent'] = [string]$tokens[$i] }
                $i++; continue
            }
            '^(?i)(--compressed|--insecure|-k|-s|-i|-v|--silent|--verbose|--location|-L|--globoff|-g)$' {
                $i++; continue
            }
            '^-' { $i++; continue }
            default {
                if ($null -eq $url -and $t -match '^https?://') { $url = $t }
                $i++; continue
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($url)) { throw '没解析出 URL。请确认复制的是完整的 curl 命令。' }
    if ([string]::IsNullOrWhiteSpace($method)) {
        $method = 'GET'
        if (-not [string]::IsNullOrEmpty($body)) { $method = 'POST' }
    }

    return [pscustomobject]@{
        Url     = $url
        Method  = $method
        Headers = $headers
        Body    = $body
    }
}

# ---------- 表单体解析 ----------
function Parse-FormBody {
    param([string]$Body)
    $pairs = New-Object System.Collections.Specialized.OrderedDictionary
    if ([string]::IsNullOrEmpty($Body)) { return $pairs }
    foreach ($seg in $Body.Split('&')) {
        if ([string]::IsNullOrEmpty($seg)) { continue }
        $idx = $seg.IndexOf('=')
        if ($idx -lt 0) { $k = $seg; $v = '' }
        else { $k = $seg.Substring(0, $idx); $v = $seg.Substring($idx + 1) }
        try { $k = [System.Uri]::UnescapeDataString($k.Replace('+', ' ')) } catch { }
        try { $v = [System.Uri]::UnescapeDataString($v.Replace('+', ' ')) } catch { }
        if ($pairs.Contains($k)) { $pairs[$k] = [string]$pairs[$k] + ',' + $v } else { $pairs[$k] = $v }
    }
    return $pairs
}

function Test-LooksHashed {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '^[0-9a-fA-F]{32}$') { return $true }
    if ($Value -match '^[0-9a-fA-F]{40}$') { return $true }
    if ($Value -match '^[0-9a-fA-F]{64}$') { return $true }
    if ($Value.Length -ge 24 -and $Value -match '^[A-Za-z0-9+/]+={0,2}$') { return $true }
    return $false
}

function Find-Field {
    param($Body, [string[]]$Candidates, [string[]]$Exclude = @())
    foreach ($c in $Candidates) {
        foreach ($k in $Body.Keys) {
            if ($Exclude -contains $k) { continue }
            if ($k.ToLower() -eq $c) { return $k }
        }
    }
    foreach ($k in $Body.Keys) {
        if ($Exclude -contains $k) { continue }
        $lk = $k.ToLower()
        foreach ($c in $Candidates) { if ($lk -like "*$c*") { return $k } }
    }
    return $null
}

# ---------- 不转义中文的 JSON 输出 ----------
function ConvertTo-JsonText {
    param($Object, [int]$Depth = 10)
    $json = $Object | ConvertTo-Json -Depth $Depth
    # PowerShell 5.1 会把非 ASCII 转成 \uXXXX，这里还原，方便手改配置文件
    $json = [regex]::Replace($json, '(?<!\\)\\u([0-9a-fA-F]{4})', {
        param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16)
    })
    return $json
}

# ============================================================
#  主流程
# ============================================================

$raw = $null
if ($CurlText) { $raw = $CurlText }
elseif ($CurlFile) {
    if (-not (Test-Path -LiteralPath $CurlFile)) { throw "找不到文件：$CurlFile" }
    $raw = Read-TextFileAuto -Path $CurlFile
}
elseif ($FromClipboard) {
    try { $raw = Get-Clipboard -Raw -ErrorAction Stop } catch { $raw = Get-Clipboard }
}
else {
    Write-Host ''
    Info '请把浏览器里的 "Copy as cURL" 内容粘贴到下面（可多行），粘贴完按一次空回车结束：'
    Write-Host ''
    $lines = New-Object System.Collections.ArrayList
    while ($true) {
        $line = Read-Host
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        [void]$lines.Add($line)
    }
    $raw = ($lines -join "`n")
}

if ([string]::IsNullOrWhiteSpace($raw)) { throw '没有拿到 curl 内容。' }

Info '解析 curl 命令...'
$parsed = Parse-CurlCommand -Raw $raw
Good ('URL    : {0}' -f $parsed.Url)
Good ('Method : {0}' -f $parsed.Method)
if ($parsed.Headers.Count -gt 0) {
    foreach ($k in $parsed.Headers.Keys) {
        if ($k -match '(?i)^cookie$') { Info ("Header : {0}: <已省略 {1} 字符>" -f $k, ([string]$parsed.Headers[$k]).Length) }
        else { Info ("Header : {0}: {1}" -f $k, $parsed.Headers[$k]) }
    }
}

$notes   = New-Object System.Collections.ArrayList
$bodyObj = New-Object System.Collections.Specialized.OrderedDictionary

$contentType = ''
foreach ($k in $parsed.Headers.Keys) { if ($k -match '(?i)^content-type$') { $contentType = [string]$parsed.Headers[$k] } }

if ([string]::IsNullOrEmpty($parsed.Body)) {
    [void]$notes.Add('抓到的请求没有请求体。如果登录确实带 body，请重新抓取（确认选中的是登录那一条请求）。')
    Warn '请求体为空，账号/密码字段无法自动识别，请手工补全 config.json 里的 login.body。'
} else {
    $form = Parse-FormBody -Body $parsed.Body
    foreach ($k in $form.Keys) { $bodyObj[$k] = $form[$k] }
    Info ('请求体字段：{0}' -f (($form.Keys) -join ', '))
}

# ---- 识别账号 / 密码字段 ----
$userCandidates = @(
    'username', 'user_name', 'userid', 'user_id', 'user', 'account', 'accountname',
    'loginname', 'login', 'uname', 'stu_id', 'stuid', 'studentid', 'xh', 'uid',
    'mobile', 'phone', 'tel', 'email', 'empno', 'jobno', 'name'
)
$passCandidates = @(
    'password', 'passwd', 'pwd', 'pass', 'pass_word', 'userpwd', 'user_pwd',
    'pwdhash', 'password2', 'secret'
)

$detectedUser = $UserField
$detectedPass = $PassField

if (-not $detectedPass -and $bodyObj.Count -gt 0) {
    foreach ($k in $bodyObj.Keys) {
        if (Test-LooksHashed ([string]$bodyObj[$k])) { $detectedPass = $k; break }
    }
}

if (-not $detectedUser) { $detectedUser = Find-Field -Body $bodyObj -Candidates $userCandidates -Exclude @($detectedPass) }
if (-not $detectedPass) { $detectedPass = Find-Field -Body $bodyObj -Candidates $passCandidates -Exclude @($detectedUser) }

$passWasHashed = $false
if ($detectedPass -and $bodyObj.Contains($detectedPass)) {
    $passWasHashed = Test-LooksHashed ([string]$bodyObj[$detectedPass])
}

if ($detectedUser) { $bodyObj[$detectedUser] = '{user}' }
else { [void]$notes.Add('未能自动识别账号字段，请手工把 login.body 里对应字段的值改成 {user}。') }

if ($detectedPass) { $bodyObj[$detectedPass] = '{pass}' }
else { [void]$notes.Add('未能自动识别密码字段，请手工把 login.body 里对应字段的值改成 {pass}。') }

if ($detectedUser) { Good ('账号字段 : {0}' -f $detectedUser) } else { Warn '账号字段：未识别' }
if ($detectedPass) { Good ('密码字段 : {0}' -f $detectedPass) } else { Warn '密码字段：未识别' }

if ($passWasHashed) {
    [void]$notes.Add('抓到的密码值是哈希/加密串，说明该页面在浏览器端对密码做了处理（常见于深澜 Srun 等）。直接用 {pass} 明文可能不通过，需要看登录页 JS 里的加密逻辑，改用 {pass_md5} / {pass_sha1} / {pass_b64} 之一，或带 salt 的组合。')
    Warn '密码字段的值看起来是哈希，明文可能不通过 —— 见 config.json 的 _notes。'
}

# ---- 常见动态字段提示 ----
foreach ($k in $bodyObj.Keys) {
    if ($k -match '(?i)^(token|challenge|captcha|nonce|sign|signature|callback)$') {
        [void]$notes.Add("请求体里存在动态字段 [$k]。如果它每次登录都变，需要用 preRequests 先请求登录页并用正则提取，再把该字段值写成 {$k}。参见 README 的『进阶：带 token / challenge 的 Portal』。")
    }
}

# ---- 组装 config ----
$headersOut = New-Object System.Collections.Specialized.OrderedDictionary
foreach ($k in $parsed.Headers.Keys) {
    if ($k -match '(?i)^(host|content-length|connection|accept-encoding|cookie|content-type)$') { continue }
    $headersOut[$k] = [string]$parsed.Headers[$k]
}

$hostName = 'portal'
try { $hostName = ([System.Uri]$parsed.Url).Host } catch { }
if ($PortalName) { $hostName = $PortalName }

$respEnc = 'utf8'
if ($contentType -match '(?i)charset=([\w\-]+)') { $respEnc = $Matches[1] }
if ([string]::IsNullOrEmpty($contentType)) { $contentType = 'application/x-www-form-urlencoded' }

$config = [ordered]@{
    portalName              = $hostName
    _notes                  = @($notes)
    allowInvalidCertificate = $false
    responseEncoding        = $respEnc
    verifyUrl               = 'http://www.msftconnecttest.com/connecttest.txt'
    verifyExpect            = 'Microsoft Connect Test'
    successKeywords         = @('成功', 'success', '已上线', '已登录')
    failureKeywords         = @('失败', '错误', '密码', '不存在', '欠费', '已禁用', 'error')
    credentials             = [ordered]@{
        user        = [string]$User
        password    = ''
        passwordEnc = ''
    }
    preRequests             = @()
    login                   = [ordered]@{
        url         = $parsed.Url
        method      = $parsed.Method
        contentType = $contentType
        headers     = $headersOut
        body        = $bodyObj
    }
}

if ([string]::IsNullOrEmpty($OutFile)) {
    # 带 [CmdletBinding()] 时 $PSScriptRoot 在 param() 默认值里是空字符串，这里在函数体里解析
    # $PSScriptRoot 本身已经是目录；只有退回到"脚本文件路径"时才需要取父目录
    $cfgDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($cfgDir)) {
        $cfgPath = $PSCommandPath
        if ([string]::IsNullOrEmpty($cfgPath)) { $cfgPath = $MyInvocation.MyCommand.Definition }
        if ([string]::IsNullOrEmpty($cfgPath)) { $cfgPath = $MyInvocation.MyCommand.Path }
        if (-not [string]::IsNullOrEmpty($cfgPath)) { $cfgDir = Split-Path -Parent $cfgPath }
    }
    if ([string]::IsNullOrEmpty($cfgDir)) { $cfgDir = (Get-Location).Path }
    $OutFile = Join-Path $cfgDir 'config.json'
}

if (Test-Path -LiteralPath $OutFile) {
    if (-not $Force) {
        $backup = $OutFile + '.bak-' + (Get-Date -Format 'yyyyMMddHHmmss')
        Copy-Item -LiteralPath $OutFile -Destination $backup -Force
        Info ('已备份原配置到 {0}' -f $backup)
    }
}

$json = ConvertTo-JsonText -Object $config -Depth 10
# 带 BOM 写出：这样在 Windows PowerShell 5.1 里直接 Get-Content / 记事本打开 config.json
# 也能正常显示中文关键词。脚本自身用 Read-TextFileAuto 读取，两种编码都兼容。
[System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($true)))
Good ('配置已写入：{0}' -f $OutFile)

Write-Host ''
Info '下一步：'
Write-Host '  1) 打开 config.json 核对 login.url / login.body 字段名是否符合预期；'
Write-Host '  2) 运行 .\Set-PortalCredential.ps1 录入账号密码（DPAPI 加密，不落明文）；'
Write-Host '  3) 运行 .\CampusNetLogin.ps1 -DryRun -Force 检查将要发送的请求；'
Write-Host '  4) 运行 .\CampusNetLogin.ps1 -Force 实测一次；'
Write-Host '  5) 成功后再运行 .\Install-AutoLogin.ps1 注册开机自动任务。'
Write-Host ''

if ($notes.Count -gt 0) {
    Warn ('有 {0} 条需要你确认的提示，已写入 config.json 的 _notes 字段：' -f $notes.Count)
    foreach ($n in $notes) { Write-Host ('    - ' + $n) -ForegroundColor Yellow }
}
