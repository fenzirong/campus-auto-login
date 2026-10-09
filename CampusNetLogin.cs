// CampusNetLogin.cs —— 校园网 Portal 自动登录（编译为单文件 WinExe，无控制台窗口）
//
// 由 build-exe.ps1 调用 csc.exe 编译，产物 CampusNetLogin.exe。
// 运行特性：
//   * -target:winexe → 天生无控制台窗口，后台静默运行
//   * 连接阶段有硬性时间预算（默认 15 秒，connectDeadlineSeconds）
//   * 认证成功后保持 N 秒（默认 300 秒，autoExitSeconds）再自动退出
//   * 保持期内检测到掉线会尝试补认证，但不延长保持期
//   * 与 CampusNetLogin.ps1 共用同一份 config.json（字段完全一致）
//
// 命令行：
//   --config <path>     指定配置文件（默认 exe 同目录 config.json）
//   --log <dir>         指定日志目录（默认 exe 同目录 logs）
//   --exit-after <sec>  覆盖保持时长（0 = 认证成功立即退出）
//   --once              认证成功立即退出
//   --dry-run           只打印将要发送的请求，不真正发送
//   --diagnose          打印网络与 Portal 可达性诊断后退出
//   --force             即使当前已联网也强制认证一次
//   --quiet             不输出到控制台（日志文件照写）

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

internal static class Program
{
    // build-exe.ps1 -EmbedConfig 会把这里替换成真实配置内容（原样字符串），
    // 使 exe 在没有外部 config.json 时也能独立运行。
    private const string EmbeddedConfig = @"__EMBEDDED_CONFIG__";

    private static string _logPath;
    private static bool _quiet;
    private static bool _hasConsole;
    private static readonly object _logLock = new object();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();

    // ============================================================
    //  日志
    // ============================================================

    private static void Log(string level, string message)
    {
        string line = string.Format(CultureInfo.InvariantCulture,
            "[{0}] [{1}] {2}", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff"), level, message);

        if (_hasConsole && !_quiet)
        {
            try
            {
                switch (level)
                {
                    case "OK":    Console.ForegroundColor = ConsoleColor.Green;  break;
                    case "WARN":  Console.ForegroundColor = ConsoleColor.Yellow; break;
                    case "ERROR": Console.ForegroundColor = ConsoleColor.Red;    break;
                    case "STEP":  Console.ForegroundColor = ConsoleColor.Cyan;   break;
                    default:      Console.ForegroundColor = ConsoleColor.Gray;   break;
                }
                Console.WriteLine(line);
                Console.ResetColor();
            }
            catch { }
        }

        if (_logPath != null)
        {
            lock (_logLock)
            {
                try { File.AppendAllText(_logPath, line + Environment.NewLine, new UTF8Encoding(false)); }
                catch { }
            }
        }
    }

    private static void InitConsole()
    {
        try
        {
            if (!AttachConsole(-1)) AllocConsole();
            _hasConsole = true;
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
        }
        catch { _hasConsole = false; }
    }

    // ============================================================
    //  配置读取辅助
    // ============================================================

    private static object Get(Dictionary<string, object> d, string key)
    {
        object v;
        if (d != null && d.TryGetValue(key, out v)) return v;
        return null;
    }

    private static Dictionary<string, object> GetObj(Dictionary<string, object> d, string key)
    {
        return Get(d, key) as Dictionary<string, object>;
    }

    private static List<object> GetList(Dictionary<string, object> d, string key)
    {
        object v = Get(d, key);
        if (v == null) return new List<object>();

        List<object> list = v as List<object>;
        if (list != null) return list;

        // 关键：JavaScriptSerializer 在目标类型为 object 时，JSON 数组会反序列化成
        // ArrayList（既不是 List<object> 也不是 object[]）。这里统一按 IEnumerable 收口，
        // 否则 preRequests / successKeywords / failureKeywords 会全部被当成空数组。
        if (!(v is string))
        {
            System.Collections.IEnumerable en = v as System.Collections.IEnumerable;
            if (en != null)
            {
                List<object> outList = new List<object>();
                foreach (object item in en) outList.Add(item);
                return outList;
            }
        }
        return new List<object>();
    }

    private static string GetStr(Dictionary<string, object> d, string key, string def)
    {
        object v = Get(d, key);
        if (v == null) return def;
        string s = v as string;
        if (s != null) return s;
        return Convert.ToString(v, CultureInfo.InvariantCulture);
    }

    private static int GetInt(Dictionary<string, object> d, string key, int def)
    {
        object v = Get(d, key);
        if (v == null) return def;
        try { return Convert.ToInt32(v, CultureInfo.InvariantCulture); } catch { return def; }
    }

    private static bool GetBool(Dictionary<string, object> d, string key, bool def)
    {
        object v = Get(d, key);
        if (v == null) return def;
        if (v is bool) return (bool)v;
        string s = Convert.ToString(v, CultureInfo.InvariantCulture);
        if (string.IsNullOrEmpty(s)) return def;
        return s.Equals("true", StringComparison.OrdinalIgnoreCase) || s == "1";
    }

    // ============================================================
    //  编码 / 文本工具
    // ============================================================

    private static Encoding GetEncoding(string name)
    {
        if (string.IsNullOrEmpty(name)) return new UTF8Encoding(false);
        switch (name.Trim().ToLowerInvariant())
        {
            case "gbk":
            case "gb2312":
            case "gb18030": return Encoding.GetEncoding(936);
            case "utf-8":
            case "utf8":    return new UTF8Encoding(false);
            case "ascii":   return Encoding.ASCII;
            case "utf-16":
            case "unicode": return Encoding.Unicode;
            default:        return new UTF8Encoding(false);
        }
    }

    // 自动识别 UTF-8 / UTF-8 BOM / UTF-16 / GBK，避免记事本另存为 ANSI 后中文关键词变乱码
    private static string ReadTextAuto(string path)
    {
        byte[] b = File.ReadAllBytes(path);
        if (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF)
            return Encoding.UTF8.GetString(b, 3, b.Length - 3);
        if (b.Length >= 2 && b[0] == 0xFF && b[1] == 0xFE)
            return Encoding.Unicode.GetString(b, 2, b.Length - 2);
        if (b.Length >= 2 && b[0] == 0xFE && b[1] == 0xFF)
            return Encoding.BigEndianUnicode.GetString(b, 2, b.Length - 2);
        try { return new UTF8Encoding(false, true).GetString(b); }
        catch { return Encoding.GetEncoding(936).GetString(b); }
    }

    private static string Expand(string text, Dictionary<string, string> vars)
    {
        if (text == null) return null;
        string outText = text;
        foreach (KeyValuePair<string, string> kv in vars)
            outText = outText.Replace("{" + kv.Key + "}", kv.Value ?? "");
        return outText;
    }

    private static string HashHex(string text, string algo)
    {
        using (HashAlgorithm h = HashAlgorithm.Create(algo))
        {
            byte[] b = h.ComputeHash(Encoding.UTF8.GetBytes(text ?? ""));
            StringBuilder sb = new StringBuilder(b.Length * 2);
            foreach (byte x in b) sb.Append(x.ToString("x2", CultureInfo.InvariantCulture));
            return sb.ToString();
        }
    }

    private static string B64(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
    }

    // 部分 Portal 返回 JSON 时把中文写成 \uXXXX，不还原就匹配不到中文关键词
    private static string ExpandJsonEscapes(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        try
        {
            return Regex.Replace(text, @"(?<!\\)\\u([0-9a-fA-F]{4})", delegate (Match m)
            {
                return ((char)Convert.ToInt32(m.Groups[1].Value, 16)).ToString();
            });
        }
        catch { return text; }
    }

    private static byte[] HexToBytes(string hex)
    {
        if (hex == null) throw new ArgumentNullException("hex");
        hex = hex.Trim();
        if (hex.Length == 0 || hex.Length % 2 != 0) throw new FormatException("十六进制长度非法");
        byte[] b = new byte[hex.Length / 2];
        for (int i = 0; i < b.Length; i++)
            b[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        return b;
    }

    // ============================================================
    //  密码（明文 / DPAPI CurrentUser / DPAPI LocalMachine）
    // ============================================================

    private static string DecryptDpapi(string hex, DataProtectionScope scope)
    {
        byte[] blob = HexToBytes(hex);
        byte[] plain = ProtectedData.Unprotect(blob, null, scope);
        // ConvertFrom-SecureString 加密的明文是 UTF-16LE
        return Encoding.Unicode.GetString(plain);
    }

    private static string GetPassword(Dictionary<string, object> creds)
    {
        if (creds == null) return "";

        string plain = GetStr(creds, "password", "");
        if (!string.IsNullOrEmpty(plain)) return plain;

        string encUser = GetStr(creds, "passwordEnc", "");
        if (!string.IsNullOrEmpty(encUser))
        {
            try { return DecryptDpapi(encUser, DataProtectionScope.CurrentUser); }
            catch (Exception ex)
            {
                throw new Exception(
                    "passwordEnc 解密失败（DPAPI CurrentUser 密文与当前用户+当前机器绑定，"
                    + "换机器/换用户请重新运行 Set-PortalCredential.ps1）：" + ex.Message);
            }
        }

        string encMachine = GetStr(creds, "passwordEncMachine", "");
        if (!string.IsNullOrEmpty(encMachine))
        {
            try { return DecryptDpapi(encMachine, DataProtectionScope.LocalMachine); }
            catch (Exception ex)
            {
                throw new Exception(
                    "passwordEncMachine 解密失败（DPAPI LocalMachine 密文与本机绑定，"
                    + "换机器请重新运行 Set-PortalCredential.ps1 -Machine）：" + ex.Message);
            }
        }

        return "";
    }

    // ============================================================
    //  网络信息（纯 .NET，不依赖 CIM/WMI，避免受限环境取不到）
    // ============================================================

    private sealed class NetInfo
    {
        public string Ip = "";
        public string Mac = "";
        public string Gateway = "";
        public string Adapter = "";
        public List<string> Dns = new List<string>();
        public bool Usable { get { return Gateway.Length > 0 || Ip.Length > 0; } }
    }

    private static string FormatMac(PhysicalAddress pa)
    {
        if (pa == null) return "";
        string s = pa.ToString();
        if (s.Length != 12) return s;
        StringBuilder sb = new StringBuilder(17);
        for (int i = 0; i < 12; i += 2)
        {
            if (i > 0) sb.Append('-');
            sb.Append(s.Substring(i, 2));
        }
        return sb.ToString();
    }

    private static NetInfo GetNetInfo()
    {
        NetInfo best = null;
        try
        {
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;

                IPInterfaceProperties props;
                try { props = nic.GetIPProperties(); } catch { continue; }

                string ip = null;
                foreach (UnicastIPAddressInformation ua in props.UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    string s = ua.Address.ToString();
                    if (s.StartsWith("127.", StringComparison.Ordinal)) continue;
                    if (s.StartsWith("169.254.", StringComparison.Ordinal)) continue;   // APIPA
                    ip = s;
                    break;
                }
                if (ip == null) continue;

                string gw = "";
                foreach (GatewayIPAddressInformation g in props.GatewayAddresses)
                {
                    if (g.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    gw = g.Address.ToString();
                    break;
                }

                NetInfo info = new NetInfo();
                info.Ip = ip;
                info.Gateway = gw;
                info.Adapter = nic.Name;
                info.Mac = FormatMac(nic.GetPhysicalAddress());
                foreach (IPAddress d in props.DnsAddresses)
                    if (d.AddressFamily == AddressFamily.InterNetwork) info.Dns.Add(d.ToString());

                if (gw.Length > 0) return info;      // 有网关的网卡优先
                if (best == null) best = info;
            }
        }
        catch { }

        return best ?? new NetInfo();
    }

    // ============================================================
    //  HTTP
    // ============================================================

    private sealed class HttpResult
    {
        public int Status;
        public string Content = "";
        public string Location = "";
        public string Url = "";
    }

    private static HttpResult Request(
        string url, string method, Dictionary<string, object> headers,
        string contentType, string body, Encoding enc,
        CookieContainer cookies, int timeoutSec, bool allowBadCert)
    {
        string target = url;
        if (method == "GET" && !string.IsNullOrEmpty(body))
            target += (target.IndexOf('?') >= 0 ? "&" : "?") + body;

        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(target);
        req.Method = method;
        req.Timeout = timeoutSec * 1000;
        req.ReadWriteTimeout = timeoutSec * 1000;
        req.AllowAutoRedirect = true;
        req.MaximumAutomaticRedirections = 10;
        req.CookieContainer = cookies ?? new CookieContainer();
        req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36";
        req.Accept = "*/*";
        req.KeepAlive = true;
        req.Proxy = null;                     // 校园网 Portal 一律直连

        if (allowBadCert)
            ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };

        if (headers != null)
        {
            foreach (KeyValuePair<string, object> kv in headers)
            {
                string name = kv.Key;
                string val = kv.Value == null ? "" : Convert.ToString(kv.Value, CultureInfo.InvariantCulture);
                switch (name.ToLowerInvariant())
                {
                    case "user-agent":   req.UserAgent = val;   continue;
                    case "referer":      req.Referer = val;     continue;
                    case "content-type": contentType = val;     continue;
                    case "host":         req.Host = val;        continue;
                    case "accept":       req.Accept = val;      continue;
                    case "connection":   continue;
                }
                try { req.Headers[name] = val; } catch { }
            }
        }

        if (req.Method == "POST")
        {
            if (string.IsNullOrEmpty(contentType)) contentType = "application/x-www-form-urlencoded";
            req.ContentType = contentType;
            byte[] payload = enc.GetBytes(body ?? "");
            req.ContentLength = payload.Length;
            using (Stream s = req.GetRequestStream()) s.Write(payload, 0, payload.Length);
        }

        HttpWebResponse resp = null;
        try { resp = (HttpWebResponse)req.GetResponse(); }
        catch (WebException wex)
        {
            if (wex.Response != null) resp = (HttpWebResponse)wex.Response;
            else throw;
        }

        HttpResult result = new HttpResult();
        result.Url = target;
        using (resp)
        {
            byte[] raw = new byte[0];
            try
            {
                using (Stream rs = resp.GetResponseStream())
                using (MemoryStream ms = new MemoryStream())
                {
                    if (rs != null) rs.CopyTo(ms);
                    raw = ms.ToArray();
                }
            }
            catch { }

            Encoding dec = enc;
            if (!string.IsNullOrEmpty(resp.CharacterSet))
            {
                try { dec = GetEncoding(resp.CharacterSet); } catch { }
            }
            try { result.Content = dec.GetString(raw); }
            catch { result.Content = enc.GetString(raw); }

            result.Status = (int)resp.StatusCode;
            try { result.Location = resp.Headers["Location"] ?? ""; } catch { }
        }
        return result;
    }

    // ============================================================
    //  在线判定
    // ============================================================

    private static bool IsOnline(Dictionary<string, object> cfg, int timeoutSec)
    {
        string url = GetStr(cfg, "verifyUrl", "http://www.msftconnecttest.com/connecttest.txt");
        string expect = GetStr(cfg, "verifyExpect", "Microsoft Connect Test");
        try
        {
            HttpResult r = Request(url, "GET", null, null, null,
                new UTF8Encoding(false), null, timeoutSec, true);
            if (r.Status == 204) return true;
            if (r.Status < 200 || r.Status >= 400) return false;
            if (!string.IsNullOrEmpty(expect)) return r.Content.IndexOf(expect, StringComparison.Ordinal) >= 0;
            return true;
        }
        catch { return false; }
    }

    // ============================================================
    //  模板变量
    // ============================================================

    private static Dictionary<string, string> BuildVars(
        Dictionary<string, object> cfg, NetInfo net, Dictionary<string, string> extra)
    {
        Dictionary<string, object> creds = GetObj(cfg, "credentials");
        string user = GetStr(creds, "user", "");
        string pass = GetPassword(creds);

        Dictionary<string, string> vars = new Dictionary<string, string>(StringComparer.Ordinal);
        vars["user"] = user;
        vars["pass"] = pass;
        vars["user_b64"] = B64(user);
        vars["user_md5"] = HashHex(user, "MD5");
        vars["pass_b64"] = B64(pass);
        vars["pass_md5"] = HashHex(pass, "MD5");
        vars["pass_sha1"] = HashHex(pass, "SHA1");
        vars["pass_sha256"] = HashHex(pass, "SHA256");
        vars["pass_b64md5"] = B64(HashHex(pass, "MD5"));
        vars["ip"] = net.Ip;
        vars["mac"] = net.Mac;
        vars["mac_plain"] = Regex.Replace(net.Mac ?? "", "[^0-9A-Fa-f]", "");
        vars["gateway"] = net.Gateway;
        vars["hostname"] = Environment.MachineName;
        vars["domain"] = Environment.UserDomainName;
        vars["ts"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        vars["date"] = DateTime.Now.ToString("yyyy-MM-dd");
        vars["time"] = DateTime.Now.ToString("HH:mm:ss");
        long unix = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        vars["ts_unix"] = unix.ToString(CultureInfo.InvariantCulture);
        vars["ts_ms"] = (unix * 1000L).ToString(CultureInfo.InvariantCulture);

        if (extra != null)
            foreach (KeyValuePair<string, string> kv in extra) vars[kv.Key] = kv.Value;

        return vars;
    }

    private static string BuildBody(Dictionary<string, object> login, Dictionary<string, string> vars, string contentType)
    {
        string bodyRaw = GetStr(login, "bodyRaw", "");
        if (!string.IsNullOrEmpty(bodyRaw)) return Expand(bodyRaw, vars);

        Dictionary<string, object> body = GetObj(login, "body");
        if (body == null) return "";

        bool isJson = contentType != null && contentType.ToLowerInvariant().IndexOf("json", StringComparison.Ordinal) >= 0;
        List<string> parts = new List<string>();
        // 注：.NET Dictionary 在无删除操作时按插入顺序枚举，JavaScriptSerializer 亦按文档顺序插入，
        //     因此 body 字段顺序与 config.json 中一致。
        foreach (KeyValuePair<string, object> kv in body)
        {
            string name = kv.Key;
            string val = Expand(kv.Value == null ? "" : Convert.ToString(kv.Value, CultureInfo.InvariantCulture), vars) ?? "";
            if (isJson)
            {
                parts.Add("\"" + name + "\":\"" + val.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"");
            }
            else
            {
                parts.Add(Uri.EscapeDataString(name) + "=" + Uri.EscapeDataString(val));
            }
        }
        return isJson ? "{" + string.Join(",", parts.ToArray()) + "}" : string.Join("&", parts.ToArray());
    }

    // ============================================================
    //  preRequests
    // ============================================================

    private static Dictionary<string, string> RunPreRequests(
        Dictionary<string, object> cfg, NetInfo net, CookieContainer cookies, int timeoutSec, bool dryRun)
    {
        Dictionary<string, string> extra = new Dictionary<string, string>(StringComparer.Ordinal);
        List<object> preReqs = GetList(cfg, "preRequests");
        if (preReqs.Count == 0) return extra;

        string respEncoding = GetStr(cfg, "responseEncoding", "utf8");
        bool allowBadCert = GetBool(cfg, "allowInvalidCertificate", false);
        Dictionary<string, string> preVars = BuildVars(cfg, net, null);

        foreach (object item in preReqs)
        {
            Dictionary<string, object> pre = item as Dictionary<string, object>;
            if (pre == null) continue;

            string name = GetStr(pre, "name", "");
            string url = Expand(GetStr(pre, "url", ""), preVars);
            string method = GetStr(pre, "method", "GET").ToUpperInvariant();
            if (string.IsNullOrEmpty(url)) continue;

            // dry-run 下也要真的执行 preRequests：否则 {token}/{challenge} 不会被解析，
            // --dry-run 打印出来的请求体就不是真实会发送的内容，失去排错价值。
            // preRequests 通常只是 GET 登录页，与浏览器打开登录页等价，无副作用。
            try
            {
                HttpResult r = Request(url, method, null, null, null,
                    GetEncoding(GetStr(pre, "encoding", respEncoding)), cookies, timeoutSec, allowBadCert);

                string pattern = GetStr(pre, "regex", "");
                if (!string.IsNullOrEmpty(pattern))
                {
                    int grp = GetInt(pre, "group", 1);
                    Match m = Regex.Match(r.Content, pattern);
                    if (m.Success && grp < m.Groups.Count)
                    {
                        string val = m.Groups[grp].Value;
                        extra[name] = val;
                        preVars[name] = val;
                        Log("OK", "preRequest [" + name + "] 提取成功（长度 " + val.Length + "）");
                    }
                    else
                    {
                        Log("WARN", "preRequest [" + name + "] 正则未匹配，请检查 regex。");
                    }
                }
                else
                {
                    Log("INFO", "preRequest [" + name + "] 已执行（仅取 Cookie，无正则）。");
                }
            }
            catch (Exception ex)
            {
                Log("WARN", "preRequest [" + name + "] 请求失败：" + ex.Message);
            }
        }
        return extra;
    }

    // ============================================================
    //  单次登录尝试（是否成功由调用方用真实外网连通性判定）
    // ============================================================

    private sealed class LoginOutcome
    {
        public bool DryRun;
    }

    private static LoginOutcome TryLoginOnce(
        Dictionary<string, object> cfg, NetInfo net, CookieContainer cookies,
        Dictionary<string, string> extraVars, int timeoutSec, bool dryRun)
    {
        LoginOutcome outcome = new LoginOutcome();

        Dictionary<string, object> login = GetObj(cfg, "login");
        Dictionary<string, string> vars = BuildVars(cfg, net, extraVars);

        string loginUrl = Expand(GetStr(login, "url", ""), vars);
        string method = GetStr(login, "method", "POST").ToUpperInvariant();
        string ctype = Expand(GetStr(login, "contentType", "application/x-www-form-urlencoded"), vars);
        Dictionary<string, object> headers = GetObj(login, "headers");
        string bodyText = BuildBody(login, vars, ctype);

        if (headers != null)
        {
            Dictionary<string, object> expanded = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, object> kv in headers)
                expanded[kv.Key] = Expand(kv.Value == null ? "" : Convert.ToString(kv.Value, CultureInfo.InvariantCulture), vars);
            headers = expanded;
        }

        if (dryRun)
        {
            outcome.DryRun = true;
            Log("WARN", "----- DryRun：以下内容不会真正发送 -----");
            Log("INFO", "URL         : " + loginUrl);
            Log("INFO", "Method      : " + method);
            Log("INFO", "Content-Type: " + ctype);
            if (headers != null)
                foreach (KeyValuePair<string, object> kv in headers)
                    Log("INFO", "Header      : " + kv.Key + ": " + kv.Value);
            Log("INFO", "Body        : " + bodyText);
            string masked = bodyText;
            if (!string.IsNullOrEmpty(vars["pass"]))
                masked = masked.Replace(vars["pass"], "********");
            Log("INFO", "Body(脱敏)  : " + masked);
            Log("WARN", "----- DryRun 结束 -----");
            return outcome;
        }

        Log("STEP", "尝试认证：" + method + " " + loginUrl);

        HttpResult resp = Request(loginUrl, method, headers, ctype, bodyText,
            GetEncoding(GetStr(cfg, "responseEncoding", "utf8")), cookies, timeoutSec,
            GetBool(cfg, "allowInvalidCertificate", false));

        string readable = ExpandJsonEscapes(resp.Content);
        string snippet = readable.Length > 300 ? readable.Substring(0, 300) + "..." : readable;
        Log("INFO", "响应 HTTP " + resp.Status + "：" + Regex.Replace(snippet ?? "", @"\s+", " "));

        // 剔除 "success":false / "ok":0 这类否定形态，避免把字段名当成成功标志
        string matchText = Regex.Replace(readable ?? "", @"(?i)""?[a-z_]*success""?\s*:\s*(false|0)\b", " ");

        foreach (object w in GetList(cfg, "failureKeywords"))
        {
            string s = w as string;
            if (!string.IsNullOrEmpty(s) && matchText.IndexOf(s, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                Log("WARN", "响应命中失败关键词「" + s + "」，判定本次登录失败。");
                break;
            }
        }
        return outcome;
    }

    // ============================================================
    //  诊断
    // ============================================================

    private static void Diagnose(Dictionary<string, object> cfg, string configPath)
    {
        NetInfo net = GetNetInfo();
        Log("INFO", "配置文件  : " + configPath);
        Log("INFO", "网卡      : " + net.Adapter);
        Log("INFO", "本机 IP   : " + net.Ip);
        Log("INFO", "MAC       : " + net.Mac);
        Log("INFO", "默认网关  : " + net.Gateway);
        Log("INFO", "DNS       : " + string.Join(", ", net.Dns.ToArray()));

        if (cfg != null)
        {
            string vurl = GetStr(cfg, "verifyUrl", "http://www.msftconnecttest.com/connecttest.txt");
            Log("INFO", "外网探测  : " + vurl + "  ->  " + IsOnline(cfg, 6));

            Dictionary<string, object> login = GetObj(cfg, "login");
            string loginUrl = login == null ? "" : GetStr(login, "url", "");
            if (!string.IsNullOrEmpty(loginUrl))
            {
                try
                {
                    HttpResult r = Request(loginUrl, "GET", null, null, null,
                        new UTF8Encoding(false), null, 6, GetBool(cfg, "allowInvalidCertificate", false));
                    Log("INFO", "Portal 可达: HTTP " + r.Status);
                }
                catch (Exception ex) { Log("WARN", "Portal 不可达: " + ex.Message); }
            }

            try
            {
                string p = GetPassword(GetObj(cfg, "credentials"));
                Log("INFO", "凭据解密  : 成功（密码长度 " + (p == null ? 0 : p.Length) + "）");
            }
            catch (Exception ex) { Log("ERROR", "凭据解密  : 失败 —— " + ex.Message); }
        }
        else
        {
            Log("WARN", "配置未就绪，跳过外网/Portal/凭据检查。");
        }
        Log("INFO", "诊断结束。");
    }

    // ============================================================
    //  帮助
    // ============================================================

    private static void ShowHelp()
    {
        Console.WriteLine("CampusNetLogin.exe —— 校园网 Portal 自动登录（后台静默，一键安装）");
        Console.WriteLine();
        Console.WriteLine("直接运行（不带参数）：");
        Console.WriteLine("  首次运行会弹出配置向导：粘贴浏览器抓到的 curl + 账号密码，");
        Console.WriteLine("  自动写 config.json、注册开机任务（弹一次 UAC）、然后立即认证。");
        Console.WriteLine("  之后每次运行（含开机自动触发）都直接认证，无窗口无交互。");
        Console.WriteLine();
        Console.WriteLine("常用：");
        Console.WriteLine("  --setup             强制重新进入配置向导");
        Console.WriteLine("  --reconfigure       只重写 config.json，不动计划任务");
        Console.WriteLine("  --uninstall         删除开机计划任务");
        Console.WriteLine("  --diagnose          打印网络 / Portal / 凭据诊断后退出（不触发安装）");
        Console.WriteLine("  --dry-run           只打印将要发送的请求，不真正发送（不触发安装）");
        Console.WriteLine("  --force             即使当前已联网也强制认证一次");
        Console.WriteLine("  --once              认证成功立即退出（不进入保持期）");
        Console.WriteLine("  --exit-after <sec>  覆盖保持时长（0 = 认证成功立即退出）");
        Console.WriteLine("  --no-install        本次不注册计划任务");
        Console.WriteLine();
        Console.WriteLine("脚本化安装（不弹窗，供批处理/远程部署用）：");
        Console.WriteLine("  --curl <file> --user <账号> --password <密码> [--no-install]");
        Console.WriteLine("  从 curl 文本文件生成配置并注册任务（密码用 DPAPI LocalMachine 加密落盘）");
        Console.WriteLine();
        Console.WriteLine("其它：");
        Console.WriteLine("  --config <path>     指定配置文件（默认 exe 同目录 config.json）");
        Console.WriteLine("  --log <dir>         指定日志目录（默认 exe 同目录 logs）");
        Console.WriteLine("  --quiet             不输出到控制台（日志文件照写）");
    }

    // ============================================================
    //  入口
    // ============================================================

    // ============================================================
    //  一键安装：配置向导 + 注册开机任务
    // ============================================================

    private static int RelaunchElevated(string exePath, string extraArgs)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(exePath, extraArgs);
            psi.UseShellExecute = true;
            psi.Verb = "runas";
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Log("ERROR", "提权失败或被用户取消：" + ex.Message);
            return 1;
        }
    }

    private static int DoSetup(
        string exePath, string configPath, bool reconfigure, bool noInstall, bool elevated,
        string curlFile, string userArg, string passArg, out bool handled)
    {
        handled = false;

        // ---------- 路径 A：脚本化安装（给了 --curl 就不弹窗）----------
        if (!string.IsNullOrEmpty(curlFile))
        {
            if (!File.Exists(curlFile)) { Log("ERROR", "找不到 curl 文件：" + curlFile); return 1; }
            if (string.IsNullOrEmpty(userArg)) { Log("ERROR", "--curl 模式必须同时提供 --user"); return 1; }
            if (passArg == null) { Log("ERROR", "--curl 模式必须同时提供 --password"); return 1; }

            try
            {
                ParsedRequest req = CurlParser.Parse(ReadTextAuto(curlFile));
                string enc = DpapiUtil.ProtectLocalMachine(passArg);
                Dictionary<string, object> cfg = CurlParser.BuildConfig(req, userArg, enc, !noInstall);
                JsonText.WriteFile(configPath, JsonText.Serialize(cfg));
                Log("OK", "已写入配置：" + configPath);
                Log("INFO", "登录地址：" + req.Url + "    方法：" + req.Method);
                foreach (string n in req.Notes) Log("WARN", n);
            }
            catch (Exception ex)
            {
                Log("ERROR", "解析或写配置失败：" + ex.Message);
                return 1;
            }

            if (noInstall) { Log("INFO", "--no-install：跳过计划任务注册。"); return 0; }

            if (!TaskInstaller.IsAdmin())
            {
                if (elevated) { Log("ERROR", "已提权但仍不是管理员，无法注册计划任务。"); return 1; }
                Log("INFO", "需要管理员权限注册开机任务，正在提权...");
                int rc = RelaunchElevated(exePath, "--curl \"" + curlFile + "\" --user \"" + userArg
                                                + "\" --password \"" + passArg + "\" --elevated");
                handled = true;
                return rc;
            }
            string msg;
            bool ok = TaskInstaller.Register(exePath, TaskInstaller.DefaultTaskName, out msg);
            Log(ok ? "OK" : "ERROR", msg);
            return ok ? 0 : 1;
        }

        // ---------- 路径 B：交互式向导 ----------
        bool needConfig = reconfigure || !File.Exists(configPath);

        if (needConfig)
        {
            if (!Environment.UserInteractive || TaskInstaller.IsSystemAccount())
            {
                Log("ERROR", "缺少 config.json，且当前会话无法显示配置向导。请在本机双击 exe 完成首次配置。");
                return 1;
            }
            if (!noInstall && !TaskInstaller.IsAdmin())
            {
                if (elevated) { Log("ERROR", "已提权但仍不是管理员，无法注册计划任务。"); return 1; }
                Log("INFO", "需要管理员权限注册开机任务，正在提权...");
                int rc = RelaunchElevated(exePath, "--setup --elevated");
                handled = true;
                return rc;
            }

            bool wantTask;
            string summary;
            if (!SetupWizard.Run(configPath, out wantTask, out summary))
            {
                Log("INFO", "用户取消了首次配置。");
                return 1;
            }
            Log("OK", summary);
            if (!wantTask) { Log("INFO", "用户选择不注册开机任务，仅本次运行。"); return 0; }
        }
        else if (!noInstall && !TaskInstaller.IsAdmin())
        {
            if (elevated) { Log("ERROR", "已提权但仍不是管理员，无法注册计划任务。"); return 1; }
            Log("INFO", "配置已存在，需要管理员权限注册开机任务，正在提权...");
            int rc = RelaunchElevated(exePath, "--setup --elevated");
            handled = true;
            return rc;
        }

        if (noInstall) { Log("INFO", "--no-install：跳过计划任务注册。"); return 0; }

        string m;
        bool r2 = TaskInstaller.Register(exePath, TaskInstaller.DefaultTaskName, out m);
        Log(r2 ? "OK" : "ERROR", m);
        return r2 ? 0 : 1;
    }

    private static int Main(string[] args)
    {
        try { return Run(args); }
        catch (Exception ex)
        {
            Log("ERROR", "未捕获异常：" + ex);
            return 1;
        }
    }

    private static int Run(string[] args)
    {
        ServicePointManager.SecurityProtocol |=
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
        ServicePointManager.Expect100Continue = false;

        string exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
        if (string.IsNullOrEmpty(exePath))
        {
            try { exePath = Process.GetCurrentProcess().MainModule.FileName; } catch { }
        }
        string exeDir = string.IsNullOrEmpty(exePath) ? null : Path.GetDirectoryName(exePath);
        if (string.IsNullOrEmpty(exeDir)) exeDir = AppDomain.CurrentDomain.BaseDirectory;

        string configPath = Path.Combine(exeDir, "config.json");
        string logDir = Path.Combine(exeDir, "logs");
        bool dryRun = false, diagnose = false, once = false, force = false;
        bool setup = false, uninstall = false, reconfigure = false, noInstall = false, elevated = false;
        string curlFile = null, userArg = null, passArg = null;
        int exitAfterOverride = -1;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            switch (a)
            {
                case "--config":     if (i + 1 < args.Length) configPath = args[++i]; break;
                case "--log":        if (i + 1 < args.Length) logDir = args[++i]; break;
                case "--curl":       if (i + 1 < args.Length) curlFile = args[++i]; break;
                case "--user":       if (i + 1 < args.Length) userArg  = args[++i]; break;
                case "--password":   if (i + 1 < args.Length) passArg  = args[++i]; break;
                case "--exit-after":
                    if (i + 1 < args.Length)
                    {
                        int t;
                        if (int.TryParse(args[++i], NumberStyles.Integer, CultureInfo.InvariantCulture, out t))
                            exitAfterOverride = t;
                    }
                    break;
                case "--setup":       setup = true;       break;
                case "--reconfigure": reconfigure = true; break;
                case "--no-install":  noInstall = true;   break;
                case "--elevated":    elevated = true;    break;
                case "--uninstall":   uninstall = true;   break;
                case "--dry-run":     dryRun = true;      break;
                case "--diagnose":    diagnose = true;    break;
                case "--once":        once = true;        break;
                case "--force":       force = true;       break;
                case "--quiet":       _quiet = true;      break;
                case "--help":
                case "-h":
                case "/?":            InitConsole(); ShowHelp(); return 0;
            }
        }

        // --dry-run 必须能走到"打印请求"那一步：否则机器本来就联网时会跳过登录循环，
        // 直接进入保持期，用户等 5 分钟什么也看不到。
        if (dryRun) force = true;

        if (dryRun || diagnose) InitConsole();

        try
        {
            if (!Directory.Exists(logDir)) Directory.CreateDirectory(logDir);
            _logPath = Path.Combine(logDir, "campus-net-" + DateTime.Now.ToString("yyyyMMdd") + ".log");
        }
        catch { _logPath = null; }

        // ---- 卸载 ----
        if (uninstall)
        {
            string umsg;
            bool uok = TaskInstaller.Unregister(TaskInstaller.DefaultTaskName, out umsg);
            Log(uok ? "OK" : "ERROR", umsg);
            return uok ? 0 : 1;
        }

        // ---- 一键安装：缺配置 / 缺开机任务时自动补齐，用户不需要敲任何命令 ----
        // 注意：单独用 --dry-run / --diagnose 不应触发安装（只想看诊断却弹 UAC 很烦）；
        //       但显式给了 --setup / --reconfigure / --curl 时属于用户明确要求，照常执行。
        bool explicitSetup = setup || reconfigure || !string.IsNullOrEmpty(curlFile);
        if (!diagnose && (explicitSetup || !dryRun))
        {
            bool taskDisabled = false;
            if (File.Exists(configPath))
            {
                try
                {
                    string ct = ReadTextAuto(configPath);
                    taskDisabled = Regex.IsMatch(ct, "\"installTask\"\\s*:\\s*false", RegexOptions.IgnoreCase);
                }
                catch { }
            }

            bool needSetup = explicitSetup || !File.Exists(configPath)
                          || (!noInstall && !taskDisabled
                              && !TaskInstaller.Exists(TaskInstaller.DefaultTaskName));

            if (needSetup)
            {
                Log("INFO", "检测到尚未完成配置，进入一键安装流程。");
                bool handled;
                int src = DoSetup(exePath, configPath, reconfigure, noInstall, elevated,
                                  curlFile, userArg, passArg, out handled);
                if (handled) return src;
                if (src != 0)
                {
                    // 自动安装失败（例如用户拒绝了 UAC）不应该阻断认证：
                    // 配置若已存在，认证照样能跑；用户可用 --setup 重试安装。
                    if (explicitSetup) return src;
                    Log("WARN", "自动安装未完成，继续尝试认证。可稍后运行 --setup 重试。");
                }
                else
                {
                    Log("OK", "一键安装完成，开始认证。");
                }
            }
        }

        // ---- 读取配置 ----
        string json = null;
        if (File.Exists(configPath))
        {
            try { json = ReadTextAuto(configPath); }
            catch (Exception ex) { Log("ERROR", "读取配置文件失败：" + ex.Message); return 1; }
        }
        else if (!string.IsNullOrEmpty(EmbeddedConfig) && EmbeddedConfig != "__EMBEDDED_CONFIG__")
        {
            json = EmbeddedConfig;
            configPath = "(exe 内置配置)";
            Log("INFO", "未找到外部 config.json，改用 exe 内置配置。");
        }
        else
        {
            Log("ERROR", "找不到配置文件：" + configPath + "，且本 exe 未内置配置。");
            return 1;
        }

        Dictionary<string, object> cfg = null;
        try
        {
            JavaScriptSerializer ser = new JavaScriptSerializer();
            ser.MaxJsonLength = int.MaxValue;
            cfg = ser.Deserialize<Dictionary<string, object>>(json);
        }
        catch (Exception ex)
        {
            Log("ERROR", "config.json 解析失败：" + ex.Message);
            return 1;
        }
        if (cfg == null) { Log("ERROR", "config.json 内容为空。"); return 1; }

        if (diagnose) { Diagnose(cfg, configPath); return 0; }

        Dictionary<string, object> login = GetObj(cfg, "login");
        if (login == null || string.IsNullOrEmpty(GetStr(login, "url", "")))
        {
            Log("ERROR", "config.json 缺少 login.url，请先运行 Get-PortalConfig.ps1 生成配置。");
            return 1;
        }

        int deadline = GetInt(cfg, "connectDeadlineSeconds", 15);
        if (deadline <= 0) deadline = 15;

        // 两次登录尝试之间的最小间隔。太短会在预算内打出几十次登录请求，
        // 真实校园网很可能因此临时锁定账号，默认 1.5 秒。
        int retryDelayMs = GetInt(cfg, "retryDelayMs", 1500);
        if (retryDelayMs < 0) retryDelayMs = 0;

        Log("INFO", "================ 校园网自动登录 ================");
        Log("INFO", "Portal    : " + GetStr(cfg, "portalName", "校园网"));
        Log("INFO", "连接预算  : " + deadline + " 秒");
        Log("INFO", "配置文件  : " + configPath);

        // 凭据解密失败要立刻报错，不要卡在重试循环里
        try { GetPassword(GetObj(cfg, "credentials")); }
        catch (Exception ex) { Log("ERROR", ex.Message); return 1; }

        Stopwatch sw = Stopwatch.StartNew();
        bool online = false;
        NetInfo net = null;
        CookieContainer cookies = new CookieContainer();
        Dictionary<string, string> extraVars = new Dictionary<string, string>(StringComparer.Ordinal);
        bool preDone = false;
        int attempts = 0;
        bool netEverUsable = false;

        if (!force)
        {
            if (IsOnline(cfg, 4)) { Log("OK", "当前已联网，无需登录。"); online = true; }
            else Log("STEP", "当前未联网，开始认证流程。");
        }
        else
        {
            Log("STEP", "Force 模式：跳过\"已联网\"判断。");
        }

        while (!online)
        {
            double leftSec = deadline - sw.Elapsed.TotalSeconds;
            if (leftSec <= 0) break;
            int remain = (int)Math.Ceiling(leftSec);
            if (remain < 1) remain = 1;

            if (net == null || !net.Usable)
            {
                net = GetNetInfo();
                if (!net.Usable)
                {
                    Log("STEP", "等待网络就绪（剩余 " + remain + " 秒）...");
                    Thread.Sleep(Math.Min(300, Math.Max(1, (int)(leftSec * 1000))));
                    continue;
                }
                netEverUsable = true;
                Log("OK", "网络就绪：IP=" + net.Ip + " 网关=" + net.Gateway + " 网卡=" + net.Adapter);
            }

            if (!preDone)
            {
                extraVars = RunPreRequests(cfg, net, cookies, Math.Max(1, Math.Min(5, remain)), dryRun);
                preDone = true;
                if (dryRun)
                {
                    TryLoginOnce(cfg, net, cookies, extraVars, 5, true);
                    return 0;
                }
            }

            attempts++;
            TryLoginOnce(cfg, net, cookies, extraVars, Math.Max(1, Math.Min(8, remain)), false);

            // 外网验证同样受总预算约束，否则总耗时会超出 connectDeadlineSeconds
            int leftForVerify = (int)Math.Ceiling(deadline - sw.Elapsed.TotalSeconds);
            if (leftForVerify <= 0)
            {
                Log("WARN", "时间预算已用尽，跳过本次外网验证。");
                break;
            }
            if (IsOnline(cfg, Math.Max(1, Math.Min(6, leftForVerify))))
            {
                online = true;
                break;
            }
            Log("WARN", "本次认证后外网仍不通（已用 "
                + sw.Elapsed.TotalSeconds.ToString("F1", CultureInfo.InvariantCulture) + " 秒）。");

            double stillLeft = deadline - sw.Elapsed.TotalSeconds;
            if (stillLeft <= 0) break;
            Thread.Sleep(Math.Min(retryDelayMs, Math.Max(1, (int)(stillLeft * 1000))));
        }

        if (!online)
        {
            if (!netEverUsable)
            {
                Log("ERROR", "在 " + deadline + " 秒内未获得可用 IPv4 / 默认网关，放弃本次。");
                return 3;
            }
            Log("ERROR", "在 " + deadline + " 秒预算内未能连上校园网（已尝试 " + attempts + " 次）。");
            return 2;
        }

        Log("OK", "认证完成，用时 " + sw.Elapsed.TotalSeconds.ToString("F2", CultureInfo.InvariantCulture) + " 秒。");

        // ---- 保持阶段 ----
        if (once) { Log("OK", "(--once) 不进入保持阶段，直接退出。"); return 0; }

        int hold = exitAfterOverride >= 0 ? exitAfterOverride : GetInt(cfg, "autoExitSeconds", 300);
        int checkEvery = GetInt(cfg, "holdCheckSeconds", 30);

        if (hold <= 0) { Log("OK", "autoExitSeconds=0，认证成功立即退出。"); return 0; }

        Log("OK", "保持连接 " + hold + " 秒后自动退出（掉线自愈间隔 "
            + (checkEvery > 0 ? checkEvery + " 秒" : "已关闭") + "）。");

        Stopwatch holdSw = Stopwatch.StartNew();
        while (true)
        {
            double left = hold - holdSw.Elapsed.TotalSeconds;
            if (left <= 0) break;

            int slice = checkEvery > 0
                ? Math.Min(checkEvery, (int)Math.Ceiling(left))
                : (int)Math.Ceiling(left);
            if (slice <= 0) slice = 1;
            Thread.Sleep(slice * 1000);

            if (checkEvery <= 0) continue;
            if (hold - holdSw.Elapsed.TotalSeconds <= 0) break;

            if (!IsOnline(cfg, 4))
            {
                Log("WARN", "保持期间检测到掉线，尝试重新认证。");
                if (net == null || !net.Usable) net = GetNetInfo();
                TryLoginOnce(cfg, net, cookies, extraVars, 8, false);
                if (IsOnline(cfg, 5)) Log("OK", "重新认证成功。");
                else Log("WARN", "重新认证失败，继续等待保持期结束。");
            }
        }

        Log("OK", "保持期结束，进程退出（总运行 "
            + sw.Elapsed.TotalSeconds.ToString("F1", CultureInfo.InvariantCulture) + " 秒）。");
        return 0;
    }
}
