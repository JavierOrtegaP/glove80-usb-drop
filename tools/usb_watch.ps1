param([int]$QuietSecs = 300, [int]$MaxWaitSecs = 1800, [string]$Log = "$PSScriptRoot\usb_watch.log",
      [string]$DeviceId = '', [string]$BtAddress = '')
# -DeviceId: the left half's USB instance id (default: the first Glove80 left half Windows knows).
# -BtAddress: the keyboard's Bluetooth address as 12 hex digits (default: from the paired "Glove80").
# Live recorder for the Glove80 USB test. Every 100 ms: every root-hub port's state (status, VID:PID,
# speed, bus address, configuration, open pipes), the keyboard's devnode state and power state (D0/D2/D3).
# Counts key presses per path (USB vs Bluetooth) via Raw Input - counts only, never which keys.
# Ends after $QuietSecs without any change once the keyboard has shown up, after $MaxWaitSecs if it
# never shows up, or when a file named usb_watch.stop appears next to this script.
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class Watch {
    static StreamWriter log; static readonly object lk = new object();
    public static string BtAddr = "";
    public static void Open(string path) { log = new StreamWriter(path, false, new UTF8Encoding(false)); log.AutoFlush = true; }
    public static void Log(string s) { lock (lk) log.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + "  " + s); }

    // ---------- root hub ports ----------
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr ov);
    static readonly string[] Status = { "none", "connected", "FAILED-ENUMERATION", "GENERAL-FAILURE", "OVERCURRENT",
        "NOT-ENOUGH-POWER", "NOT-ENOUGH-BANDWIDTH", "nested-too-deep", "in-legacy-hub", "enumerating", "reset" };
    static readonly string[] Speed = { "low", "full", "high", "super", "super+" };
    class Hub { public string Name; public SafeFileHandle H; public int Ports; public string[] Last; }
    static readonly List<Hub> hubs = new List<Hub>();

    public static string AddHub(string name, string path) {
        var h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) h = CreateFile(path, 0x40000000, 2, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) return "cannot open " + path + ": " + Marshal.GetLastWin32Error();
        var info = new byte[512]; int ret;
        if (!DeviceIoControl(h, 0x220454, info, info.Length, info, info.Length, out ret, IntPtr.Zero)) return "hub info failed: " + Marshal.GetLastWin32Error();
        int n = BitConverter.ToUInt16(info, 4);
        hubs.Add(new Hub { Name = name, H = h, Ports = n, Last = new string[n + 1] });
        return null;
    }

    static string PortState(Hub hub, int p) {
        var c = new byte[512]; BitConverter.GetBytes(p).CopyTo(c, 0); int ret;
        if (!DeviceIoControl(hub.H, 0x220448, c, c.Length, c, c.Length, out ret, IntPtr.Zero)) return "query-error " + Marshal.GetLastWin32Error();
        int s = BitConverter.ToInt32(c, 31);
        if (s == 0) return "none";
        string st = s < Status.Length ? Status[s] : s.ToString();
        return String.Format("{0} {1:X4}:{2:X4} {3} addr {4} cfg {5} pipes {6}", st, BitConverter.ToUInt16(c, 12), BitConverter.ToUInt16(c, 14),
            c[23] < 5 ? Speed[c[23]] : c[23].ToString(), BitConverter.ToUInt16(c, 25), c[22], BitConverter.ToInt32(c, 27));
    }

    // ---------- keyboard devnode ----------
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Locate_DevNodeW(out uint devInst, string id, uint flags);
    [DllImport("cfgmgr32.dll")] static extern int CM_Get_DevNode_Status(out uint status, out uint problem, uint devInst, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct DEVPROPKEY { public Guid fmtid; public uint pid; }
    [DllImport("cfgmgr32.dll")] static extern int CM_Get_DevNode_PropertyW(uint devInst, ref DEVPROPKEY key, out uint type, byte[] buf, ref uint size, uint flags);
    static DEVPROPKEY powerKey = new DEVPROPKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 32 };
    static string DevState(string id) {
        uint di; if (CM_Locate_DevNodeW(out di, id, 0) != 0) return "absent";
        uint st, pr; if (CM_Get_DevNode_Status(out st, out pr, di, 0) != 0) return "status-error";
        string s = (st & 0x8) != 0 ? "started" : "not-started";
        if ((st & 0x400) != 0) s += " PROBLEM-CODE-" + pr;
        var buf = new byte[64]; uint size = 64, type;
        if (CM_Get_DevNode_PropertyW(di, ref powerKey, out type, buf, ref size, 0) == 0) {
            int d = BitConverter.ToInt32(buf, 4);
            s += d >= 1 && d <= 4 ? " D" + (d - 1) : " D?";
        }
        return s;
    }

    // ---------- raw input key counts ----------
    delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS { public uint style; public WndProc proc; public int cls; public int wnd; public IntPtr inst; public IntPtr icon; public IntPtr cursor; public IntPtr bg; public string menu; public string name; }
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassW(ref WNDCLASS wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG msg, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG msg);
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr hRaw, uint cmd, IntPtr data, ref uint size, uint headerSize);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint GetRawInputDeviceInfoW(IntPtr hDev, uint cmd, StringBuilder data, ref uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
    static WndProc keep;
    static readonly Dictionary<IntPtr, string> names = new Dictionary<IntPtr, string>();
    static readonly Dictionary<string, int> counts = new Dictionary<string, int>();

    static string Classify(IntPtr dev) {
        string n;
        if (names.TryGetValue(dev, out n)) return n;
        uint size = 0; GetRawInputDeviceInfoW(dev, 0x20000007, null, ref size);
        var sb = new StringBuilder((int)size + 2);
        if (size > 0) GetRawInputDeviceInfoW(dev, 0x20000007, sb, ref size);
        string s = sb.ToString().ToUpperInvariant();
        n = s.Contains("VID_16C0&PID_27DB") ? "USB" : (BtAddr.Length > 0 && s.Contains(BtAddr)) ? "BT" : dev == IntPtr.Zero ? "injected" : "other";
        names[dev] = n;
        Log("keyboard input path seen: " + n + "  " + sb.ToString());
        return n;
    }

    static IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l) {
        if (m == 0x00FF) {   // WM_INPUT
            uint hdr = (uint)(8 + 2 * IntPtr.Size), size = 0;
            GetRawInputData(l, 0x10000003, IntPtr.Zero, ref size, hdr);
            IntPtr buf = Marshal.AllocHGlobal((int)Math.Max(size, 64));
            try {
                if (GetRawInputData(l, 0x10000003, buf, ref size, hdr) == size && Marshal.ReadInt32(buf, 0) == 1) {
                    ushort flags = (ushort)Marshal.ReadInt16(buf, (int)hdr + 2);
                    if ((flags & 1) == 0) {   // key down only; the key itself is never read
                        string n = Classify(Marshal.ReadIntPtr(buf, 8));
                        lock (counts) { int c; counts.TryGetValue(n, out c); counts[n] = c + 1; }
                    }
                }
            } finally { Marshal.FreeHGlobal(buf); }
        } else if (m == 0x00FE) {   // WM_INPUT_DEVICE_CHANGE
            Log("keyboard input path " + (w.ToInt64() == 1 ? "ADDED: " : "REMOVED: ") + Classify(l));
        }
        return DefWindowProcW(h, m, w, l);
    }

    public static void StartRaw() {
        var t = new Thread(() => {
            keep = Proc;
            var wc = new WNDCLASS { proc = keep, inst = GetModuleHandleW(null), name = "UsbWatchRaw" };
            RegisterClassW(ref wc);
            IntPtr hwnd = CreateWindowExW(0, "UsbWatchRaw", "", 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, wc.inst, IntPtr.Zero);
            var rid = new[] { new RAWINPUTDEVICE { UsagePage = 1, Usage = 6, Flags = 0x100 | 0x2000, Target = hwnd } };
            if (!RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) Log("raw input registration FAILED: " + Marshal.GetLastWin32Error());
            else Log("key counting on (counts per path only)");
            MSG msg; while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) DispatchMessageW(ref msg);
        });
        t.IsBackground = true; t.SetApartmentState(ApartmentState.STA); t.Start();
    }

    // ---------- main loop ----------
    public static void Run(string devId, int quietSecs, int maxWaitSecs, string stopFile) {
        var sw = Stopwatch.StartNew(); double lastChange = 0; bool seen = false; string lastDev = null; long nextFlush = 1000;
        foreach (var hub in hubs) for (int p = 1; p <= hub.Ports; p++) { hub.Last[p] = PortState(hub, p); if (hub.Last[p] != "none") Log(hub.Name + " port " + p + ": " + hub.Last[p]); }
        lastDev = DevState(devId); Log("keyboard USB device: " + lastDev);
        while (true) {
            Thread.Sleep(100);
            foreach (var hub in hubs) for (int p = 1; p <= hub.Ports; p++) {
                string s = PortState(hub, p);
                if (s != hub.Last[p]) { Log(hub.Name + " port " + p + ": " + hub.Last[p] + "  ->  " + s); hub.Last[p] = s; lastChange = sw.Elapsed.TotalSeconds; if (s.Contains("16C0:27DB")) seen = true; }
            }
            string d = DevState(devId);
            if (d != lastDev) { Log("keyboard USB device: " + lastDev + "  ->  " + d); lastDev = d; lastChange = sw.Elapsed.TotalSeconds; if (d != "absent") seen = true; }
            if (sw.ElapsedMilliseconds >= nextFlush) {
                nextFlush += 1000;
                string line = null;
                lock (counts) { if (counts.Count > 0) { var parts = new List<string>(); foreach (var kv in counts) parts.Add(kv.Key + " " + kv.Value); line = "key presses this second: " + String.Join(", ", parts.ToArray()); counts.Clear(); } }
                if (line != null) Log(line);
            }
            double now = sw.Elapsed.TotalSeconds;
            if (File.Exists(stopFile)) { Log("stopped by stop file"); break; }
            if (seen && now - lastChange > quietSecs) { Log("no changes for " + quietSecs + " s, done"); break; }
            if (!seen && now > maxWaitSecs) { Log("keyboard never appeared on USB within " + maxWaitSecs + " s, done"); break; }
        }
    }
}
'@
Remove-Item "$PSScriptRoot\usb_watch.stop" -ErrorAction SilentlyContinue
[Watch]::Open($Log)
[Watch]::Log("recorder started; quiet limit $QuietSecs s, wait limit $MaxWaitSecs s")
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\ROOT_HUB*' } | ForEach-Object {
    $ctrl = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_Parent).Data
    $name = if ($ctrl -match 'DEV_43D5') { 'CHIPSET' } elseif ($ctrl -match 'DEV_149C') { 'CPU' } else { $ctrl }
    $err = [Watch]::AddHub($name, '\\?\' + ($_.InstanceId -replace '\\', '#') + '#{f18a0e88-c30c-11d0-8815-00a0c906bed8}')
    if ($err) { [Watch]::Log("hub $name : $err") }
}
if (-not $DeviceId) {
    $DeviceId = (Get-PnpDevice | Where-Object { $_.InstanceId -like 'USB\VID_16C0&PID_27DB\*' } | Select-Object -First 1).InstanceId
}
if (-not $BtAddress) {
    $bt = Get-PnpDevice | Where-Object { $_.InstanceId -like 'BTHLE\DEV_*' -and $_.FriendlyName -eq 'Glove80' } | Select-Object -First 1
    if ($bt -and $bt.InstanceId -match 'DEV_([0-9A-F]{12})') { $BtAddress = $Matches[1] }
}
[Watch]::BtAddr = $BtAddress.ToUpperInvariant()
[Watch]::Log("keyboard USB id: $DeviceId; Bluetooth address: $BtAddress")
[Watch]::StartRaw()
[Watch]::Run($DeviceId, $QuietSecs, $MaxWaitSecs, "$PSScriptRoot\usb_watch.stop")
Get-Content $Log
