import Foundation
import IOKit
import IOKit.pwr_mgt

/// Dims external displays when there is no mouse/keyboard input, and restores them on activity.
/// After `dim.after` seconds idle it fades to `dim.factor` of the current brightness.
/// It does not dim while an app holds the display awake (video, calls), and does not restore
/// over a brightness change the user made while dimmed.
final class Dimmer {
    private let lock = NSLock()
    private var stopped = false

    // State below is only touched with `lock` held.
    private var dimmed = false
    private var held = false            // user changed brightness; don't dim again until next activity
    private var saved: Float = 0.7      // level to restore to
    private var expected: Float = 0     // last level this module set
    private var dimLevel: Float = 0     // level of the last dim
    private var verifyUntil: TimeInterval = 0  // after a restore, watch until then for the display falling back
    private var recovering = false

    /// Copy of the loop state for the menu, behind its own lock so reading it never waits on a fade.
    private struct Snapshot { var dimmed = false, held = false, recovering = false, saved: Float = 0 }
    private let snapLock = NSLock()
    private var snap = Snapshot()

    /// Brightness to return to, kept while dimmed so a run that dies dimmed can be undone by the next one.
    static let stateFile: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tide")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dim.state")
    }()

    /// One-line state for the menu. Settings are read live, so a pause or toggle shows immediately.
    var status: String {
        snapLock.lock(); let s = snap; snapLock.unlock()
        if s.recovering { return "Restoring brightness…" }
        if s.dimmed { return "Dimmed, restores to \(pct(s.saved))" }
        if !Settings.dimEnabled { return "Off" }
        if let paused = Settings.pausedUntil {
            return "Paused until \(paused.formatted(date: Calendar.current.isDateInToday(paused) ? .omitted : .abbreviated, time: .shortened))"
        }
        if !Brightness.available { return "Brightness control unavailable" }
        if Brightness.externals().isEmpty { return "No external display" }
        if s.held { return "Keeping your brightness change" }
        return "Dims after \(Dimmer.duration(Settings.dimAfter)) idle"
    }

    private func publish() {
        snapLock.lock()
        snap = Snapshot(dimmed: dimmed, held: held, recovering: recovering, saved: saved)
        snapLock.unlock()
    }

    func start() {
        recovering = FileManager.default.fileExists(atPath: Dimmer.stateFile.path)
        let t = Thread { [weak self] in self?.run() }
        t.name = "Tide dimmer"
        t.qualityOfService = .userInteractive
        t.start()
        log("started (dim after \(Settings.dimAfter)s to \(Settings.dimFactor)x)")
    }

    /// Called on quit/logout: restores the display if it is dimmed, since nothing else will.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if dimmed, fade(saved, Settings.dimFadeIn) {
            dimmed = false
            removeState()
            log("stopped, restored \(fmt(saved))")
        }
    }

    /// Shows the current dim settings: fades down, holds briefly, fades back. Runs in the background.
    func preview(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.dimmed else { return DispatchQueue.main.async { completion("Already dimmed") } }
            guard let cur = Brightness.get() else { return DispatchQueue.main.async { completion("No controllable external display") } }
            guard case .success = Brightness.fade(to: cur * Settings.dimFactor, seconds: Settings.dimFadeOut) else {
                return DispatchQueue.main.async { completion("Could not set brightness") }
            }
            Thread.sleep(forTimeInterval: 1.5)
            _ = Brightness.fade(to: cur, seconds: Settings.dimFadeIn)
            DispatchQueue.main.async { completion(nil) }
        }
    }

    // MARK: Loop

    private func run() {
        while true {
            lock.lock()
            if stopped { lock.unlock(); return }
            let interval = tick()
            publish()
            lock.unlock()
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// One poll. Returns how long to sleep before the next one.
    private func tick() -> TimeInterval {
        if recovering {
            if recover() { recovering = false }
            return 2
        }

        let enabled = Settings.dimEnabled
        let paused = Settings.pausedUntil
        let limit = Settings.dimAfter

        // Waking from display sleep, the set can be accepted and then overwritten with the old dimmed value.
        // For a short while after a restore, put the brightness back if it falls back to the dim level.
        if !dimmed, now() < verifyUntil, let cur = Brightness.get(),
           abs(cur - dimLevel) < 0.02, saved - cur > 0.02 {
            log("display fell back to \(fmt(cur)), restoring \(fmt(saved)) again")
            _ = fade(saved, Settings.dimFadeIn)
        }

        let idle = Dimmer.idleSeconds()
        if idle < limit { held = false }

        if dimmed {
            if let cur = Brightness.get(), abs(cur - expected) > 0.02 {
                dimmed = false
                held = true
                removeState()
                log("brightness changed manually (\(fmt(cur))), not restoring")
            } else if idle < limit || Dimmer.displaySleepBlocked() || !enabled || paused != nil {
                restore()
            }
        } else if enabled, paused == nil, !held, idle >= limit, !Dimmer.displaySleepBlocked() {
            if let cur = Brightness.get() {
                saved = cur
                let warn = saved * Settings.dimFactor
                expected = saved
                dimLevel = warn
                writeState(saved)
                if fade(warn, Settings.dimFadeOut) {
                    dimmed = true
                    log("dimmed to \(fmt(warn)) (saved \(fmt(saved)))")
                } else {
                    removeState()
                }
            }
        }

        // Poll faster while dimmed so the restore feels immediate.
        return dimmed || now() < verifyUntil ? 0.25 : 2
    }

    // MARK: Actions (lock held)

    @discardableResult
    private func fade(_ level: Float, _ seconds: Double) -> Bool {
        let target = (level * 1000).rounded() / 1000
        guard case .success = Brightness.fade(to: target, seconds: seconds) else { return false }
        expected = target
        return true
    }

    private func restore() {
        // The display can be missing (asleep, unplugged); stay dimmed and retry on the next poll.
        guard fade(saved, Settings.dimFadeIn) else { return }
        dimmed = false
        removeState()
        verifyUntil = now() + 20
        log("restored \(fmt(saved))")
    }

    /// A previous run died while dimmed: put the display back. Returns false while the display is unavailable.
    private func recover() -> Bool {
        let prev = (try? String(contentsOf: Dimmer.stateFile, encoding: .utf8))
            .flatMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let cur = Brightness.get() else { return false }
        if let prev, prev - cur > 0.02, fade(prev, Settings.dimFadeIn) {
            log("recovered \(fmt(prev)) left dimmed by a previous run")
        }
        removeState()
        return true
    }

    private func writeState(_ v: Float) { try? fmt(v).write(to: Dimmer.stateFile, atomically: true, encoding: .utf8) }
    private func removeState() { try? FileManager.default.removeItem(at: Dimmer.stateFile) }

    // MARK: System queries

    /// Seconds since the last mouse/keyboard input (IOHIDSystem HIDIdleTime).
    static func idleSeconds() -> Int {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard svc != 0 else { return 0 }
        defer { IOObjectRelease(svc) }
        guard let v = IORegistryEntryCreateCFProperty(svc, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return Int(v.uint64Value / 1_000_000_000)
    }

    /// True while an app holds a PreventUserIdleDisplaySleep assertion (video, calls).
    static func displaySleepBlocked() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [String: Any] else { return false }
        return ((d["PreventUserIdleDisplaySleep"] as? NSNumber)?.intValue ?? 0) > 0
    }

    // MARK: Helpers

    static func duration(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : seconds > 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
    }
    private func fmt(_ v: Float) -> String { String(format: "%.3f", v) }
    private func pct(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
    private func log(_ s: String) { Log.write("dim", s) }
}
