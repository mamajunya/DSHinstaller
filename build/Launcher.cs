// DeepSeek Harness 安装器 —— 单文件 exe 启动器
//
// 作用：把 DSHInstaller.ps1 与 deepseek.ico 作为嵌入资源打包进 exe，
//       运行时释放到 %LOCALAPPDATA%\DeepSeekHarnessInstaller\，
//       再用隐藏窗口的 Windows PowerShell 拉起图形安装向导。
//
// 目标编译器：.NET Framework 自带的 csc.exe（C# 5），无需安装任何 SDK。

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[assembly: AssemblyTitle("DeepSeek Harness 安装器")]
[assembly: AssemblyProduct("DeepSeek Harness Installer")]
[assembly: AssemblyDescription("DeepSeek Harness 一键安装向导（图形界面）")]
[assembly: AssemblyCompany("DeepSeek Harness Installer")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class Program
{
    private const string ScriptName = "DSHInstaller.ps1";
    private const string IconName = "deepseek.ico";

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int dwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    [STAThread]
    private static int Main(string[] args)
    {
        bool selfTest = HasSwitch(args, "-SelfTest");
        bool noConsole = selfTest || HasSwitch(args, "-Console");

        // -SelfTest 时把自己挂到调用者的控制台上，方便在 cmd 里看输出
        if (noConsole) { AttachConsole(-1); }

        string dir;
        string scriptPath;
        try
        {
            dir = ResolveWorkDir();
            Directory.CreateDirectory(dir);
            ExtractResource(ScriptName, Path.Combine(dir, ScriptName));
            ExtractResource(IconName, Path.Combine(dir, IconName));
            scriptPath = Path.Combine(dir, ScriptName);
        }
        catch (Exception ex)
        {
            Fail("释放内置的安装脚本失败：\r\n" + ex.Message);
            return 3;
        }

        string powershell = ResolvePowerShell();
        if (powershell == null)
        {
            Fail("找不到 Windows PowerShell（powershell.exe）。\r\n本安装器需要 Windows 7 SP1 及以上系统。");
            return 4;
        }

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = powershell;
        psi.Arguments = BuildArguments(scriptPath, args, selfTest);
        psi.WorkingDirectory = dir;

        if (selfTest)
        {
            // 自检模式：抓取子进程输出，再由本进程写到调用者的标准输出。
            // GUI 子系统 exe 里 Console.Out 是空写入器，必须自己开标准输出句柄。
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = new UTF8Encoding(false);
            psi.StandardErrorEncoding = new UTF8Encoding(false);
        }
        else
        {
            // 与「start "" powershell -WindowStyle Hidden ...」等价：有隐藏控制台，行为最接近脚本版
            psi.UseShellExecute = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
        }

        Process child;
        try
        {
            child = Process.Start(psi);
        }
        catch (Exception ex)
        {
            Fail("启动 PowerShell 失败：\r\n" + ex.Message);
            return 5;
        }
        if (child == null)
        {
            Fail("启动 PowerShell 失败：系统未返回进程句柄。");
            return 5;
        }

        if (selfTest)
        {
            StringBuilder err = new StringBuilder();
            Thread reader = new Thread(delegate() { try { err.Append(child.StandardError.ReadToEnd()); } catch { } });
            reader.IsBackground = true;
            reader.Start();
            string output = child.StandardOutput.ReadToEnd();
            child.WaitForExit();
            reader.Join(3000);
            WriteStandard(1, output);
            WriteStandard(2, err.ToString());
            return child.ExitCode;
        }

        child.WaitForExit();
        try { return child.ExitCode; }
        catch { return 0; }
    }

    /// <summary>直接往标准输出/错误句柄写字节（GUI 子系统下 Console.Out 不可靠）。</summary>
    private static void WriteStandard(int which, string text)
    {
        if (string.IsNullOrEmpty(text)) { return; }
        try
        {
            Stream s = (which == 1) ? Console.OpenStandardOutput() : Console.OpenStandardError();
            using (s)
            {
                byte[] bytes = new UTF8Encoding(false).GetBytes(text);
                s.Write(bytes, 0, bytes.Length);
                s.Flush();
            }
        }
        catch
        {
            try
            {
                if (which == 1) { Console.Out.Write(text); } else { Console.Error.Write(text); }
            }
            catch { }
        }
    }

    private static bool HasSwitch(string[] args, string name)
    {
        foreach (string a in args)
        {
            if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) { return true; }
        }
        return false;
    }

    /// <summary>脚本与图标的释放目录（固定位置，便于排查，也不容易被杀软视为随机落地）。</summary>
    private static string ResolveWorkDir()
    {
        string root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrEmpty(root)) { root = Path.GetTempPath(); }
        return Path.Combine(root, "DeepSeekHarnessInstaller");
    }

    private static string ResolvePowerShell()
    {
        string dir = Environment.GetFolderPath(Environment.SpecialFolder.System);
        if (!string.IsNullOrEmpty(dir))
        {
            string p = Path.Combine(dir, @"WindowsPowerShell\v1.0\powershell.exe");
            if (File.Exists(p)) { return p; }
        }
        dir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (!string.IsNullOrEmpty(dir))
        {
            string p = Path.Combine(dir, @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (File.Exists(p)) { return p; }
        }
        return null;
    }

    private static string BuildArguments(string scriptPath, string[] args, bool selfTest)
    {
        StringBuilder sb = new StringBuilder();
        sb.Append("-NoProfile -ExecutionPolicy Bypass");
        if (!selfTest) { sb.Append(" -WindowStyle Hidden"); }
        sb.Append(" -File \"").Append(scriptPath).Append('"');
        foreach (string a in args)
        {
            sb.Append(' ');
            if (a.IndexOf(' ') >= 0) { sb.Append('"').Append(a).Append('"'); }
            else { sb.Append(a); }
        }
        return sb.ToString();
    }

    /// <summary>把嵌入资源写到目标路径；内容一致时不重写，避免无谓的磁盘写入。</summary>
    private static void ExtractResource(string name, string target)
    {
        byte[] data = ReadResource(name);
        if (data == null) { throw new FileNotFoundException("缺少嵌入资源 " + name); }
        if (File.Exists(target))
        {
            try
            {
                byte[] old = File.ReadAllBytes(target);
                if (BytesEqual(old, data)) { return; }
            }
            catch { }
        }
        File.WriteAllBytes(target, data);
    }

    private static byte[] ReadResource(string name)
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        string found = null;
        foreach (string res in asm.GetManifestResourceNames())
        {
            if (string.Equals(res, name, StringComparison.OrdinalIgnoreCase) ||
                res.EndsWith("." + name, StringComparison.OrdinalIgnoreCase))
            {
                found = res;
                break;
            }
        }
        if (found == null) { return null; }
        using (Stream s = asm.GetManifestResourceStream(found))
        {
            if (s == null) { return null; }
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] buffer = new byte[81920];
                int read;
                while ((read = s.Read(buffer, 0, buffer.Length)) > 0) { ms.Write(buffer, 0, read); }
                return ms.ToArray();
            }
        }
    }

    private static bool BytesEqual(byte[] a, byte[] b)
    {
        if (a == null || b == null || a.Length != b.Length) { return false; }
        for (int i = 0; i < a.Length; i++) { if (a[i] != b[i]) { return false; } }
        return true;
    }

    private static void Fail(string message)
    {
        try { MessageBoxW(IntPtr.Zero, message, "DeepSeek Harness 安装器", 0x10); }
        catch { }
        try { Console.Error.WriteLine("[DSH] " + message); }
        catch { }
    }
}
