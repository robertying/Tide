using System;
using Microsoft.Win32;
using Windows.Media;
using Windows.Media.Control;

namespace Tide;

/// Reasons not to dim, all readable without administrator rights: a full-screen app in front,
/// a camera or microphone in use (calls), or video playing through the system media controls.
sealed class KeepAwake {
    GlobalSystemMediaTransportControlsSessionManager? media;

    public async void Start() {
        try { media = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync(); }
        catch (Exception e) { Log.Write($"media sessions unavailable: {e.Message}"); }
    }

    /// <param name="checkFullScreen">Off while dimmed: the dimming overlay itself covers the whole screen.</param>
    public string? Reason(bool checkFullScreen) {
        if (checkFullScreen && Native.SHQueryUserNotificationState(out int state) == 0 && state is 2 or 3 or 4)
            return "full-screen app";
        if (InUse("webcam") || InUse("microphone")) return "camera or microphone in use";
        if (VideoPlaying()) return "video playing";
        return null;
    }

    bool VideoPlaying() {
        if (media == null) return false;
        try {
            foreach (var session in media.GetSessions()) {
                var info = session.GetPlaybackInfo();
                // Music players report Music; browsers often report nothing, which is treated as video.
                if (info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing &&
                    info.PlaybackType != MediaPlaybackType.Music)
                    return true;
            }
        } catch { }
        return false;
    }

    /// Windows records camera and microphone use per app; an app that started but has not stopped is using it now.
    static bool InUse(string capability) {
        try {
            using var root = Registry.CurrentUser.OpenSubKey(
                $@"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\{capability}");
            return root != null && AnyInUse(root);
        } catch { return false; }
    }

    static bool AnyInUse(RegistryKey key) {
        foreach (var name in key.GetSubKeyNames()) {
            using var sub = key.OpenSubKey(name);
            if (sub == null) continue;
            if (name == "NonPackaged") {
                if (AnyInUse(sub)) return true;
                continue;
            }
            if (sub.GetValue("LastUsedTimeStart") is long start && start > 0 &&
                sub.GetValue("LastUsedTimeStop") is long stop && stop == 0)
                return true;
        }
        return false;
    }
}
