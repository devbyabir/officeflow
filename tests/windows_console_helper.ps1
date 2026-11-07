# Test-only helper: attaches to another process's console window and drives it like a person.
#   read   - returns the console's visible text
#   type   - types the text in -TextFile as real key presses (\n = Enter)
#   ctrlc  - presses Ctrl+C in that console, waits for the process to end, returns the text
#   close  - closes the console window (like clicking its X), after detaching from it
# Run it as its own process; it frees its own console first. Output goes to -OutFile.
param(
  [Parameter(Mandatory = $true)][ValidateSet("read", "type", "ctrlc", "close")][string]$Action,
  [Parameter(Mandatory = $true)][int]$TargetPid,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [string]$TextFile = ""
)
$ErrorActionPreference = "Stop"
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class ConsoleDriver {
  [StructLayout(LayoutKind.Sequential)] public struct Coord { public short X; public short Y; }
  [StructLayout(LayoutKind.Sequential)] public struct SmallRect { public short Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct ScreenInfo {
    public Coord Size; public Coord Cursor; public ushort Attributes; public SmallRect Window; public Coord MaxSize;
  }
  [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)] public struct InputRecord {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public int KeyDown;
    [FieldOffset(8)] public ushort RepeatCount;
    [FieldOffset(10)] public ushort VirtualKeyCode;
    [FieldOffset(12)] public ushort VirtualScanCode;
    [FieldOffset(14)] public char UnicodeChar;
    [FieldOffset(16)] public uint ControlKeyState;
  }

  [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint processId);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool WriteConsoleInputW(IntPtr input, InputRecord[] records, uint count, out uint written);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool ReadConsoleOutputCharacterW(IntPtr output, [Out] char[] text, uint length, Coord start, out uint read);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleScreenBufferInfo(IntPtr output, out ScreenInfo info);
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint group);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
  [DllImport("user32.dll", SetLastError = true)] static extern bool PostMessageW(IntPtr window, uint message, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder name, int size);

  const uint GenericReadWrite = 0xC0000000, ShareReadWrite = 3, OpenExisting = 3;

  static IntPtr Open(string name) {
    IntPtr handle = CreateFileW(name, GenericReadWrite, ShareReadWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
    if (handle == new IntPtr(-1)) throw new Exception("Cannot open " + name + ": " + Marshal.GetLastWin32Error());
    return handle;
  }

  static string Screen() {
    IntPtr output = Open("CONOUT$");
    try {
      ScreenInfo info;
      if (!GetConsoleScreenBufferInfo(output, out info)) throw new Exception("No screen info: " + Marshal.GetLastWin32Error());
      int width = info.Size.X, height = info.Cursor.Y + 1;
      var lines = new StringBuilder();
      for (short row = 0; row < height; row++) {
        var line = new char[width];
        uint read;
        ReadConsoleOutputCharacterW(output, line, (uint)width, new Coord { X = 0, Y = row }, out read);
        lines.Append(new string(line, 0, (int)Math.Min(read, (uint)width)).TrimEnd()).Append('\n');
      }
      return lines.ToString();
    } finally { CloseHandle(output); }
  }

  static void Type(string text) {
    IntPtr input = Open("CONIN$");
    try {
      var records = new InputRecord[text.Length * 2];
      for (int i = 0; i < text.Length; i++) {
        char c = text[i] == '\n' ? '\r' : text[i];
        ushort key = c == '\r' ? (ushort)0x0D : (ushort)0;
        records[2 * i] = new InputRecord { EventType = 1, KeyDown = 1, RepeatCount = 1, VirtualKeyCode = key, UnicodeChar = c };
        records[2 * i + 1] = new InputRecord { EventType = 1, KeyDown = 0, RepeatCount = 1, VirtualKeyCode = key, UnicodeChar = c };
      }
      uint written;
      if (!WriteConsoleInputW(input, records, (uint)records.Length, out written) || written != records.Length)
        throw new Exception("Typing failed: " + Marshal.GetLastWin32Error());
    } finally { CloseHandle(input); }
  }

  public static string Run(string action, int processId, string text) {
    FreeConsole();
    if (!AttachConsole((uint)processId)) return "ERROR attach " + Marshal.GetLastWin32Error();
    try {
      switch (action) {
        case "read": return Screen();
        case "type": Type(text); return "OK";
        case "ctrlc":
          SetConsoleCtrlHandler(IntPtr.Zero, true); // this helper ignores the Ctrl+C itself
          if (!GenerateConsoleCtrlEvent(0, 0)) return "ERROR ctrl " + Marshal.GetLastWin32Error();
          try { Process.GetProcessById(processId).WaitForExit(60000); } catch (ArgumentException) { }
          return Screen(); // still attached, so the window's text is still readable
        case "close":
          IntPtr window = GetConsoleWindow();
          FreeConsole(); // detach first, so closing the window does not end this helper
          if (window == IntPtr.Zero) return "ERROR no console window";
          var className = new StringBuilder(256);
          GetClassNameW(window, className, className.Capacity);
          if (!PostMessageW(window, 0x0010, IntPtr.Zero, IntPtr.Zero)) return "ERROR close " + Marshal.GetLastWin32Error();
          System.Threading.Thread.Sleep(3000);
          return "OK class=" + className + " stillOpen=" + IsWindow(window);
      }
      return "ERROR unknown action";
    } finally { FreeConsole(); }
  }
}
'@
$text = if ($TextFile) { [IO.File]::ReadAllText($TextFile) } else { "" }
try {
  $result = [ConsoleDriver]::Run($Action, $TargetPid, $text)
} catch {
  $result = "ERROR $($_.Exception.Message)"
}
[IO.File]::WriteAllText($OutFile, $result)
