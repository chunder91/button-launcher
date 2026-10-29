// ButtonLauncher.exe - tiny starter for Launcher.ps1 (no console window).
// Starts: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "<exe dir>\Launcher.ps1" [args]
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Button Launcher")]
[assembly: AssemblyDescription("Starts the Button Launcher panels")]
[assembly: AssemblyCompany("Keystone Bingo Supply")]
[assembly: AssemblyProduct("Button Launcher")]
[assembly: AssemblyCopyright("Keystone Bingo Supply")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]
[assembly: AssemblyInformationalVersion("1.1.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
        string script = Path.Combine(dir, "Launcher.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Launcher.ps1 was not found next to ButtonLauncher.exe:\n\n" + dir +
                "\n\nReinstall the launcher, or put ButtonLauncher.exe back in its folder.",
                "Button Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        var sb = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File ");
        sb.Append(Quote(script));
        foreach (string a in args) { sb.Append(' ').Append(Quote(a)); }
        // R-M3: only the real Windows PowerShell 5.1. No bare "powershell.exe" fallback, which Windows could resolve
        // from the user-writable install folder first.
        string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps))
        {
            MessageBox.Show("Windows PowerShell was not found at:\n\n" + ps +
                "\n\nButton Launcher needs Windows PowerShell 5.1, which is part of Windows.",
                "Button Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 3;
        }
        var psi = new ProcessStartInfo(ps, sb.ToString())
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir
        };
        try { Process.Start(psi); return 0; }
        catch (Exception ex)
        {
            MessageBox.Show("Couldn't start PowerShell:\n\n" + ex.Message, "Button Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }

    // Windows command-line quoting (CommandLineToArgvW rules).
    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
        var sb = new StringBuilder("\"");
        int bs = 0;
        foreach (char c in s)
        {
            if (c == '\\') { bs++; continue; }
            if (c == '"') { sb.Append('\\', bs * 2 + 1).Append('"'); bs = 0; continue; }
            sb.Append('\\', bs).Append(c); bs = 0;
        }
        sb.Append('\\', bs * 2).Append('"');
        return sb.ToString();
    }
}
