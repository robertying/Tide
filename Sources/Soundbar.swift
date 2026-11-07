// Routes the Mac's volume keys to a HomeKit "Soundbar Volume" accessory (via the Homebridge UI API)
// whenever audio is going out to the TV over HDMI.

import AppKit
import CoreAudio
import CryptoKit
import Foundation

private func log(_ s: String) { Log.write("soundbar", s) }

// MARK: - CoreAudio

func defaultOutputDeviceName() -> String? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr
    else { return nil }
    return deviceName(deviceID)
}

func deviceName(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return nil }
    return n.takeRetainedValue() as String
}

/// Names of all audio devices that can play sound, for the Settings picker.
func outputDeviceNames() -> [String] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    var names: [String] = []
    for id in ids {
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
              let name = deviceName(id), !names.contains(name) else { continue }
        names.append(name)
    }
    return names
}

/// Name of a matching device that an app holds exclusively (hog mode), e.g. Music.app doing
/// HDMI passthrough. macOS moves the default output elsewhere while that happens.
func hoggedSoundbarDevice() -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return nil }
    let match = Settings.sbDevice
    for id in ids {
        guard let name = deviceName(id), name.localizedCaseInsensitiveContains(match) else { continue }
        var hog: pid_t = -1
        var hogAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyHogMode,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var hogSize = UInt32(MemoryLayout<pid_t>.size)
        if AudioObjectGetPropertyData(id, &hogAddr, 0, nil, &hogSize, &hog) == noErr, hog != -1 { return name }
    }
    return nil
}

/// True when audio is going to the soundbar: the TV is the default output, or an app
/// (e.g. Music with passthrough) has taken the TV device exclusively.
func soundbarIsActive() -> Bool {
    guard !Settings.sbDevice.isEmpty else { return false }
    if let name = defaultOutputDeviceName(), name.localizedCaseInsensitiveContains(Settings.sbDevice) { return true }
    return hoggedSoundbarDevice() != nil
}

// MARK: - TOTP

/// RFC 6238 one-time codes, from a base32 secret or an otpauth:// URL.
struct TOTP {
    let key: Data
    var digits = 6
    var period = 30.0
    var algorithm = "SHA1"

    init?(_ input: String) {
        var secret = input.trimmingCharacters(in: .whitespaces)
        if secret.lowercased().hasPrefix("otpauth://"), let comps = URLComponents(string: secret) {
            let q = Dictionary((comps.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
            secret = q["secret"] ?? ""
            if let d = q["digits"].flatMap(Int.init) { digits = d }
            if let p = q["period"].flatMap(Double.init), p > 0 { period = p }
            if let a = q["algorithm"], !a.isEmpty { algorithm = a.uppercased() }
        }
        guard let k = TOTP.base32Decode(secret), !k.isEmpty else { return nil }
        key = k
    }

    static func base32Decode(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && ch != " " && ch != "-" {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }

    func code(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / period).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let k = SymmetricKey(data: key)
        let mac: Data
        switch algorithm {
        case "SHA256": mac = Data(HMAC<SHA256>.authenticationCode(for: msg, using: k))
        case "SHA512": mac = Data(HMAC<SHA512>.authenticationCode(for: msg, using: k))
        default: mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: k))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let bin = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        let mod = UInt32(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)u", bin % mod)
    }

    func step(at date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970 / period) }

    /// Homebridge rejects (and logs) a code that was already used, so remember the last time step
    /// used by any Tide process and wait for a new one instead of reusing it.
    static let usedStepFile = URL(fileURLWithPath: "/tmp/tide.otp-step")

    func freshCode() -> String {
        let last = (try? String(contentsOf: TOTP.usedStepFile, encoding: .utf8))
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let last, step() <= last {
            Thread.sleep(forTimeInterval: secondsUntilNext() + 0.5)
        }
        try? String(step()).write(to: TOTP.usedStepFile, atomically: true, encoding: .utf8)
        return code()
    }

    func secondsUntilNext(_ date: Date = Date()) -> Double {
        period - date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
    }
}

// MARK: - Homebridge UI API

enum Homebridge {
    /// Characteristics that can carry the volume, in order of preference.
    static let levelTypes = ["RotationSpeed", "Brightness", "Volume"]

    private static let lock = NSRecursiveLock()
    private static var token: String?
    private static var target: (uniqueId: String, type: String)?
    /// Last known On state of a fan/light accessory, so On is only sent when it changes.
    private static var lastOn: Bool?
    /// Settings the cached login and accessory belong to; a change drops them.
    private static var configKey = ""
    /// Separate from `lock`, which is held across network calls, so the menu can read this without waiting.
    private static let errorLock = NSLock()
    private static var _lastError: String?
    private(set) static var lastError: String? {
        get { errorLock.lock(); defer { errorLock.unlock() }; return _lastError }
        set { errorLock.lock(); _lastError = newValue; errorLock.unlock() }
    }

    struct HTTPError: Error, CustomStringConvertible {
        let status: Int
        let body: String
        var description: String { status == 0 ? body : "HTTP \(status): \(body.prefix(200))" }
    }

    private static func syncConfig() {
        let key = [Settings.sbURL, Settings.sbUser, Keychain.get(.password) ?? "", Keychain.get(.totp) ?? "",
                   Settings.sbAccessory].joined(separator: "\u{1}")
        if key != configKey {
            configKey = key
            token = nil
            target = nil
            lastOn = nil
        }
    }

    private static func request(_ method: String, _ path: String, body: Any? = nil, auth: Bool = true) throws -> Any? {
        guard !Settings.sbURL.isEmpty, let url = URL(string: Settings.sbURL + path) else {
            throw HTTPError(status: 0, body: "Homebridge address isn't set")
        }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth {
            if token == nil { try login() }
            req.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        }
        var result: (Data?, URLResponse?, Error?)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { result = ($0, $1, $2); sem.signal() }.resume()
        sem.wait()
        if let e = result.2 { throw e }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        let data = result.0 ?? Data()
        if status == 401 && auth {
            token = nil // expired: log in once more and retry
            try login()
            return try request(method, path, body: body, auth: true)
        }
        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }

    private static func login() throws {
        let user = Settings.sbUser
        guard !user.isEmpty, let pass = Keychain.get(.password) else {
            throw HTTPError(status: 0, body: "Homebridge username or password isn't set")
        }
        token = nil
        let secret = Keychain.get(.totp)
        let totp = secret.flatMap(TOTP.init)
        if secret != nil && totp == nil {
            throw HTTPError(status: 0, body: "Two-factor secret isn't valid")
        }
        func attempt(_ otp: String?) throws -> String? {
            var body = ["username": user, "password": pass]
            if let otp { body["otp"] = otp }
            let json = try request("POST", "/api/auth/login", body: body, auth: false) as? [String: Any]
            return json?["access_token"] as? String
        }
        var t: String?
        do {
            t = try attempt(totp?.freshCode())
        } catch let e as HTTPError where totp != nil && (400..<500).contains(e.status) {
            // A code can still be rejected right at a period boundary; try once more with the next one.
            t = try attempt(totp!.freshCode())
        }
        guard let t else { throw HTTPError(status: 0, body: "login returned no token") }
        token = t
    }

    /// Finds the accessory and returns its current level.
    private static func lookup() throws -> Int {
        guard let list = try request("GET", "/api/accessories") as? [[String: Any]] else {
            throw HTTPError(status: 0, body: "unexpected /api/accessories response")
        }
        let name = Settings.sbAccessory
        let wanted = name.lowercased()
        for acc in list {
            let names = [acc["serviceName"], (acc["accessoryInformation"] as? [String: Any])?["Name"]]
                .compactMap { ($0 as? String)?.lowercased() }
            guard names.contains(where: { $0 == wanted }) || names.contains(where: { $0.contains(wanted) }),
                  let id = acc["uniqueId"] as? String,
                  let chars = acc["serviceCharacteristics"] as? [[String: Any]] else { continue }
            for t in levelTypes {
                if let c = chars.first(where: { ($0["type"] as? String) == t }) {
                    target = (id, t)
                    lastOn = (chars.first(where: { ($0["type"] as? String) == "On" })?["value"] as? NSNumber)?.boolValue
                    return (c["value"] as? NSNumber)?.intValue ?? 0
                }
            }
        }
        throw HTTPError(status: 0, body: "no accessory named '\(name)' with \(levelTypes.joined(separator: "/")) found")
    }

    /// Current level, or the error that prevented reading it.
    static func check() -> Result<Int, Error> {
        lock.lock(); defer { lock.unlock() }
        syncConfig()
        do {
            let v = try lookup()
            lastError = nil
            return .success(v)
        } catch {
            lastError = "\(error)"
            log("get failed: \(error)")
            return .failure(error)
        }
    }

    /// Current level for the periodic resync. Once the accessory is known, reads just that accessory
    /// instead of the full list, which makes Homebridge query every accessory it has.
    static func get() -> Int? {
        lock.lock(); defer { lock.unlock() }
        syncConfig()
        if let t = target {
            do {
                let acc = try request("GET", "/api/accessories/\(t.uniqueId)") as? [String: Any]
                if let chars = acc?["serviceCharacteristics"] as? [[String: Any]],
                   let c = chars.first(where: { ($0["type"] as? String) == t.type }) {
                    lastOn = (chars.first(where: { ($0["type"] as? String) == "On" })?["value"] as? NSNumber)?.boolValue
                    lastError = nil
                    return (c["value"] as? NSNumber)?.intValue ?? 0
                }
                log("accessory \(t.uniqueId) has no \(t.type); searching again")
            } catch {
                log("reading accessory \(t.uniqueId) failed (\(error)); searching again")
            }
            target = nil
        }
        return try? check().get()
    }

    static func set(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        syncConfig()
        do {
            if target == nil { _ = try lookup() }
            guard let t = target else { return }
            if t.type == "RotationSpeed" || t.type == "Brightness", lastOn != (value > 0) {
                // Fans/lights ignore the level while "off"; keep On in sync with the level.
                _ = try? request("PUT", "/api/accessories/\(t.uniqueId)",
                                 body: ["characteristicType": "On", "value": value > 0])
                lastOn = value > 0
            }
            _ = try request("PUT", "/api/accessories/\(t.uniqueId)",
                            body: ["characteristicType": t.type, "value": value])
            lastError = nil
        } catch {
            lastError = "\(error)"
            log("set \(value) failed: \(error)")
            target = nil
        }
    }
}

// MARK: - HUD

/// Segmented level bar like the system volume HUD: 16 blocks, the last one partially filled.
final class LevelBar: NSView {
    static let segments = 16
    var value: Double = 0 { didSet { needsDisplay = true } }   // 0...1
    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 1.5
        let n = LevelBar.segments
        let w = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        let filled = value * Double(n)
        for i in 0..<n {
            let r = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
            let f = min(1, max(0, filled - Double(i)))
            if f > 0 {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX, y: 0, width: r.width * CGFloat(f), height: r.height),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}

final class HUD {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let bar = LevelBar()
    private var hideWork: DispatchWorkItem?
    static let size = NSSize(width: 300, height: 64)
    static let radius: CGFloat = 32   // full capsule

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: HUD.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Content: speaker icon · segmented bar (same layout as the system volume HUD)
        let content = NSView(frame: NSRect(origin: .zero, size: HUD.size))
        icon.frame = NSRect(x: 20, y: 14, width: 40, height: 36)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .semibold)
        icon.contentTintColor = .white
        icon.imageAlignment = .alignLeft
        icon.imageScaling = .scaleNone
        bar.frame = NSRect(x: 68, y: 29, width: 212, height: 5)
        [icon, bar].forEach(content.addSubview)

        if #available(macOS 26.0, *) {
            // Liquid Glass, rounded by the view itself so the window has no square corners.
            let glass = NSGlassEffectView(frame: content.frame)
            glass.cornerRadius = HUD.radius
            // Grey frost under the content so white reads on light backgrounds, like the system HUD.
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
            content.layer?.cornerRadius = HUD.radius
            glass.contentView = content
            panel.contentView = glass
        } else {
            let fx = NSVisualEffectView(frame: content.frame)
            fx.material = .hudWindow
            fx.state = .active
            fx.blendingMode = .behindWindow
            fx.maskImage = HUD.roundedMask(radius: HUD.radius)   // shapes both the blur and the window shadow
            fx.addSubview(content)
            panel.contentView = fx
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    func show(level: Int, muted: Bool) {
        let off = muted || level == 0
        icon.image = off
            ? NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Muted")
            : NSImage(systemSymbolName: "speaker.wave.3.fill", variableValue: Double(level) / 100,
                      accessibilityDescription: "Volume \(level)")
        bar.value = muted ? 0 : Double(level) / 100

        // Top-right under the menu bar, where macOS shows its own volume HUD.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - HUD.size.width - 10, y: f.maxY - HUD.size.height - 6))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self?.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self?.panel.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

// MARK: - Controller

final class VolumeController {
    let hud = HUD()
    private let worker = DispatchQueue(label: "tide.soundbar.worker")
    /// Posted on the main thread whenever `shownLevel` may have changed.
    static let levelChanged = Notification.Name("TideSoundbarLevelChanged")

    // main-thread state
    private(set) var level: Int? { didSet { announce() } }
    private var muted = false { didSet { announce() } }
    /// What the soundbar is actually at: 0 while muted.
    var shownLevel: Int? { muted ? 0 : level }
    private var preMute = 20
    private var lastActivity = Date.distantPast
    // worker state (guarded by `worker`)
    private var pending: Int?
    private var inFlight = false

    private func announce() {
        NotificationCenter.default.post(name: VolumeController.levelChanged, object: self)
    }

    func start() {
        if Settings.sbEnabled && Settings.sbConfigured { resync() }
        // Re-read the real value every minute while idle (in case the TV remote changed it).
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, Settings.sbEnabled, Settings.sbConfigured,
                  Date().timeIntervalSince(self.lastActivity) > 10, soundbarIsActive() else { return }
            self.resync()
        }
    }

    func resync(then: (() -> Void)? = nil) {
        worker.async {
            let v = Homebridge.get()
            DispatchQueue.main.async {
                if let v {
                    self.level = v
                    if v > 0 { self.muted = false }
                }
                then?()
            }
        }
    }

    enum Key { case up, down, mute }

    func handle(_ key: Key, fine: Bool) {
        lastActivity = Date()
        guard let current = level else {
            // First press and we don't know the level yet: fetch, then apply.
            resync { if self.level != nil { self.handle(key, fine: fine) } }
            return
        }
        let step = fine ? 1 : Settings.sbStep
        var target = current
        switch key {
        case .up:
            target = muted ? max(preMute, step) : min(Settings.sbMax, current + step)
            muted = false
        case .down:
            if muted { hud.show(level: 0, muted: true); return }
            target = max(0, current - step)
        case .mute:
            if muted {
                muted = false
                target = preMute
            } else {
                preMute = current > 0 ? current : preMute
                muted = true
                target = 0
            }
        }
        level = muted ? current : target
        hud.show(level: target, muted: muted)
        send(target)
    }

    /// Sets an absolute level (menu slider).
    func setLevel(_ value: Int) {
        lastActivity = Date()
        let v = min(Settings.sbMax, max(0, value))
        muted = false
        level = v
        send(v)
    }

    /// Coalesces rapid changes: only the newest value is sent once the previous call returns.
    private func send(_ value: Int) {
        worker.async {
            self.pending = value
            guard !self.inFlight else { return }
            self.drain()
        }
    }

    private func drain() {
        guard let v = pending else { inFlight = false; return }
        pending = nil
        inFlight = true
        DispatchQueue.global().async {
            Homebridge.set(v)
            self.worker.async { self.drain() }
        }
    }
}

// MARK: - Module

/// Owns the volume key event tap. The tap needs Accessibility permission; until it is granted the
/// module waits and retries, and the rest of Tide keeps running.
final class Soundbar {
    static let shared = Soundbar()
    let controller = VolumeController()
    fileprivate var tap: CFMachPort?
    private var retry: Timer?

    var tapInstalled: Bool { tap != nil }

    func start() {
        controller.start()
        if Settings.sbEnabled && !AXIsProcessTrusted() {
            // Ask once per launch; the Settings window also links to the right pane.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        installTap()
        if tap == nil {
            log("waiting for Accessibility permission")
            retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                self?.installTap()
                if self?.tap != nil { t.invalidate() }
            }
        }
        log("started (device match '\(Settings.sbDevice)')")
    }

    private func installTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
            log("could not create event tap")
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        log("volume keys tap installed")
    }

    /// One-line state for the menu.
    var status: String {
        if !Settings.sbEnabled { return "Off" }
        if !AXIsProcessTrusted() { return "Needs Accessibility permission" }
        if tap == nil { return "Relaunch to apply permission" }
        if !Settings.sbConfigured { return "Not set up" }
        if Homebridge.lastError != nil { return "Homebridge error, see log" }
        if soundbarIsActive() {
            return "Active, TV is the output"
        }
        return "Inactive, TV isn't the output"
    }
}

private let NX_KEYTYPE_SOUND_UP = 0
private let NX_KEYTYPE_SOUND_DOWN = 1
private let NX_KEYTYPE_MUTE = 7

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, cgEvent: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = Soundbar.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(cgEvent)
    }
    guard type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue),
          let ev = NSEvent(cgEvent: cgEvent), ev.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(cgEvent)
    }
    let keyCode = (ev.data1 & 0xFFFF0000) >> 16
    let keyFlags = ev.data1 & 0x0000FFFF
    let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA
    let key: VolumeController.Key
    switch keyCode {
    case NX_KEYTYPE_SOUND_UP: key = .up
    case NX_KEYTYPE_SOUND_DOWN: key = .down
    case NX_KEYTYPE_MUTE: key = .mute
    default: return Unmanaged.passUnretained(cgEvent)
    }
    guard Settings.sbEnabled, Settings.sbConfigured, soundbarIsActive() else { return Unmanaged.passUnretained(cgEvent) }
    if isDown {
        let fine = ev.modifierFlags.contains(.shift) && ev.modifierFlags.contains(.option)
        DispatchQueue.main.async { Soundbar.shared.controller.handle(key, fine: fine) }
    }
    return nil // swallow so macOS doesn't show its disabled volume HUD
}
