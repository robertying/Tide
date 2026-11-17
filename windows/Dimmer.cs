using System;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace Tide;

/// Dims the screen in software when there is no input, and restores it on activity.
/// After `DimAfter` seconds idle, a black overlay fades in until the picture is at `DimLevel`.
/// Nothing on the display itself changes (no brightness or monitor settings), so it works on any
/// display, including TVs without DDC/CI, and if Tide stops for any reason the overlay goes with it.
/// Runs on the UI thread from a timer: every 500 ms while awake, every 16 ms while fading or dimmed.
sealed class Dimmer : IDisposable {
    readonly Settings settings;
    readonly Overlay overlay = new();
    readonly KeepAwake keepAwake = new();
    readonly DispatcherTimer timer = new();

    bool dimmed, fading;
    double from, to, seconds;
    DateTime fadeStart, nextCheck = DateTime.MinValue, previewUntil = DateTime.MinValue;
    DateTime heldAt = DateTime.MinValue;   // last check that found a reason to stay awake
    string? holdReason;

    public event Action? StatusChanged;

    public Dimmer(Settings settings) {
        this.settings = settings;
        keepAwake.Start();
        var dispatcher = Dispatcher.CurrentDispatcher;
        SystemEvents.DisplaySettingsChanged += (_, _) =>
            dispatcher.BeginInvoke(() => overlay.Bounds = Forms.SystemInformation.VirtualScreen);
        timer.Interval = TimeSpan.FromMilliseconds(500);
        timer.Tick += (_, _) => Tick();
        timer.Start();
        Log.Write($"started (dim after {settings.DimAfter}s to {settings.DimLevel:P0}, {(settings.Enabled ? "on" : "off")})");
    }

    /// MaxValue while a preview is about to start, MinValue when there is none.
    public bool Previewing => previewUntil != DateTime.MinValue;

    /// One-line state for the menu, worded as on the Mac.
    public string Status {
        get {
            if (Previewing) return "Previewing…";
            if (dimmed) return "Dimmed";
            if (!settings.Enabled) return "Off";
            if (settings.Paused && settings.PausedUntil is DateTime until) {
                var local = until.ToLocalTime();
                return local.Date == DateTime.Today ? $"Paused until {local:t}" : $"Paused until {local:MMM d}, {local:t}";
            }
            if (holdReason != null) return $"Not dimming: {holdReason}";
            return $"Dims after {Duration(settings.DimAfter)} idle";
        }
    }

    public static string Duration(int s) =>
        s % 60 == 0 ? $"{s / 60} min" : s > 60 ? $"{s / 60} min {s % 60} s" : $"{s} s";

    bool Active => settings.Enabled && !settings.Paused;

    /// Call after any setting changes.
    public void SettingsChanged() {
        if (!Active && dimmed && !Previewing) Wake();
        Changed();
    }

    /// Dims with the current settings, holds for 2 seconds, then restores. Input doesn't end it early.
    /// Works even while dimming is off or paused.
    public void Preview() {
        if (dimmed || Previewing) return;
        previewUntil = DateTime.MaxValue;
        Changed();
        // Start after the click finishes: while the Preview button still holds the mouse capture,
        // the pointer belongs to the Settings window and the overlay can't hide it.
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Input, () => {
            previewUntil = DateTime.UtcNow.AddSeconds(settings.FadeOut + 2);
            Dim();
        });
    }

    void Tick() {
        var now = DateTime.UtcNow;
        if (fading) Step(now);

        if (previewUntil != DateTime.MinValue) {
            if (now >= previewUntil && !fading) { previewUntil = DateTime.MinValue; Wake(); }
        } else if (!Active) {
            if (dimmed) Wake();
            SetHold(null);
        } else {
            int idle = Idle.Seconds();
            if (dimmed) {
                bool wake = idle < settings.DimAfter;
                if (!wake && now >= nextCheck) {
                    nextCheck = now.AddSeconds(5);
                    var reason = keepAwake.Reason(checkFullScreen: false);
                    if (reason != null) { wake = true; heldAt = now; SetHold(reason); }
                }
                if (wake) { Wake(); Log.Write("restored"); }
            } else if (idle >= settings.DimAfter) {
                if (now >= nextCheck) {
                    nextCheck = now.AddSeconds(5);
                    var reason = keepAwake.Reason(checkFullScreen: true);
                    SetHold(reason);
                    // A reason to stay awake counts as activity: when it ends (a video stops, an app
                    // quits), the countdown starts from then rather than from the last input.
                    if (reason != null) heldAt = now;
                    else if ((now - heldAt).TotalSeconds >= settings.DimAfter) { Dim(); Log.Write($"dimmed to {settings.DimLevel:P0}"); }
                }
            } else {
                SetHold(null);
            }
        }

        // Smooth fades and an instant wake need frequent ticks; while awake, twice a second is plenty.
        var interval = TimeSpan.FromMilliseconds(dimmed || fading ? 16 : 500);
        if (timer.Interval != interval) timer.Interval = interval;
    }

    void Dim() {
        dimmed = true;
        overlay.SetClickThrough(false);
        // A fully transparent layered window doesn't receive the mouse, so start just above zero.
        overlay.Opacity = Math.Max(overlay.Opacity, 1 / 255.0);
        overlay.ShowOnTop();
        Idle.IgnoreInputForNow();
        overlay.TakePointer();
        // Opacity that leaves the picture at DimLevel. Kept below 1 so the window stays layered.
        FadeTo(Math.Clamp(1 - settings.DimLevel, 0, 0.99), settings.FadeOut);
        Changed();
    }

    void Wake() {
        dimmed = false;
        Idle.StopIgnoring();
        overlay.SetClickThrough(true);
        Overlay.ShowPointer();
        FadeTo(0, settings.FadeIn);
        Changed();
    }

    void FadeTo(double level, double secs) {
        from = overlay.Opacity; to = level; seconds = secs; fadeStart = DateTime.UtcNow; fading = true;
        timer.Interval = TimeSpan.FromMilliseconds(16);
        Step(fadeStart);
    }

    void Step(DateTime now) {
        double linear = seconds > 0 ? Math.Min(1, (now - fadeStart).TotalSeconds / seconds) : 1;
        // Smoothstep easing: slow start and end, so the change looks gradual.
        double k = linear * linear * (3 - 2 * linear);
        overlay.Opacity = linear >= 1 ? to : from + (to - from) * k;
        if (linear >= 1) {
            fading = false;
            if (to <= 0) overlay.Hide();
            else if (dimmed) overlay.HidePointer();   // in case something reset it during the fade
        }
    }

    void SetHold(string? reason) {
        if (reason == holdReason) return;
        holdReason = reason;
        if (reason != null) Log.Write($"not dimming: {reason}");
        Changed();
    }

    void Changed() => StatusChanged?.Invoke();

    public void Dispose() {
        timer.Stop();
        overlay.Dispose();
    }
}
