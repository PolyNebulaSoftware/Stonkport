// Stonkport tray helper: hides/shows the launcher's main window on request.
//
// Godot 4.7 refuses to change the main window's visibility through its own
// API ("Can't change visibility of main window", window.cpp set_visible), so
// the launcher shells out to this helper with the raw HWND and lets user32
// perform the call. ShowWindowAsync is mandatory here: plain ShowWindow
// sends messages into the target window's thread, which is blocked waiting
// for this very process inside OS.execute — a guaranteed deadlock.
//
// Compiled at build time with the .NET Framework csc that ships with Windows
// (see tools/export_presets.cmd):
//
//   csc /nologo /target:winexe /out:StonkportTrayHelper.exe StonkportTrayHelper.cs
//
// Usage: StonkportTrayHelper.exe <hide|show|query> <hwnd>
// Exit codes: 0 = success, 1 = operation failed, 2 = bad arguments.
using System;
using System.Runtime.InteropServices;

internal static class Program
{
    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    private const int SW_HIDE = 0;
    private const int SW_RESTORE = 9;

    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            return 2;
        }

        IntPtr hWnd;
        try
        {
            hWnd = new IntPtr(long.Parse(args[1]));
        }
        catch (FormatException)
        {
            return 2;
        }
        catch (OverflowException)
        {
            return 2;
        }

        switch (args[0])
        {
            case "hide":
                return ShowWindowAsync(hWnd, SW_HIDE) ? 0 : 1;
            case "show":
                return ShowWindowAsync(hWnd, SW_RESTORE) ? 0 : 1;
            case "query":
                // Pure state read: sends no messages, cannot deadlock.
                return IsWindowVisible(hWnd) ? 0 : 1;
            default:
                return 2;
        }
    }
}
