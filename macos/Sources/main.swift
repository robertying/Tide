import AppKit

Settings.registerDefaults()

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "brightness":
    // Tide brightness [level [seconds]]
    exit(Brightness.cli(Array(args.dropFirst())))

case "soundbar":
    // Tide soundbar [level]: checks the output device and the Homebridge connection, optionally sets a level.
    Log.toStderr = true
    print("output device: \(defaultOutputDeviceName() ?? "?")  hogged: \(hoggedSoundbarDevice() ?? "none")  (soundbar active: \(soundbarIsActive()))")
    print("homebridge: \(Settings.sbURL.isEmpty ? "(not set)" : Settings.sbURL)  accessory: '\(Settings.sbAccessory)'")
    switch Homebridge.check() {
    case .success(let v): print("current level: \(v)")
    case .failure(let e): print("current level: unavailable (\(e))"); exit(1)
    }
    if let v = args.dropFirst().first.flatMap(Int.init) {
        let t0 = Date()
        Homebridge.set(v)
        print("set to \(v) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms; now reads: \(Homebridge.get().map(String.init) ?? "unavailable")")
    }
    exit(0)

case "status":
    // Tide status: what the dimmer sees right now.
    print("idle: \(Dimmer.idleSeconds())s  display sleep blocked: \(Dimmer.displaySleepBlocked())")
    print("external displays: \(Brightness.externals().count)  brightness: \(Brightness.get().map { String(format: "%.3f", $0) } ?? "unavailable")")
    print("dim: \(Settings.dimEnabled ? "on" : "off") after \(Settings.dimAfter)s to \(Settings.dimFactor)x\(Settings.pausedUntil.map { ", paused until \($0)" } ?? "")")
    exit(0)

case "help", "--help", "-h":
    print("""
    Tide — menu bar app that dims idle external displays and maps volume keys to a soundbar.
      Tide                        run the app
      Tide brightness [lvl [s]]   print or set (fade) external display brightness, 0.0–1.0
      Tide soundbar [level]       check the soundbar connection, optionally set a level
      Tide status                 show idle time, display-sleep assertions and brightness
    """)
    exit(0)

default:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
