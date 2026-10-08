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
