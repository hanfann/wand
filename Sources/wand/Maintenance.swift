import Foundation
import Darwin
import WandKit

enum Maintenance {
    static func run(dryRun: Bool = false, automatic: Bool = false) -> ArtifactMaintenance.Report {
        let directory = URL(fileURLWithPath: Net.socketDir())
        let stamp = directory.appendingPathComponent("maintenance.stamp")
        if automatic,
           let date = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < 86400 { return .init() }
        let fd = open(directory.appendingPathComponent("maintenance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .init() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return .init() }
        defer { flock(fd, LOCK_UN) }
        let report = ArtifactMaintenance.clean(directory: directory, dryRun: dryRun)
        if !dryRun { try? Data().write(to: stamp, options: .atomic) }
        return report
    }
}
