# 校园网开机自动登录（Windows / Portal 认证）

一套配置驱动的校园网自动认证方案。**不猜协议**：先用浏览器抓出你学校真实的登录请求，转成配置，再让程序照着发。

生产运行体是 **`CampusNetLogin.exe`**（单文件、后台静默、无控制台窗口）。

| 文件 | 作用 |
| --- | --- |
| `CampusNetLogin.exe` | **生产运行体**：开机自动认证，后台静默，成功后保持一段时间再退出 |
| `CampusNetLogin.cs` | exe 主源码：认证流程 + 一键安装调度 |
| `SetupWizard.cs` | 配置向导源码：curl 解析器 + 计划任务安装器 |
| `build-exe.ps1` | 用系统自带 csc.exe 编译出 `CampusNetLogin.exe` |
| `Get-PortalConfig.ps1` | 把浏览器 "Copy as cURL" 的登录请求转成 `config.json` |
| `Set-PortalCredential.ps1` | 录入账号密码（DPAPI 加密，默认无明文落盘） |
| `Install-AutoLogin.ps1` | 注册「每次开机自动运行」的计划任务 |
| `Test-CampusNetLogin.ps1` | **自检**：本地起 mock Portal，验证 exe 的 5 项关键行为 |
| `CampusNetLogin.ps1` | 排障用 PowerShell 版（等价逻辑，支持 `-Diagnose` / `-DryRun`） |
| `config.sample.json` | 配置示例，别直接拿来用 |

> ⚠️ 所有 `.ps1` 是 **UTF-8 with BOM** 编码。Windows PowerShell 5.1 读无 BOM 的 UTF-8 脚本会按 GBK 解析、直接语法报错。用记事本另存时编码务必选「UTF-8 带 BOM」。

## exe 的行为（全部由 `config.json` 控制）

| 行为 | 默认值 | 配置项 |
| --- | --- | --- |
| 连接时间预算 | 15 秒 | `connectDeadlineSeconds` |
| 两次登录尝试的最小间隔 | 1.5 秒 | `retryDelayMs` |
| 认证成功后自动退出 | 300 秒 | `autoExitSeconds`（设 0 = 成功即退出） |
| 保持期内掉线自愈检查间隔 | 30 秒 | `holdCheckSeconds`（设 0 = 关闭） |

**后台静默**是编译层面的保证：产物是 Windows GUI 子系统程序（PE Subsystem = 2），双击或由计划任务启动都不会出现黑窗口。

---

## 一、部署步骤（目标机器上操作）

把 `CampusNetLogin.exe` 拷到目标机器任意目录（例如 `C:\CampusNet\`），**双击它**。剩下的全自动：

1. 弹出配置向导 → 粘贴浏览器抓到的 curl（F12 → Network → 右键登录请求 → **Copy as cURL**）+ 账号密码
2. 自动解析协议、用 DPAPI（LocalMachine）加密密码、写出 `config.json`
3. 自动注册开机计划任务（弹一次 UAC）
4. 立即认证一次

之后每次开机，计划任务会以 SYSTEM 身份静默运行同一个 exe 完成认证；你再双击 exe 也是直接认证，不再弹任何窗口。

```
双击 CampusNetLogin.exe
```

> 没有现成的 exe？在目标机上执行 `.\build-exe.ps1` 即可离线重建——用 Windows 自带的 `csc.exe`，无需联网、无需安装任何 SDK。

### 命令行等价用法（可选）

不想点鼠标，或需要远程 / 批处理部署时：

```powershell
cd C:\CampusNet

# 一键安装：从 curl 文件生成配置 + 注册开机任务（会弹一次 UAC）
.\CampusNetLogin.exe --curl .\curl.txt --user 你的学号 --password 你的密码

# 只生成配置，不注册任务
.\CampusNetLogin.exe --curl .\curl.txt --user 你的学号 --password 你的密码 --no-install

# 看看会发什么请求（不触发安装、不弹 UAC）
.\CampusNetLogin.exe --dry-run --force

# 诊断网络 / Portal / 凭据
.\CampusNetLogin.exe --diagnose

# 重新配置 / 卸载
.\CampusNetLogin.exe --setup
.\CampusNetLogin.exe --uninstall
```

### 可选：跑一遍自检

```powershell
.\Test-CampusNetLogin.ps1
```

本地起 mock Portal 验证 exe 的 5 项关键行为，不碰真实校园网、不改系统。

### 备用：全 PowerShell 流程

不想用向导，也可以脚本一步步来：

```powershell
.\Get-PortalConfig.ps1 -FromClipboard              # 抓包转配置
.\Set-PortalCredential.ps1 -User 你的学号 -Machine  # DPAPI LocalMachine 加密（SYSTEM 可解密）
.\Install-AutoLogin.ps1                            # 管理员身份注册开机任务
```

---

## 二、抓取真实的登录请求

每个学校的 Portal 地址、字段名、是否加密都不一样，所以这一步不能省。

1. 连上校园网（此时还没认证），浏览器打开登录页。
2. 按 `F12` → 切到 **Network** 面板 → 勾选 **Preserve log**。
3. 正常输入账号密码，点击登录。
4. 在请求列表里找那条登录请求，名字通常是 `login`、`auth`、`doLogin`、`PortalLogin`、`webauth`。
   - 判断方法：点它看 **Payload / 请求体**，里面能看到你的学号，就是它。
5. 右键该请求 → **Copy** → **Copy as cURL (bash)**（或 cmd）。
6. 回到 PowerShell：

```powershell
.\Get-PortalConfig.ps1 -FromClipboard
```

脚本会打印识别结果，比如：

```
[+] URL    : http://10.10.10.10/portal/login
[+] Method : POST
[+] 账号字段 : userName
[+] 密码字段 : passWord
```

如果账号/密码字段识别错了，手动指定重跑：

```powershell
.\Get-PortalConfig.ps1 -FromClipboard -UserField your_user_field -PassField your_pass_field
```

> 也可以把 curl 内容存成 `curl.txt`，然后 `.\Get-PortalConfig.ps1 -CurlFile .\curl.txt`。

---

## 三、config.json 字段说明

```jsonc
{
  "portalName": "10.10.10.10",          // 仅用于日志显示
  "allowInvalidCertificate": false,     // Portal 用自签名 HTTPS 证书时改成 true
  "responseEncoding": "utf8",           // 返回内容是 GBK 时改成 "gbk"

  "verifyUrl": "http://www.msftconnecttest.com/connecttest.txt",
  "verifyExpect": "Microsoft Connect Test",
  // ↑ 判定"是否真的能上外网"。校园网未认证时会劫持 HTTP 并返回登录页，
  //   所以必须比对内容，不能只看状态码。换成你自己的目标网址也行。

  "successKeywords": ["成功", "success", "已上线"],
  "failureKeywords": ["失败", "错误", "密码", "不存在", "欠费", "error"],
  // ↑ 仅用于日志诊断。最终判定永远是"外网是否真的通了"。

  "credentials": {
    "user": "20230001",
    "password": "",        // 明文（仅 Startup 模式需要）
    "passwordEnc": ""      // DPAPI 密文，由 Set-PortalCredential.ps1 写入
  },

  "preRequests": [ /* 见第五节，一般用不到 */ ],

  "login": {
    "url": "http://10.10.10.10/portal/login",
    "method": "POST",
    "contentType": "application/x-www-form-urlencoded",
    "headers": { "Referer": "http://10.10.10.10/portal/index.html" },
    "body": {
      "userName": "{user}",
      "passWord": "{pass}",
      "wlanuserip": "{ip}"
    }
  }
}
```

### `login.body` 可用占位符

| 占位符 | 含义 |
| --- | --- |
| `{user}` / `{pass}` | 账号 / 密码原文 |
| `{user_md5}` `{user_b64}` | 账号的 MD5 / Base64 |
| `{pass_md5}` `{pass_sha1}` `{pass_sha256}` | 密码的哈希（小写十六进制） |
| `{pass_b64}` `{pass_b64md5}` | 密码 Base64 / MD5 后再 Base64 |
| `{ip}` `{mac}` `{mac_plain}` `{gateway}` | 本机 IP / MAC（带冒号 / 不带冒号）/ 网关 |
| `{hostname}` `{domain}` | 计算机名 / 域 |
| `{ts}` `{date}` `{time}` `{ts_unix}` `{ts_ms}` | 时间戳 |

---

## 四、断网/离线测试

```powershell
# 查看本机网络 + Portal 是否可达
.\CampusNetLogin.ps1 -Diagnose

# 模拟断网后自动认证（先在托盘里断开 WiFi 或禁用网卡，再执行）
.\CampusNetLogin.ps1 -Force

# 看日志
Get-Content .\logs\campus-net-*.log -Tail 50
```

---

## 五、进阶：带 token / challenge 的 Portal

深澜 Srun、部分城市热点会在登录页生成一个一次性 `challenge` / `token`，登录时必须带上。这时用 `preRequests`：先请求登录页，用正则把值抠出来，再在 `login.body` 里用 `{变量名}` 引用。

```jsonc
"preRequests": [
  {
    "name": "challenge",
    "url": "http://10.10.10.10/portal/index.html",
    "method": "GET",
    "regex": "challenge\\s*=\\s*['\"]([^'\"]+)['\"]",
    "group": 1,
    "encoding": "utf8"
  }
],
"login": {
  "body": {
    "username": "{user}",
    "password": "{pass}",
    "challenge": "{challenge}"
  }
}
```

**怎么拿到正则**：在 F12 里打开登录页的 **Sources**，搜 `challenge`，看它是怎么生成的；或者在 Console 里执行 `document.documentElement.innerHTML` 把页面源码打出来，从里面找。

`preRequests` 会共享同一个 Cookie 容器，所以「先 GET 拿 session cookie、再 POST 登录」这类流程也能覆盖。

---

## 六、进阶：密码在浏览器端被哈希

如果抓到的密码字段长这样 —— `d41d8cd98f00b204e9800998ecf8427e`（32 位十六进制）或一长串 Base64 —— 说明登录页在浏览器里先把密码处理过了。此时：

1. `Get-PortalConfig.ps1` 会在 `_notes` 里给出警告；
2. 打开登录页 JS，找到加密逻辑。常见几种：
   - 纯 MD5 → 把 `"passWord": "{pass}"` 改成 `"{pass_md5}"`；
   - SHA1 → `"{pass_sha1}"`；
   - Base64 → `"{pass_b64}"`；
   - `md5(password + salt)`（salt 是固定字符串或来自页面）→ 这种情况本脚本覆盖不了，需要自己改 `CampusNetLogin.ps1`，在 `New-TemplateVars` 里加一个变量，例如：

     ```powershell
     $vars['pass_salted'] = Get-HashHex ($pass + 'your_salt_here') 'MD5'
     ```

     然后在 `login.body` 里写 `"{pass_salted}"`。

---

## 七、开机自动登录的两种模式

### 模式 A：`Logon`（默认，推荐）

```powershell
.\Install-AutoLogin.ps1
```

- 身份：当前用户，交互式运行。
- 触发：用户登录后 20 秒 + 每 10 分钟兜底一次。
- 密码可用 DPAPI 加密（`Set-PortalCredential.ps1` 默认行为），**磁盘上没有明文密码**。
- 适合：开机自动登录 Windows 的场景（此时用户会话已建立）。

### 模式 B：`Startup`（开机即认证，无需登录 Windows）

```powershell
.\Set-PortalCredential.ps1 -PlainText     # 先改成明文密码
.\Install-AutoLogin.ps1 -Mode Startup     # 以管理员身份
```

- 身份：`SYSTEM`，开机 30 秒后运行，不依赖用户登录。
- **DPAPI 密文在 SYSTEM 下无法解密，所以必须用明文密码**，务必限制文件权限：

```powershell
icacls "C:\CampusNet\config.json" /inheritance:r /grant:r "SYSTEM:(R)" "Administrators:(R)"
```

### 其它参数

```powershell
.\Install-AutoLogin.ps1 -RepeatMinutes 5   # 改兜底频率
.\Install-AutoLogin.ps1 -NoRepeat          # 只跑一次，不要兜底
.\Install-AutoLogin.ps1 -RunNow            # 注册后立刻触发一次
.\Install-AutoLogin.ps1 -Uninstall         # 卸载
```

### 为什么要有「每 10 分钟兜底」

认证会掉：笔记本合盖唤醒、WiFi 切换、DHCP 续约、学校网关强制下线。兜底任务每次先探测外网，**已联网时几毫秒就退出**，几乎不占资源；断线时自动补认证。这是整套方案里最值钱的一块。

---

## 八、排错

| 现象 | 原因 / 处理 |
| --- | --- |
| 报「意外的标记」「语句块中缺少右 }」、中文变乱码 | `.ps1` 被存成了**无 BOM 的 UTF-8**，Windows PowerShell 5.1 会按 GBK 解析导致语法错误。用记事本「另存为」时编码选 **UTF-8 带 BOM**，或重新拷一份原文件。四个脚本出厂即为 UTF-8 with BOM，别用会剥掉 BOM 的编辑器另存 |
| `config.json 缺少 login.url` | 没跑 `Get-PortalConfig.ps1`，或抓错了请求 |
| `-DryRun` 里 Body 的账号密码是空的 | 没跑 `Set-PortalCredential.ps1` |
| `passwordEnc 解密失败` | DPAPI 密文换机器/换用户了，重跑 `Set-PortalCredential.ps1` |
| 请求发出去了但外网仍不通 | 用 `-DryRun` 对比字段；确认 `responseEncoding`（GBK 页面改 `gbk`）；确认 `login.body` 里的 `{pass}` 是不是该换成 `{pass_md5}` |
| 返回乱码 | `responseEncoding` 设成 `gbk` |
| HTTPS 证书报错 | `allowInvalidCertificate` 设为 `true` |
| 日志里「命中失败关键词」但网络其实是通的 | 关键词只用于诊断，最终判定永远是外网是否真的通了；可按学校实际情况调整 `successKeywords` / `failureKeywords` |
| 计划任务跑了但没生效 | `Get-ScheduledTaskInfo -TaskName CampusNet-AutoLogin` 看 `LastTaskResult`；日志在 `logs\` |
| 提示需要管理员权限 | 右键 PowerShell →「以管理员身份运行」 |

**计划任务返回码**：`0x0` = 成功（含"本来就已联网"）；`0x1` = 配置缺失或密码解密失败；`0x2` = 登录失败（看日志）；`0x3` = 拿不到可用 IPv4 / 默认网关。

---

## 九、安全提醒

- 默认模式下密码以 DPAPI 加密存储，**只有当前用户的当前机器**能解密。拷给别人 / 换机器会直接报解密失败 —— 这是特性不是 bug。
- `-PlainText`（Startup 模式）会写明文密码，务必按第七节限制文件权限。
- `logs\` 目录里的日志会记录服务器响应内容，**不会**记录密码（`-DryRun` 输出已做脱敏）。
- 抓包得到的 `curl.txt` 里含明文密码，转完配置后建议删掉。

---

## 十、卸载

```powershell
.\Install-AutoLogin.ps1 -Uninstall         # 删计划任务
Remove-Item -Recurse -Force C:\CampusNet   # 删整个目录
```
