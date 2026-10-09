// SetupWizard.cs —— 一键安装向导：解析 curl → 生成 config.json → 注册开机任务
//
// 由 build-exe.ps1 与 CampusNetLogin.cs 一起编译进 CampusNetLogin.exe。
// 目标：双击 exe 即可完成全部配置，不需要用户手敲任何命令。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Security;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// ============================================================
//  DPAPI：LocalMachine 作用域（SYSTEM 身份可解密）
// ============================================================
internal static class DpapiUtil
{
    public static string ProtectLocalMachine(string plain)
    {
        byte[] blob = Encoding.Unicode.GetBytes(plain ?? "");
        byte[] enc = ProtectedData.Protect(blob, null, DataProtectionScope.LocalMachine);
        StringBuilder sb = new StringBuilder(enc.Length * 2);
        foreach (byte b in enc) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }
}

// ============================================================
//  JSON 写出（保留中文，不转义成 \uXXXX）
// ============================================================
internal static class JsonText
{
    public static string Serialize(object o)
    {
        string json = new JavaScriptSerializer().Serialize(o);
        // JavaScriptSerializer 会把非 ASCII 转成 \uXXXX，还原成真实字符，方便用户手改
        return Regex.Replace(json, @"(?<!\\)\\u([0-9a-fA-F]{4})", delegate (Match m)
        {
            return ((char)Convert.ToInt32(m.Groups[1].Value, 16)).ToString();
        });
    }

    public static void WriteFile(string path, string json)
    {
        File.WriteAllText(path, json, new UTF8Encoding(true));
    }
}

// ============================================================
//  curl 解析（Get-PortalConfig.ps1 的 C# 移植）
// ============================================================
internal sealed class ParsedRequest
{
    public string Url = "";
    public string Method = "POST";
    public string ContentType = "application/x-www-form-urlencoded";
    public Dictionary<string, string> Headers = new Dictionary<string, string>(StringComparer.Ordinal);
    public Dictionary<string, string> Body = new Dictionary<string, string>(StringComparer.Ordinal);
    public string UserField = "";
    public string PassField = "";
    public bool PasswordLooksHashed;
    public List<string> Notes = new List<string>();
}

internal static class CurlParser
{
    private static readonly string[] UserCandidates = new string[] {
        "username","user_name","userid","user_id","user","account","accountname",
        "loginname","login","uname","stu_id","stuid","studentid","xh","uid",
        "mobile","phone","tel","email","empno","jobno","name"
    };
    private static readonly string[] PassCandidates = new string[] {
        "password","passwd","pwd","pass","pass_word","userpwd","user_pwd",
        "pwdhash","password2","secret"
    };

    public static ParsedRequest Parse(string raw)
    {
        if (string.IsNullOrEmpty(raw)) throw new Exception("内容为空。");

        string text = raw.Replace("\r\n", "\n");
        text = Regex.Replace(text, @"\^\s*\n", " ");     // cmd 风格续行
        text = Regex.Replace(text, @"\\\s*\n", " ");     // bash 风格续行
        text = text.Replace("\n", " ");

        List<string> tokens = Tokenize(text);
        if (tokens.Count == 0) throw new Exception("没解析到任何内容。");

        ParsedRequest r = new ParsedRequest();
        string body = null;
        string method = null;

        for (int i = 0; i < tokens.Count; i++)
        {
            string t = tokens[i];
            string lt = t.ToLowerInvariant();

            if (lt == "curl" || lt == "curl.exe") continue;

            if (lt == "-h" || lt == "--header")
            {
                if (++i < tokens.Count)
                {
                    string h = tokens[i];
                    int idx = h.IndexOf(':');
                    if (idx > 0) r.Headers[h.Substring(0, idx).Trim()] = h.Substring(idx + 1).Trim();
                }
                continue;
            }
            if (lt == "-d" || lt == "--data" || lt == "--data-raw" || lt == "--data-binary"
                || lt == "--data-ascii" || lt == "--data-urlencode")
            {
                if (++i < tokens.Count)
                    body = body == null ? tokens[i] : body + "&" + tokens[i];
                continue;
            }
            if (lt == "-x" || lt == "--request")
            {
                if (++i < tokens.Count) method = tokens[i].ToUpperInvariant();
                continue;
            }
            if (lt == "--url")
            {
                if (++i < tokens.Count) r.Url = tokens[i];
                continue;
            }
            if (lt == "-b" || lt == "--cookie")
            {
                if (++i < tokens.Count) r.Headers["Cookie"] = tokens[i];
                continue;
            }
            if (lt == "-e" || lt == "--referer")
            {
                if (++i < tokens.Count) r.Headers["Referer"] = tokens[i];
                continue;
            }
            if (lt == "-a" || lt == "--user-agent")
            {
                if (++i < tokens.Count) r.Headers["User-Agent"] = tokens[i];
                continue;
            }
            if (lt == "--compressed" || lt == "--insecure" || lt == "-k" || lt == "-s"
                || lt == "-i" || lt == "-v" || lt == "--silent" || lt == "--verbose"
                || lt == "--location" || lt == "-l" || lt == "--globoff" || lt == "-g")
                continue;
            if (t.StartsWith("-")) continue;

            if (string.IsNullOrEmpty(r.Url) && Regex.IsMatch(t, @"^https?://")) r.Url = t;
        }

        if (string.IsNullOrEmpty(r.Url))
            throw new Exception("没解析出 URL。请确认复制的是完整的 curl 命令。");

        r.Method = !string.IsNullOrEmpty(method) ? method
                 : (!string.IsNullOrEmpty(body) ? "POST" : "GET");

        if (r.Headers.ContainsKey("Content-Type")) r.ContentType = r.Headers["Content-Type"];
        if (string.IsNullOrEmpty(r.ContentType)) r.ContentType = "application/x-www-form-urlencoded";

        // 去掉不该写进配置的请求头
        List<string> drop = new List<string>();
        foreach (KeyValuePair<string, string> kv in r.Headers)
        {
            string k = kv.Key.ToLowerInvariant();
            if (k == "host" || k == "content-length" || k == "connection"
                || k == "accept-encoding" || k == "cookie" || k == "content-type")
                drop.Add(kv.Key);
        }
        foreach (string k in drop) r.Headers.Remove(k);

        if (!string.IsNullOrEmpty(body))
        {
            foreach (KeyValuePair<string, string> kv in ParseFormBody(body))
                r.Body[kv.Key] = kv.Value;
        }
        else
        {
            r.Notes.Add("抓到的请求没有请求体。若登录确实带 body，请重新抓取（确认选中的是登录那一条请求）。");
        }

        DetectFields(r);
        return r;
    }

    private static List<string> Tokenize(string text)
    {
        List<string> tokens = new List<string>();
        StringBuilder sb = new StringBuilder();
        char quote = '\0';
        for (int i = 0; i < text.Length; i++)
        {
            char ch = text[i];
            if (quote != '\0')
            {
                if (ch == quote) { quote = '\0'; continue; }
                if (quote == '"' && ch == '\\' && i + 1 < text.Length)
                {
                    char nx = text[i + 1];
                    if (nx == '"' || nx == '\\') { sb.Append(nx); i++; continue; }
                }
                sb.Append(ch);
                continue;
            }
            if (ch == '\'' || ch == '"') { quote = ch; continue; }
            if (char.IsWhiteSpace(ch))
            {
                if (sb.Length > 0) { tokens.Add(sb.ToString()); sb.Length = 0; }
                continue;
            }
            sb.Append(ch);
        }
        if (sb.Length > 0) tokens.Add(sb.ToString());
        return tokens;
    }

    private static Dictionary<string, string> ParseFormBody(string body)
    {
        Dictionary<string, string> pairs = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string seg in body.Split('&'))
        {
            if (seg.Length == 0) continue;
            int idx = seg.IndexOf('=');
            string k = idx < 0 ? seg : seg.Substring(0, idx);
            string v = idx < 0 ? "" : seg.Substring(idx + 1);
            try { k = Uri.UnescapeDataString(k.Replace('+', ' ')); } catch { }
            try { v = Uri.UnescapeDataString(v.Replace('+', ' ')); } catch { }
            pairs[k] = v;
        }
        return pairs;
    }

    private static bool LooksHashed(string v)
    {
        if (string.IsNullOrEmpty(v)) return false;
        if (Regex.IsMatch(v, "^[0-9a-fA-F]{32}$")) return true;
        if (Regex.IsMatch(v, "^[0-9a-fA-F]{40}$")) return true;
        if (Regex.IsMatch(v, "^[0-9a-fA-F]{64}$")) return true;
        if (v.Length >= 24 && Regex.IsMatch(v, "^[A-Za-z0-9+/]+={0,2}$")) return true;
        return false;
    }

    private static string FindField(Dictionary<string, string> body, string[] candidates, string exclude)
    {
        foreach (string c in candidates)
            foreach (KeyValuePair<string, string> kv in body)
                if (kv.Key != exclude && kv.Key.ToLowerInvariant() == c) return kv.Key;
        foreach (KeyValuePair<string, string> kv in body)
        {
            if (kv.Key == exclude) continue;
            string lk = kv.Key.ToLowerInvariant();
            foreach (string c in candidates)
                if (lk.Contains(c)) return kv.Key;
        }
        return "";
    }

    private static void DetectFields(ParsedRequest r)
    {
        // 先按"值看起来像哈希"猜密码字段
        foreach (KeyValuePair<string, string> kv in r.Body)
        {
            if (LooksHashed(kv.Value)) { r.PassField = kv.Key; r.PasswordLooksHashed = true; break; }
        }
        if (string.IsNullOrEmpty(r.UserField)) r.UserField = FindField(r.Body, UserCandidates, r.PassField);
        if (string.IsNullOrEmpty(r.PassField)) r.PassField = FindField(r.Body, PassCandidates, r.UserField);

        if (!string.IsNullOrEmpty(r.UserField)) r.Body[r.UserField] = "{user}";
        else r.Notes.Add("未能自动识别账号字段，请手工把请求体里对应字段的值改成 {user}。");

        if (!string.IsNullOrEmpty(r.PassField)) r.Body[r.PassField] = "{pass}";
        else r.Notes.Add("未能自动识别密码字段，请手工把请求体里对应字段的值改成 {pass}。");

        if (r.PasswordLooksHashed)
            r.Notes.Add("抓到的密码值是哈希/加密串，说明该页面在浏览器端对密码做了处理。直接用 {pass} 明文可能不通过，"
                      + "需要看登录页 JS 的加密逻辑，改用 {pass_md5} / {pass_sha1} / {pass_b64} 之一。");

        foreach (KeyValuePair<string, string> kv in r.Body)
        {
            if (Regex.IsMatch(kv.Key, "(?i)^(token|challenge|captcha|nonce|sign|signature|callback)$"))
                r.Notes.Add("请求体里存在动态字段 [" + kv.Key + "]。如果它每次登录都变，需要配置 preRequests 提取（见 README）。");
        }
    }

    // 把解析结果拼成 config.json 的字典结构
    public static Dictionary<string, object> BuildConfig(ParsedRequest r, string user, string passEncMachine, bool installTask)
    {
        string host = "portal";
        try { host = new Uri(r.Url).Host; } catch { }

        string respEnc = "utf8";
        Match m = Regex.Match(r.ContentType ?? "", "(?i)charset=([\\w\\-]+)");
        if (m.Success) respEnc = m.Groups[1].Value;

        Dictionary<string, object> bodyObj = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (KeyValuePair<string, string> kv in r.Body) bodyObj[kv.Key] = kv.Value;

        Dictionary<string, object> headersObj = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (KeyValuePair<string, string> kv in r.Headers) headersObj[kv.Key] = kv.Value;

        Dictionary<string, object> creds = new Dictionary<string, object>(StringComparer.Ordinal);
        creds["user"] = user ?? "";
        creds["password"] = "";
        creds["passwordEnc"] = "";
        creds["passwordEncMachine"] = passEncMachine ?? "";

        Dictionary<string, object> login = new Dictionary<string, object>(StringComparer.Ordinal);
        login["url"] = r.Url;
        login["method"] = r.Method;
        login["contentType"] = string.IsNullOrEmpty(r.ContentType) ? "application/x-www-form-urlencoded" : r.ContentType;
        login["headers"] = headersObj;
        login["body"] = bodyObj;

        Dictionary<string, object> cfg = new Dictionary<string, object>(StringComparer.Ordinal);
        cfg["portalName"] = host;
        cfg["_notes"] = r.Notes.ToArray();
        cfg["allowInvalidCertificate"] = false;
        cfg["responseEncoding"] = respEnc;
        cfg["verifyUrl"] = "http://www.msftconnecttest.com/connecttest.txt";
        cfg["verifyExpect"] = "Microsoft Connect Test";
        cfg["successKeywords"] = new string[] { "成功", "success", "已上线", "已登录" };
        cfg["failureKeywords"] = new string[] { "失败", "错误", "密码", "不存在", "欠费", "已禁用", "error" };
        cfg["connectDeadlineSeconds"] = 15;
        cfg["retryDelayMs"] = 1500;
        cfg["autoExitSeconds"] = 300;
        cfg["holdCheckSeconds"] = 30;
        cfg["credentials"] = creds;
        cfg["preRequests"] = new object[0];
        cfg["installTask"] = installTask;
        cfg["login"] = login;
        return cfg;
    }
}

// ============================================================
//  计划任务安装器（schtasks + XML，可精确控制开机触发与失败重试）
// ============================================================
internal static class TaskInstaller
{
    public const string DefaultTaskName = "CampusNet-AutoLogin";

    public static bool IsAdmin()
    {
        try
        {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    public static bool IsSystemAccount()
    {
        try
        {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
                return id.User != null && id.User.Value == "S-1-5-18";
        }
        catch { return false; }
    }

    public static bool Exists(string taskName)
    {
        ProcResult r = Run("schtasks.exe", "/Query /TN \"" + taskName + "\"");
        return r.ExitCode == 0;
    }

    public static bool Register(string exePath, string taskName, out string message)
    {
        message = "";
        if (!IsAdmin())
        {
            message = "注册计划任务需要管理员权限。";
            return false;
        }

        string xml = BuildXml(exePath);
        string tmp = Path.Combine(Path.GetTempPath(), "CampusNetTask_" + Guid.NewGuid().ToString("N") + ".xml");
        try
        {
            // schtasks 读 XML 最稳的是 UTF-16 + BOM
            File.WriteAllText(tmp, xml, new UnicodeEncoding(false, true));
            ProcResult r = Run("schtasks.exe", "/Create /TN \"" + taskName + "\" /XML \"" + tmp + "\" /F");
            if (r.ExitCode != 0)
            {
                message = "schtasks 创建任务失败（退出码 " + r.ExitCode + "）：" + r.Output.Trim();
                return false;
            }
            message = "已注册计划任务：" + taskName + "（开机后 5 秒，SYSTEM 身份，失败自动重试 5 次）";
            return true;
        }
        finally
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
        }
    }

    public static bool Unregister(string taskName, out string message)
    {
        message = "";
        if (!IsAdmin()) { message = "删除计划任务需要管理员权限。"; return false; }
        if (!Exists(taskName)) { message = "没有找到计划任务：" + taskName; return true; }
        ProcResult r = Run("schtasks.exe", "/Delete /TN \"" + taskName + "\" /F");
        if (r.ExitCode != 0) { message = "删除失败：" + r.Output.Trim(); return false; }
        message = "已删除计划任务：" + taskName;
        return true;
    }

    private static string BuildXml(string exePath)
    {
        string cmd = SecurityElement.Escape(exePath);
        string dir = SecurityElement.Escape(Path.GetDirectoryName(exePath));
        return
            "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n" +
            "<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\n" +
            "  <RegistrationInfo>\r\n" +
            "    <Description>CampusNet Portal auto login: authenticate right after every boot.</Description>\r\n" +
            "  </RegistrationInfo>\r\n" +
            "  <Triggers>\r\n" +
            "    <BootTrigger>\r\n" +
            "      <Enabled>true</Enabled>\r\n" +
            "      <Delay>PT5S</Delay>\r\n" +
            "    </BootTrigger>\r\n" +
            "  </Triggers>\r\n" +
            "  <Principals>\r\n" +
            "    <Principal id=\"Author\">\r\n" +
            "      <UserId>S-1-5-18</UserId>\r\n" +
            "      <RunLevel>HighestAvailable</RunLevel>\r\n" +
            "    </Principal>\r\n" +
            "  </Principals>\r\n" +
            "  <Settings>\r\n" +
            "    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\r\n" +
            "    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\r\n" +
            "    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\r\n" +
            "    <AllowHardTerminate>true</AllowHardTerminate>\r\n" +
            "    <StartWhenAvailable>true</StartWhenAvailable>\r\n" +
            "    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>\r\n" +
            "    <AllowStartOnDemand>true</AllowStartOnDemand>\r\n" +
            "    <Enabled>true</Enabled>\r\n" +
            "    <Hidden>false</Hidden>\r\n" +
            "    <RunOnlyIfIdle>false</RunOnlyIfIdle>\r\n" +
            "    <WakeToRun>false</WakeToRun>\r\n" +
            "    <ExecutionTimeLimit>PT15M</ExecutionTimeLimit>\r\n" +
            "    <Priority>7</Priority>\r\n" +
            "    <RestartOnFailure>\r\n" +
            "      <Interval>PT1M</Interval>\r\n" +
            "      <Count>5</Count>\r\n" +
            "    </RestartOnFailure>\r\n" +
            "  </Settings>\r\n" +
            "  <Actions Context=\"Author\">\r\n" +
            "    <Exec>\r\n" +
            "      <Command>" + cmd + "</Command>\r\n" +
            "      <WorkingDirectory>" + dir + "</WorkingDirectory>\r\n" +
            "    </Exec>\r\n" +
            "  </Actions>\r\n" +
            "</Task>\r\n";
    }

    internal sealed class ProcResult
    {
        public int ExitCode;
        public string Output = "";
    }

    internal static ProcResult Run(string file, string args)
    {
        ProcResult res = new ProcResult();
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(file, args);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using (Process p = Process.Start(psi))
            {
                res.Output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                p.WaitForExit();
                res.ExitCode = p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            res.ExitCode = -1;
            res.Output = ex.Message;
        }
        return res;
    }
}

// ============================================================
//  一键配置向导（WinForms）
// ============================================================
internal static class SetupWizard
{
    /// <summary>
    /// 显示配置向导。返回 true 表示用户完成配置（config.json 已写出）。
    /// wantTask 输出用户是否勾选了"注册开机任务"。
    /// </summary>
    public static bool Run(string configPath, out bool wantTask, out string summary)
    {
        wantTask = true;
        summary = "";
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        ParsedRequest parsed = null;
        bool localWantTask = true;
        // C# 不允许在 lambda 里捕获 out 参数，用局部变量中转
        string localSummary = "";

        using (Form f = new Form())
        {
            f.Text = "校园网自动登录 — 首次配置";
            f.ClientSize = new Size(640, 620);
            f.StartPosition = FormStartPosition.CenterScreen;
            f.FormBorderStyle = FormBorderStyle.FixedDialog;
            f.MaximizeBox = false;
            f.MinimizeBox = false;

            int y = 12;

            Label lbTip = new Label();
            lbTip.Text = "第 1 步：把浏览器抓到的登录请求粘进来（F12 → Network → 右键登录请求 → Copy as cURL）";
            lbTip.SetBounds(14, y, 610, 20);
            f.Controls.Add(lbTip);
            y += 24;

            TextBox txtCurl = new TextBox();
            txtCurl.Multiline = true;
            txtCurl.ScrollBars = ScrollBars.Vertical;
            txtCurl.SetBounds(14, y, 610, 120);
            f.Controls.Add(txtCurl);
            y += 128;

            Button btnParse = new Button();
            btnParse.Text = "解析";
            btnParse.SetBounds(14, y, 90, 28);
            f.Controls.Add(btnParse);

            Label lbParsed = new Label();
            lbParsed.SetBounds(114, y + 5, 510, 20);
            lbParsed.ForeColor = Color.DimGray;
            lbParsed.Text = "尚未解析";
            f.Controls.Add(lbParsed);
            y += 40;

            Label lbUrl = new Label();
            lbUrl.Text = "登录地址";
            lbUrl.SetBounds(14, y, 70, 20);
            f.Controls.Add(lbUrl);
            TextBox txtUrl = new TextBox();
            txtUrl.SetBounds(90, y - 3, 534, 24);
            f.Controls.Add(txtUrl);
            y += 32;

            Label lbBody = new Label();
            lbBody.Text = "请求体";
            lbBody.SetBounds(14, y, 70, 20);
            f.Controls.Add(lbBody);
            TextBox txtBody = new TextBox();
            txtBody.Multiline = true;
            txtBody.ScrollBars = ScrollBars.Vertical;
            txtBody.SetBounds(90, y - 3, 534, 80);
            f.Controls.Add(txtBody);
            y += 92;

            Label lbUser = new Label();
            lbUser.Text = "账号";
            lbUser.SetBounds(14, y, 70, 20);
            f.Controls.Add(lbUser);
            TextBox txtUser = new TextBox();
            txtUser.SetBounds(90, y - 3, 240, 24);
            f.Controls.Add(txtUser);

            Label lbPass = new Label();
            lbPass.Text = "密码";
            lbPass.SetBounds(350, y, 40, 20);
            f.Controls.Add(lbPass);
            TextBox txtPass = new TextBox();
            txtPass.UseSystemPasswordChar = true;
            txtPass.SetBounds(394, y - 3, 230, 24);
            f.Controls.Add(txtPass);
            y += 36;

            CheckBox chkTask = new CheckBox();
            chkTask.Text = "注册为开机自动运行（需要管理员权限，会弹一次 UAC）";
            chkTask.Checked = true;
            chkTask.SetBounds(14, y, 610, 22);
            f.Controls.Add(chkTask);
            y += 28;

            Label lbNote = new Label();
            lbNote.SetBounds(14, y, 610, 40);
            lbNote.ForeColor = Color.DimGray;
            lbNote.Text = "密码使用 Windows DPAPI（LocalMachine）加密后写入 config.json，磁盘上不保存明文；"
                        + "该密文与本机绑定，换机器需重新配置。";
            f.Controls.Add(lbNote);
            y += 44;

            Button btnOk = new Button();
            btnOk.Text = "安装并开始";
            btnOk.SetBounds(400, y, 110, 30);
            f.Controls.Add(btnOk);

            Button btnCancel = new Button();
            btnCancel.Text = "取消";
            btnCancel.SetBounds(520, y, 100, 30);
            f.Controls.Add(btnCancel);

            btnParse.Click += delegate
            {
                try
                {
                    parsed = CurlParser.Parse(txtCurl.Text);
                    txtUrl.Text = parsed.Url;
                    StringBuilder sb = new StringBuilder();
                    foreach (KeyValuePair<string, string> kv in parsed.Body)
                    {
                        if (sb.Length > 0) sb.Append("&");
                        sb.Append(kv.Key).Append("=").Append(kv.Value);
                    }
                    txtBody.Text = sb.ToString();
                    lbParsed.Text = "已解析：" + parsed.Method + " " + parsed.Url
                                  + "；账号字段=" + (parsed.UserField == "" ? "未识别" : parsed.UserField)
                                  + "，密码字段=" + (parsed.PassField == "" ? "未识别" : parsed.PassField);
                    lbParsed.ForeColor = Color.Green;
                }
                catch (Exception ex)
                {
                    lbParsed.Text = "解析失败：" + ex.Message;
                    lbParsed.ForeColor = Color.Red;
                }
            };

            btnOk.Click += delegate
            {
                if (parsed == null)
                {
                    MessageBox.Show(f, "请先点「解析」。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                if (string.IsNullOrEmpty(txtUser.Text.Trim()))
                {
                    MessageBox.Show(f, "请填写账号。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                if (txtPass.Text.Length == 0)
                {
                    MessageBox.Show(f, "请填写密码。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                // 用户在界面上可能改了地址或请求体，以界面为准
                parsed.Url = txtUrl.Text.Trim();
                Dictionary<string, string> newBody = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (string seg in txtBody.Text.Split('&'))
                {
                    if (seg.Length == 0) continue;
                    int idx = seg.IndexOf('=');
                    string k = idx < 0 ? seg : seg.Substring(0, idx);
                    string v = idx < 0 ? "" : seg.Substring(idx + 1);
                    newBody[k] = v;
                }
                parsed.Body = newBody;

                try
                {
                    string enc = DpapiUtil.ProtectLocalMachine(txtPass.Text);
                    Dictionary<string, object> cfg = CurlParser.BuildConfig(parsed, txtUser.Text.Trim(), enc, chkTask.Checked);
                    JsonText.WriteFile(configPath, JsonText.Serialize(cfg));
                    localWantTask = chkTask.Checked;
                    localSummary = "已写入配置：" + configPath;
                    f.DialogResult = DialogResult.OK;
                    f.Close();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(f, "写入配置失败：" + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            };

            btnCancel.Click += delegate { f.DialogResult = DialogResult.Cancel; f.Close(); };

            f.AcceptButton = btnOk;
            f.CancelButton = btnCancel;

            if (f.ShowDialog() != DialogResult.OK) return false;
        }

        wantTask = localWantTask;
        summary = localSummary;
        return true;
    }
}
