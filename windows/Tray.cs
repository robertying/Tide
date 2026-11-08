using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Text;
using System.Windows.Forms;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Tide;

/// Notification area icon and menu, with the same items as the macOS menu bar menu.
/// The menu is a standard Win32 popup menu, so it uses the system's own menu style and follows
/// Windows' light or dark app mode.
sealed class Tray : IDisposable {
    readonly NotifyIcon icon = new();
    readonly NativeWindow owner = new();
    readonly Settings settings;
    readonly Dimmer dimmer;
    readonly Action showSettings, quit;

    const int CmdToggle = 1, CmdResume = 2, CmdPause1h = 3, CmdPause3h = 4, CmdPauseTomorrow = 5,
              CmdSettings = 6, CmdLogin = 7, CmdLog = 8, CmdQuit = 9;

    public Tray(Settings settings, Dimmer dimmer, Action showSettings, Action quit) {
        this.settings = settings;
        this.dimmer = dimmer;
        this.showSettings = showSettings;
        this.quit = quit;
        owner.CreateHandle(new CreateParams());
        Menus.AllowDarkMode();

        icon.Text = "Tide";
        icon.Icon = Render();
        icon.MouseUp += (_, e) => {
            if (e.Button == MouseButtons.Left) showSettings();
            else if (e.Button == MouseButtons.Right) ShowMenu();
        };
        icon.Visible = true;

        // Redraw in the right color when the taskbar switches between light and dark.
        var dispatcher = Dispatcher.CurrentDispatcher;
        SystemEvents.UserPreferenceChanged += (_, e) => {
            if (e.Category == UserPreferenceCategory.General)
                dispatcher.BeginInvoke(() => { var old = icon.Icon; icon.Icon = Render(); old?.Dispose(); });
        };
    }

    void ShowMenu() {
        var items = new List<Menus.Item> {
            new(CmdToggle, "Dim Display When Idle", Checked: settings.Enabled),
            new(0, dimmer.Status, Disabled: true),
        };
        // Pause shows only while dimming is on, as on the Mac.
        if (settings.Enabled) {
            var pause = new List<Menus.Item>();
            if (settings.Paused) {
                pause.Add(new(CmdResume, "Resume Now"));
                pause.Add(Menus.Item.Separator);
            }
            pause.Add(new(CmdPause1h, "For 1 Hour"));
            pause.Add(new(CmdPause3h, "For 3 Hours"));
            pause.Add(new(CmdPauseTomorrow, "Until Tomorrow"));
            items.Add(new(0, "Pause Dimming", Submenu: pause.ToArray()));
        }
        items.AddRange(new Menus.Item[] {
            Menus.Item.Separator,
            new(CmdSettings, "Settings…"),
            new(CmdLogin, "Launch at Login", Checked: Settings.LaunchAtLogin),
            new(CmdLog, "Open Log"),
            Menus.Item.Separator,
            new(CmdQuit, "Quit Tide"),
        });

        switch (Menus.Show(owner.Handle, items)) {
            case CmdToggle: Update(() => settings.Enabled = !settings.Enabled); break;
            case CmdResume: Pause(null); break;
            case CmdPause1h: Pause(DateTime.UtcNow.AddHours(1)); break;
            case CmdPause3h: Pause(DateTime.UtcNow.AddHours(3)); break;
            case CmdPauseTomorrow: Pause(DateTime.Today.AddDays(1).ToUniversalTime()); break;
            case CmdSettings: showSettings(); break;
            case CmdLogin:
                try { Settings.LaunchAtLogin = !Settings.LaunchAtLogin; }
                catch (Exception e) { Log.Write($"could not change launch at login: {e.Message}"); }
                break;
            case CmdLog: Log.Open(); break;
            case CmdQuit: quit(); break;
        }
    }

    void Pause(DateTime? until) {
        Update(() => settings.PausedUntil = until);
        Log.Write(until is DateTime t ? $"paused until {t.ToLocalTime():g}" : "resumed");
    }

    void Update(Action change) {
        change();
        settings.Save();
        dimmer.SettingsChanged();
    }

    /// The brightness glyph from the Windows icon font, black on a light taskbar and white on a dark one.
    static Icon Render() {
        int size = SystemInformation.SmallIconSize.Width;
        bool lightTaskbar = Registry.GetValue(
            @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "SystemUsesLightTheme", 0) is int v && v == 1;
        using var bitmap = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bitmap)) {
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using var font = new Font(IconFont.Name, size * 0.8f, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(lightTaskbar ? Color.Black : Color.White);
            using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString(IconFont.Brightness, font, brush, new RectangleF(0, 0, size, size), format);
        }
        IntPtr handle = bitmap.GetHicon();
        var result = (Icon)Icon.FromHandle(handle).Clone();
        Native.DestroyIcon(handle);
        return result;
    }

    public void Dispose() {
        icon.Visible = false;
        icon.Dispose();
        owner.DestroyHandle();
    }
}
