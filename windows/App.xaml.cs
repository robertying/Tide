using System;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace Tide;

/// Starts Tide: one copy per user, the dimmer, the tray icon, and the Settings window on demand.
/// There is no main window; Tide runs until Quit Tide in the tray menu.
public partial class App : Application {
    const string InstanceName = @"Local\io.ruiying.Tide";

    Mutex? instance;
    EventWaitHandle? showRequest;
    Settings settings = null!;
    Dimmer dimmer = null!;
    Tray tray = null!;
    SettingsWindow? window;

    protected override void OnStartup(StartupEventArgs e) {
        base.OnStartup(e);

        // Leave a trace in tide.log if Tide dies or Windows ends the session, so a missing tray icon can be explained.
        // The handlers only log; the crash itself still happens as before.
        AppDomain.CurrentDomain.UnhandledException += (_, a) => Log.Write($"crash (unhandled exception, terminating={a.IsTerminating}): {a.ExceptionObject}");
        DispatcherUnhandledException += (_, a) => Log.Write($"crash (UI thread): {a.Exception}");
        TaskScheduler.UnobservedTaskException += (_, a) => Log.Write($"unobserved task exception: {a.Exception}");
        SessionEnding += (_, a) => Log.Write($"session ending ({a.ReasonSessionEnding})");
        Log.Write($"starting Tide {Assembly.GetExecutingAssembly().GetName().Version?.ToString(3)} " +
                  $"({(e.Args.Contains("--startup") ? "at login" : "by hand")}) from {Environment.ProcessPath}");

        // One copy at a time. Opening Tide again brings up the running copy's Settings window.
        instance = new Mutex(true, InstanceName, out bool first);
        showRequest = new EventWaitHandle(false, EventResetMode.AutoReset, InstanceName + ".Show");
        if (!first) {
            Log.Write("another copy is already running; asking it to show Settings");
            // This copy was just started by the user, so it may bring a window to the front; pass that on.
            Native.AllowSetForegroundWindow(Native.ASFW_ANY);
            showRequest.Set();
            Shutdown();
            return;
        }
        ThreadPool.RegisterWaitForSingleObject(showRequest,
            (_, _) => Dispatcher.BeginInvoke(ShowSettings), null, Timeout.Infinite, false);

        settings = Settings.Load();
        Settings.RefreshStartupPath();
        dimmer = new Dimmer(settings);
        tray = new Tray(settings, dimmer, ShowSettings, Quit);

        // Started by hand rather than at login (--startup): show Settings, since Windows often hides new
        // tray icons in the overflow area and there would otherwise be no sign Tide is running.
        if (!e.Args.Contains("--startup")) ShowSettings();
    }

    void ShowSettings() {
        if (window == null) {
            window = new SettingsWindow(settings, dimmer);
            window.Closed += (_, _) => window = null;
            window.Show();
        }
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    void Quit() {
        Log.Write("quit");
        window?.Close();
        tray.Dispose();
        dimmer.Dispose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e) {
        Log.Write($"exit (code {e.ApplicationExitCode})");
        instance?.Dispose();
        base.OnExit(e);
    }
}
