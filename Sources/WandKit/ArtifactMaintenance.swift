import Foundation
import Darwin

/// Retains bounded inactive diagnostics. Never traverses directories, follows
/// symlinks, removes lock files, or touches another owner's active log.
public enum ArtifactMaintenance {
    public struct Report {
        public var files: [String] = []
        public var bytes = 0
        public init() {}
    }
    public static func clean(directory: URL, dryRun: Bool, now: Date = Date(),
                             maxLogs: Int = 32, maxLogBytes: Int = 8 * 1024 * 1024) -> Report {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        struct Candidate { let url: URL; let size: Int; let date: Date; let udid: String? }
        var candidates: [Candidate] = []
        for url in files {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, let date = values.contentModificationDate else { continue }
            let name = url.lastPathComponent
            let isLog = name.hasPrefix("daemon-") && name.hasSuffix(".log")
            let isOCR = name.hasPrefix("ocr-") && ["png", "json"].contains(url.pathExtension)
            guard isLog || isOCR else { continue }
            let prefix = isLog ? "daemon-" : "ocr-"
            let identifier = String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
            guard UUID(uuidString: identifier) != nil else { continue }
            candidates.append(Candidate(url: url, size: values.fileSize ?? 0, date: date, udid: isLog ? identifier : nil))
        }
        candidates.sort { $0.date < $1.date }
        var logCount = candidates.filter { $0.udid != nil }.count
        var logBytes = candidates.filter { $0.udid != nil }.reduce(0) { $0 + $1.size }
        var report = Report()
        for candidate in candidates {
            let old = now.timeIntervalSince(candidate.date) > 7 * 86400
            guard old || (candidate.udid != nil && (logCount > maxLogs || logBytes > maxLogBytes)) else { continue }
            var locks: [Int32] = []
            defer { for fd in locks { flock(fd, LOCK_UN); close(fd) } }
            if let udid = candidate.udid {
                var owned = true
                // Same ordering as startup. Do not unlink locks: that splits ownership.
                for suffix in [".startup.lock", ".owner.lock"] {
                    let path = directory.appendingPathComponent("daemon-\(udid).sock" + suffix).path
                    let fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | (dryRun ? 0 : O_CREAT), 0o600)
                    if fd < 0 {
                        if dryRun && errno == ENOENT { continue }
                        owned = false; break
                    }
                    if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); owned = false; break }
                    locks.append(fd)
                }
                guard owned else { continue }
            }
            if !dryRun {
                do { try fm.removeItem(at: candidate.url) } catch { continue }
            }
            report.files.append(candidate.url.lastPathComponent); report.bytes += candidate.size
            if candidate.udid != nil { logCount -= 1; logBytes -= candidate.size }
        }
        return report
    }
}
