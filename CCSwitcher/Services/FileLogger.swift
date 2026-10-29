import Foundation

/// Drop-in replacement for os.Logger that writes to ~/Library/Logs/CCSwitcher-app.log.
/// Rotates at 5MB, keeps 2 prior files (.1 and .2) for ~15MB total cap.
/// Usage: `let log = FileLog("Category"); log.info("message")`
/// Read logs: `cat ~/Library/Logs/CCSwitcher-app.log` or `tail -f ~/Library/Logs/CCSwitcher-app.log`
struct FileLog: Sendable {
    private static let shared = FileLogWriter()
    private let category: String

    init(_ category: String) {
        self.category = category
    }

    func info(_ message: String) { FileLog.shared.write("INFO", category, message) }
    func warning(_ message: String) { FileLog.shared.write("WARN", category, message) }
    func error(_ message: String) { FileLog.shared.write("ERROR", category, message) }
    /// Debug builds only. These are per-subprocess and per-keychain-read
    /// lines, about a third of the log; in Release the message is not even
    /// built.
    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        FileLog.shared.write("DEBUG", category, message())
        #endif
    }
}

private final class FileLogWriter: @unchecked Sendable {
    private let logsDir: String
    private let basePath: String
    private var fileHandle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private let queue = DispatchQueue(label: "com.ccswitcher.filelog")
    private let dateFormatter: ISO8601DateFormatter

    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024  // 5 MB
    private static let keepRotated = 2  // .1 and .2 → ~15MB total cap

    init() {
        let logsDir = NSHomeDirectory() + "/Library/Logs"
        self.logsDir = logsDir
        self.basePath = logsDir + "/CCSwitcher-app.log"

        // Remove the legacy log file from versions <= 1.4.4, which may contain
        // an Authorization Bearer token captured by the old getUsageLimits log
        // (see GitHub issue #11). Best-effort; ignore errors if it doesn't exist.
        try? FileManager.default.removeItem(atPath: logsDir + "/CCSwitcher.log")

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        openHandle()
        writeSessionHeader()
    }

    private func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: basePath) {
            fm.createFile(atPath: basePath, contents: nil)
            bytesWritten = 0
        } else {
            let attrs = try? fm.attributesOfItem(atPath: basePath)
            bytesWritten = (attrs?[.size] as? UInt64) ?? 0
        }
        fileHandle = FileHandle(forWritingAtPath: basePath)
        _ = try? fileHandle?.seekToEnd()
    }

    private func writeSessionHeader() {
        let ts = dateFormatter.string(from: Date())
        let header = "====== CCSwitcher launched \(ts) ======\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
            bytesWritten += UInt64(data.count)
        }
    }

    func write(_ level: String, _ category: String, _ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let ts = self.dateFormatter.string(from: Date())
            // The log outlives the session and gets attached to bug reports,
            // so account emails are masked here, once, for every call site.
            let line = "[\(ts)] [\(level)] [\(category)] \(message.obfuscatedEmail())\n"
            guard let data = line.data(using: .utf8) else { return }
            if let fh = self.fileHandle {
                fh.write(data)
                self.bytesWritten += UInt64(data.count)
                if self.bytesWritten >= Self.maxFileBytes {
                    self.rotate()
                }
            }
        }
    }

    /// Rotate: close current → bump .1→.2, .log→.1 (drop oldest) → open fresh.
    /// Called only on the serial queue; safe to mutate fileHandle.
    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        // Drop the oldest rotated file if it exists.
        let oldestPath = "\(basePath).\(Self.keepRotated)"
        try? fm.removeItem(atPath: oldestPath)

        // Shift .N-1 → .N, ..., .1 → .2.
        var idx = Self.keepRotated
        while idx > 1 {
            let from = "\(basePath).\(idx - 1)"
            let to = "\(basePath).\(idx)"
            if fm.fileExists(atPath: from) {
                try? fm.moveItem(atPath: from, toPath: to)
            }
            idx -= 1
        }

        // Move current → .1.
        let firstRotated = "\(basePath).1"
        try? fm.removeItem(atPath: firstRotated)
        if fm.fileExists(atPath: basePath) {
            try? fm.moveItem(atPath: basePath, toPath: firstRotated)
        }

        // Reopen a fresh active file.
        openHandle()
        let ts = dateFormatter.string(from: Date())
        let marker = "====== rotated at \(ts) ======\n"
        if let data = marker.data(using: .utf8) {
            fileHandle?.write(data)
            bytesWritten += UInt64(data.count)
        }
    }
}
