using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
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

        // Reload the icon when the display scaling (and so the icon size) may have changed.
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

    static readonly int[] TrayFrames = { 16, 20, 24, 32, 48, 64 };

    /// The colored app icon at the notification area's icon size: the embedded frame for that size
    /// (16 px at 100% scaling, up to 48 px at 300%), or the next larger one scaled down.
    static Icon Render() {
        int size = SystemInformation.SmallIconSize.Width;
        int frame = TrayFrames.FirstOrDefault(f => f >= size, TrayFrames[^1]);
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"Tide.tray{frame}.png")
            ?? throw new InvalidOperationException($"missing tray icon resource for {frame} px");
        using var source = new Bitmap(stream);
        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(source, new Rectangle(0, 0, size, size));
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
