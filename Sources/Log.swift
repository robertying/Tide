import Foundation

/// Appends to ~/Library/Logs/Tide/tide.log (or stderr for the command-line tools).
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tide")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tide.log")
    }()
    static var toStderr = false
    private static let lock = NSLock()
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Keeps one previous log once the current one passes 1 MB.
    static func rotate() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 1_000_000 else { return }
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    static func write(_ module: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = Data("\(format.string(from: Date())) [\(module)] \(message)\n".utf8)
        if toStderr { FileHandle.standardError.write(line); return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }
}
