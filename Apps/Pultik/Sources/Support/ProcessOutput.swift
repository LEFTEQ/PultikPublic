import Foundation

/// Reads a running child's stdout and stderr to EOF at the same time, then
/// waits for it to exit. Waiting first, or reading one pipe to EOF before the
/// other, deadlocks as soon as the child fills the undrained pipe's 64 KiB
/// buffer: it blocks writing, and the parent blocks waiting. Every
/// `Process` Pultík runs with piped output collects it through here.
enum ProcessOutput {
    static func collect(_ process: Process, stdout: Pipe, stderr: Pipe) -> (stdout: Data, stderr: Data) {
        let errHandle = stderr.fileHandleForReading
        let errData = DrainedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData.set(errHandle.readDataToEndOfFile())
            group.leave()
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (out, errData.value)
    }

    /// Hands each `\n`-terminated stdout record (without its newline) to
    /// `record` while the child runs, so a reader that wants the first few
    /// hundred lines of a long output stops there: false terminates the
    /// child. A last record without a newline is handed over at EOF. Stderr
    /// drains alongside, as in `collect`.
    static func records(_ process: Process, stdout: Pipe, stderr: Pipe,
                        record: (Data) -> Bool) -> (stderr: Data, stopped: Bool) {
        let errHandle = stderr.fileHandleForReading
        let errData = DrainedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData.set(errHandle.readDataToEndOfFile())
            group.leave()
        }
        let handle = stdout.fileHandleForReading
        var pending = Data()
        var stopped = false
        reading: while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                let line = pending.subdata(in: start ..< newline)
                start = pending.index(after: newline)
                guard record(line) else {
                    stopped = true
                    break reading
                }
            }
            pending.removeSubrange(pending.startIndex ..< start)
        }
        if stopped {
            process.terminate()
        } else if !pending.isEmpty {
            _ = record(pending)
        }
        group.wait()
        process.waitUntilExit()
        return (errData.value, stopped)
    }
}

/// The stderr bytes handed back from the draining queue.
private final class DrainedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
