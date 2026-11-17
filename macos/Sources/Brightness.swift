import CoreGraphics
import Foundation

/// External display brightness via macOS DisplayServices (a private API).
enum Brightness {
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let fns: (set: SetFn, get: GetFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let s = dlsym(h, "DisplayServicesSetBrightness"),
              let g = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return (unsafeBitCast(s, to: SetFn.self), unsafeBitCast(g, to: GetFn.self))
    }()

    static var available: Bool { fns != nil }

    static func externals() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Current brightness (0–1) of the first external display, or nil if there is none or it cannot be read.
    static func get() -> Float? {
        guard let fns, let id = externals().first else { return nil }
        var v: Float = 0
        return fns.get(id, &v) == 0 ? v : nil
    }

    enum FadeError: Error { case unavailable, noDisplay, setFailed }

    /// Fades all external displays to `level` over `seconds`, with smoothstep easing. Blocks until done.
    static func fade(to level: Float, seconds: Double) -> Result<Void, FadeError> {
        guard let fns else { return .failure(.unavailable) }
        let displays = externals()
        guard !displays.isEmpty else { return .failure(.noDisplay) }
        var starts = [CGDirectDisplayID: Float]()
        for id in displays { var v = level; _ = fns.get(id, &v); starts[id] = v }
        var failed = false
        var last = [CGDirectDisplayID: Float]()
        let begin = DispatchTime.now().uptimeNanoseconds
        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e9
            let linear = seconds > 0 ? min(1.0, elapsed / seconds) : 1.0
            // Smoothstep easing: slow start and end, so the change looks gradual.
            let t = Float(linear * linear * (3 - 2 * linear))
            for id in displays {
                let from = starts[id] ?? level
                let v = linear >= 1.0 ? level : from + (level - from) * t
                // Skip values the display cannot show as a separate step.
                if let l = last[id], abs(l - v) < 0.005, linear < 1.0 { continue }
                if fns.set(id, v) != 0 { failed = true }
                last[id] = v
            }
            if linear >= 1.0 { break }
            usleep(8_000)
        }
        return failed ? .failure(.setFailed) : .success(())
    }

    /// `Tide brightness [level [seconds]]`: prints the level, or fades every external display to it.
    /// Exits 1 on bad input or no DisplayServices, 2 with no external display, 3 if the get or set fails.
    static func cli(_ args: [String]) -> Int32 {
        guard available else { fputs("DisplayServices not available\n", stderr); return 1 }
        guard !externals().isEmpty else { fputs("no external display\n", stderr); return 2 }
        guard let arg = args.first else {
            guard let v = get() else { fputs("get failed\n", stderr); return 3 }
            print(String(format: "%.3f", v))
            return 0
        }
        guard let level = Float(arg), (0...1).contains(level) else { fputs("level must be 0.0–1.0\n", stderr); return 1 }
        var seconds = 0.0
        if args.count > 1 {
            guard let s = Double(args[1]), s >= 0 else { fputs("seconds must be 0 or more\n", stderr); return 1 }
            seconds = s
        }
        switch fade(to: level, seconds: seconds) {
        case .success: return 0
        case .failure(.noDisplay): fputs("no external display\n", stderr); return 2
        case .failure: fputs("set failed\n", stderr); return 3
        }
    }
}
