using System;
using System.Diagnostics;
using System.IO;

namespace Tide;

static class Log {
    public static readonly string Folder =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tide");
    static readonly string LogPath = Path.Combine(Folder, "tide.log");

    public static void Write(string message) {
        try {
            Directory.CreateDirectory(Folder);
            var info = new FileInfo(LogPath);
            if (info.Exists && info.Length > 1_000_000) File.Move(LogPath, LogPath + ".1", true);
            File.AppendAllText(LogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        } catch { }
    }

    public static void Open() {
        Write("log opened");
        try { Process.Start(new ProcessStartInfo(LogPath) { UseShellExecute = true }); } catch { }
    }
}
