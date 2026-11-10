import WandKit

extension Daemon {
    // One executor for both output modes. Summary avoids retaining intermediate
    // success text; it never skips commands, errors, cancellation or settling.
    static func executeBatch(_ batch: CommandBatch, cancelled: () -> Bool,
                             execute: ([String]) -> Reply) -> Reply {
        var output: [String] = []
        let total = batch.commands.count
        func render(completed: Int) -> String {
            let prefix = batch.summary ? ["completed \(completed)/\(total)"] : []
            return (prefix + output).joined(separator: "\n")
        }
        for (index, command) in batch.commands.enumerated() {
            if cancelled() {
                output.append("client disconnected; remaining batch steps did not run; prior steps may have applied")
                return Reply(ok: false, text: render(completed: index))
            }
            let reply = execute(command)
            if !batch.summary || !reply.ok || index == total - 1 {
                output.append("\(index + 1) \(reply.ok ? "OK" : "FAIL") \(reply.text)")
            }
            if !reply.ok {
                output.append("stopped; remaining commands did not run. Inspect state before retrying")
                return Reply(ok: false, text: render(completed: index), exitAfterReply: reply.exitAfterReply)
            }
        }
        return Reply(ok: true, text: render(completed: total))
    }
}
