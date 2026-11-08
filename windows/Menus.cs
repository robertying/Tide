using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Tide;

/// Native Win32 popup menus.
static class Menus {
    public sealed record Item(int Id, string? Text, bool Checked = false, bool Disabled = false, Item[]? Submenu = null) {
        public static readonly Item Separator = new(0, null);
    }

    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll")] static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string? text);
    [DllImport("user32.dll")]
    static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

    // Undocumented uxtheme exports, by ordinal, available since Windows 10 1903:
    // let this app's menus follow Windows' light or dark app mode.
    [DllImport("uxtheme.dll", EntryPoint = "#135")] static extern int SetPreferredAppMode(int mode);
    [DllImport("uxtheme.dll", EntryPoint = "#136")] static extern void FlushMenuThemes();

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    const uint MF_STRING = 0x0, MF_GRAYED = 0x1, MF_CHECKED = 0x8, MF_POPUP = 0x10, MF_SEPARATOR = 0x800;
    const uint TPM_RIGHTALIGN = 0x8, TPM_BOTTOMALIGN = 0x20, TPM_NONOTIFY = 0x80, TPM_RETURNCMD = 0x100, TPM_RIGHTBUTTON = 0x2;
    const int SM_MENUDROPALIGNMENT = 40;

    public static void AllowDarkMode() {
        try {
            SetPreferredAppMode(1);   // AllowDark: dark when Windows apps are set to dark
            FlushMenuThemes();
        } catch (EntryPointNotFoundException) { }
    }

    /// Shows the menu at the pointer and returns the chosen item's Id, or 0 if dismissed.
    public static int Show(IntPtr owner, IEnumerable<Item> items) {
        IntPtr menu = Build(items);
        try {
            GetCursorPos(out var p);
            // Needed so the menu closes when you click elsewhere.
            SetForegroundWindow(owner);
            uint align = TPM_BOTTOMALIGN | (GetSystemMetrics(SM_MENUDROPALIGNMENT) != 0 ? TPM_RIGHTALIGN : 0);
            int command = TrackPopupMenuEx(menu, align | TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, p.X, p.Y, owner, IntPtr.Zero);
            PostMessage(owner, 0, IntPtr.Zero, IntPtr.Zero);   // WM_NULL, so a second right-click opens it again
            return command;
        } finally {
            DestroyMenu(menu);   // also destroys submenus
        }
    }

    static IntPtr Build(IEnumerable<Item> items) {
        IntPtr menu = CreatePopupMenu();
        foreach (var item in items) {
            if (item.Text == null) { AppendMenu(menu, MF_SEPARATOR, UIntPtr.Zero, null); continue; }
            uint flags = MF_STRING | (item.Checked ? MF_CHECKED : 0) | (item.Disabled ? MF_GRAYED : 0);
            if (item.Submenu != null)
                AppendMenu(menu, flags | MF_POPUP, (UIntPtr)(ulong)Build(item.Submenu).ToInt64(), item.Text);
            else
                AppendMenu(menu, flags, (UIntPtr)item.Id, item.Text);
        }
        return menu;
    }
}
