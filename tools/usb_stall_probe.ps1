param([int]$IntervalMs = 10, [double]$SpikeMs = 6, [double]$Minutes = 60, [string]$Log = "$PSScriptRoot\usb_stall_probe.log")
# Measures how quickly the Glove80's USB stack answers control requests. Every $IntervalMs it asks the
# keyboard's USB HID interface for its product string (a GET_DESCRIPTOR control transfer that Zephyr answers
# from the same work-queue thread a settings save or Bluetooth connect can block) and times the reply.
# Prints one line per reply slower than $SpikeMs, plus a summary every 30 s. Stops after $Minutes or when a
# file usb_stall_probe.stop appears next to the script. Reads nothing but the product string.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class Probe {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string n, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr t);
    [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_GetProductString(SafeFileHandle h, byte[] buf, int len);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    static StreamWriter log;
    static void Out(string s) { string l = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + s; Console.WriteLine(l); log.WriteLine(l); }
    public static void Run(string[] paths, int intervalMs, double spikeMs, double minutes, string logPath, string stopFile) {
        log = new StreamWriter(logPath, true, new UTF8Encoding(false)); log.AutoFlush = true;
        timeBeginPeriod(1);
        Thread.CurrentThread.Priority = ThreadPriority.AboveNormal;
        SafeFileHandle h = null; string used = null; var buf = new byte[256];
        var sw = Stopwatch.StartNew(); var end = TimeSpan.FromMinutes(minutes);
        double winMax = 0, winSum = 0; int winN = 0, winFail = 0; long nextSum = 30000; bool gone = false;
        while (sw.Elapsed < end && !File.Exists(stopFile)) {
            if (h == null || h.IsInvalid) {
                foreach (var p in paths) { var t = CreateFile(p, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero); if (!t.IsInvalid) { h = t; used = p; break; } }
                if (h == null || h.IsInvalid) { if (!gone) { Out("keyboard USB interface not available; retrying every second"); gone = true; } Thread.Sleep(1000); continue; }
                if (gone || used != null) { Out("probing " + used); gone = false; }
            }
            double t0 = sw.Elapsed.TotalMilliseconds;
            bool ok = HidD_GetProductString(h, buf, buf.Length);
            double dt = sw.Elapsed.TotalMilliseconds - t0;
            if (!ok) {
                winFail++;
                int err = Marshal.GetLastWin32Error();
                if (err == 1167 || err == 2 || err == 6 || err == 22 || err == 31) { Out("request failed (error " + err + "); device gone? reopening"); h.Dispose(); h = null; Thread.Sleep(500); continue; }
            } else {
                winN++; winSum += dt; if (dt > winMax) winMax = dt;
                if (dt >= spikeMs) {
                    string start = DateTime.Now.AddMilliseconds(-dt).ToString("HH:mm:ss.fff");
                    Out(String.Format("SLOW reply: {0:F1} ms (request sent {1})", dt, start));
                }
            }
            if (sw.ElapsedMilliseconds >= nextSum) {
                nextSum += 30000;
                Out(String.Format("summary 30 s: {0} replies, mean {1:F2} ms, max {2:F1} ms, {3} failed", winN, winN > 0 ? winSum / winN : 0, winMax, winFail));
                winMax = 0; winSum = 0; winN = 0; winFail = 0;
            }
            int sleep = intervalMs - (int)dt; if (sleep > 0) Thread.Sleep(sleep);
        }
        Out("probe stopped");
    }
}
'@
Remove-Item "$PSScriptRoot\usb_stall_probe.stop" -ErrorAction SilentlyContinue
$paths = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'HID\VID_16C0&PID_27DB&COL*' } | Sort-Object InstanceId -Descending |
    ForEach-Object { $b = [string][char]92; $b + $b + "?" + $b + $_.InstanceId.Replace($b, "#") + "#{4d1e55b2-f16f-11cf-88cb-001111000030}" })
if (-not $paths) { "no Glove80 USB HID interface found"; exit 1 }
[Probe]::Run([string[]]$paths, $IntervalMs, $SpikeMs, $Minutes, $Log, "$PSScriptRoot\usb_stall_probe.stop")
