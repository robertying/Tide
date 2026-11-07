import Foundation
import Security

/// UserDefaults keys (domain io.ruiying.Tide). The Settings window binds to these directly,
/// and the modules read them on every use, so changes apply without a restart.
enum Key {
    static let dimEnabled = "dim.enabled"
    static let dimAfter = "dim.after"            // seconds idle before dimming
    static let dimFactor = "dim.factor"          // dimmed level as a fraction of the current level
    static let dimFadeOut = "dim.fadeOut"        // seconds
    static let dimFadeIn = "dim.fadeIn"          // seconds
    static let dimPausedUntil = "dim.pausedUntil" // seconds since 1970; 0 = not paused

    static let sbEnabled = "soundbar.enabled"
    static let sbURL = "soundbar.url"
    static let sbUser = "soundbar.user"
    static let sbAccessory = "soundbar.accessory"
    static let sbDevice = "soundbar.device"
    static let sbStep = "soundbar.step"
    static let sbMax = "soundbar.max"
}

enum Defaults {
    static let dimAfter = 120
    static let dimFactor = 0.25
    static let dimFadeOut = 1.2
    static let dimFadeIn = 0.3
    static let sbAccessory = "Soundbar Volume"
    static let sbDevice = ""  // no TV output until one is picked in Settings
    static let sbStep = 2
    static let sbMax = 100
}

enum Settings {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            Key.dimEnabled: true,
            Key.dimAfter: Defaults.dimAfter,
            Key.dimFactor: Defaults.dimFactor,
            Key.dimFadeOut: Defaults.dimFadeOut,
            Key.dimFadeIn: Defaults.dimFadeIn,
            Key.dimPausedUntil: 0.0,
            Key.sbEnabled: true,
            Key.sbURL: "",
            Key.sbUser: "",
            Key.sbAccessory: Defaults.sbAccessory,
            Key.sbDevice: Defaults.sbDevice,
            Key.sbStep: Defaults.sbStep,
            Key.sbMax: Defaults.sbMax,
        ])
    }

    // MARK: Dim
    static var dimEnabled: Bool {
        get { d.bool(forKey: Key.dimEnabled) }
        set { d.set(newValue, forKey: Key.dimEnabled) }
    }
    static var dimAfter: Int { max(5, d.integer(forKey: Key.dimAfter)) }
    static var dimFactor: Float { Float(min(1, max(0, d.double(forKey: Key.dimFactor)))) }
    static var dimFadeOut: Double { min(10, max(0, d.double(forKey: Key.dimFadeOut))) }
    static var dimFadeIn: Double { min(10, max(0, d.double(forKey: Key.dimFadeIn))) }
    static var pausedUntil: Date? {
        get {
            let t = d.double(forKey: Key.dimPausedUntil)
            return t > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: t) : nil
        }
        set { d.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.dimPausedUntil) }
    }

    // MARK: Soundbar
    static var sbEnabled: Bool {
        get { d.bool(forKey: Key.sbEnabled) }
        set { d.set(newValue, forKey: Key.sbEnabled) }
    }
    static var sbURL: String {
        var s = (d.string(forKey: Key.sbURL) ?? "").trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
    static var sbUser: String { (d.string(forKey: Key.sbUser) ?? "").trimmingCharacters(in: .whitespaces) }
    static var sbAccessory: String { nonEmpty(Key.sbAccessory) ?? Defaults.sbAccessory }
    static var sbDevice: String { nonEmpty(Key.sbDevice) ?? "" }
    static var sbStep: Int { max(1, d.integer(forKey: Key.sbStep)) }
    static var sbMax: Int { min(100, max(1, d.integer(forKey: Key.sbMax))) }

    /// URL, user, password and TV output are all set.
    static var sbConfigured: Bool {
        !sbURL.isEmpty && !sbUser.isEmpty && !sbDevice.isEmpty && Keychain.get(.password) != nil
    }

    private static func nonEmpty(_ key: String) -> String? {
        let s = (d.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

/// Homebridge secrets, kept in the login Keychain and cached in memory.
enum Secret: String, CaseIterable {
    case password = "homebridge-password"
    case totp = "homebridge-totp-secret"
}

enum Keychain {
    static let service = "io.ruiying.Tide"
    private static let lock = NSLock()
    private static var cache: [Secret: String?] = [:]

    static func get(_ s: Secret) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[s] { return cached }
        var result: AnyObject?
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: s.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: String?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            value = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        }
        cache[s] = value
        return value
    }

    /// Stores the value, or removes the item when it is nil or empty.
    static func set(_ s: Secret, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: s.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let v = value.flatMap { $0.isEmpty ? nil : $0 }
        if let v {
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrLabel as String] = "Tide (\(s.rawValue))"
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess { Log.write("settings", "Keychain save of \(s.rawValue) failed: \(status)") }
        }
        cache[s] = v
    }
}
