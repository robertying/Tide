using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace Tide;

/// Stored as JSON in %LOCALAPPDATA%\Tide\settings.json. Launch at Login lives in the registry instead,
/// so Windows' own Startup apps page can see and turn it off. Defaults and ranges match the macOS app.
sealed class Settings {
    public const int DefaultDimAfter = 120;
    public const double DefaultDimLevel = 0.25, DefaultFadeOut = 1.2, DefaultFadeIn = 0.3;

    public bool Enabled { get; set; } = true;
    public int DimAfter { get; set; } = DefaultDimAfter;      // seconds
    public double DimLevel { get; set; } = DefaultDimLevel;   // picture brightness while dimmed, relative to normal
    public double FadeOut { get; set; } = DefaultFadeOut;     // seconds
    public double FadeIn { get; set; } = DefaultFadeIn;       // seconds
    public DateTime? PausedUntil { get; set; }                // UTC; ignored once in the past

    [JsonIgnore] public bool Paused => PausedUntil is DateTime t && t > DateTime.UtcNow;

    static string FilePath => Path.Combine(Log.Folder, "settings.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static Settings Load() {
        Settings s;
        try { s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new(); }
        catch (FileNotFoundException) { s = new(); }
        catch (Exception e) { Log.Write($"settings unreadable, using defaults: {e.Message}"); s = new(); }
        s.Clamp();
        return s;
    }

    public void Clamp() {
        DimAfter = Math.Clamp(DimAfter, 5, 3600);
        DimLevel = Math.Clamp(DimLevel, 0.05, 0.9);
        FadeOut = Math.Clamp(FadeOut, 0, 10);
        FadeIn = Math.Clamp(FadeIn, 0, 10);
    }

    public void Save() {
        try {
            Directory.CreateDirectory(Log.Folder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
        } catch (Exception e) { Log.Write($"could not save settings: {e.Message}"); }
    }

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunValue = "Tide";
    static string RunCommand => $"\"{Environment.ProcessPath}\" --startup";

    public static bool LaunchAtLogin {
        get {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(RunValue) is string;
        }
        set {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(RunValue, RunCommand);
            else key.DeleteValue(RunValue, false);
        }
    }

    /// Keeps the login entry pointing at this copy if Tide.exe was moved.
    public static void RefreshStartupPath() {
        if (LaunchAtLogin) LaunchAtLogin = true;
    }
}
