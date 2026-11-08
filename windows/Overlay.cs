using System;
using System.Drawing;
using System.Windows.Forms;

namespace Tide;

/// Full-screen black window that never takes focus and never shows in the taskbar or Alt+Tab.
/// While dimmed it sits under the pointer with a blank cursor, which hides the pointer without
/// changing any system setting: if Tide ends, the window and the hidden pointer go with it.
/// Once awake it is click-through again, so it never gets in the way.
/// A WinForms window because its Opacity is a constant-alpha layered window, which is cheap to fade.
sealed class Overlay : Form {
    bool clickThrough = true;

    public Overlay() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Color.Black;
        StartPosition = FormStartPosition.Manual;
        Opacity = 0;
        Bounds = SystemInformation.VirtualScreen;
        var and = new byte[32 * 32 / 8];
        Array.Fill(and, (byte)0xFF);   // fully transparent pointer
        Cursor = new Cursor(Native.CreateCursor(IntPtr.Zero, 0, 0, 32, 32, and, new byte[32 * 32 / 8]));
    }

    /// Click-through windows never get the pointer, so it only hides while this is off.
    public void SetClickThrough(bool on) {
        clickThrough = on;
        if (!IsHandleCreated) return;
        int ex = Native.GetWindowLong(Handle, Native.GWL_EXSTYLE);
        Native.SetWindowLong(Handle, Native.GWL_EXSTYLE, on ? ex | Native.WS_EX_TRANSPARENT : ex & ~Native.WS_EX_TRANSPARENT);
    }

    /// Windows only hands the pointer to the window under it when the mouse moves, and the mouse is
    /// still when dimming starts, so the app underneath keeps the pointer (and its shape). Moving it
    /// 1 pixel and back makes Windows give it to this window, which then shows the blank pointer.
    /// The caller has to ignore this as input (see Idle.IgnoreInputForNow).
    public void TakePointer() {
        if (!Native.GetCursorPos(out var p)) return;
        Native.SetCursorPos(p.X > 0 ? p.X - 1 : p.X + 1, p.Y);
        Native.SetCursorPos(p.X, p.Y);
        HidePointer();
    }

    /// Sets the blank pointer directly; works while the pointer already belongs to this window.
    public void HidePointer() => Native.SetCursor(Cursor.Handle);

    /// After a keyboard wake the mouse hasn't moved either: put back a normal arrow until it does,
    /// when the app underneath sets its own pointer again.
    public static void ShowPointer() => Native.SetCursor(Native.LoadCursor(IntPtr.Zero, Native.IDC_ARROW));

    public void ShowOnTop() {
        if (!Visible) {
            Bounds = SystemInformation.VirtualScreen;
            Show();
        }
        // Back above other always-on-top windows such as the taskbar.
        Native.SetWindowPos(Handle, Native.HWND_TOPMOST, 0, 0, 0, 0,
            Native.SWP_NOSIZE | Native.SWP_NOMOVE | Native.SWP_NOACTIVATE);
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE;
            if (clickThrough) cp.ExStyle |= Native.WS_EX_TRANSPARENT;
            return cp;
        }
    }
}
