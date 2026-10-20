import Darwin
import Foundation

/// Runs a configured child with bounded wall time, bounded retained output
/// and concurrent stdout / stderr drains — the one runner for a local CLI
/// whose answer the panel reads (`DevboxClient`, `ToolkitClient`). Never a
/// shell: the caller sets `executableURL` and `arguments` itself. Blocking:
/// call it off the main actor.
///
/// The deadline covers the whole lifecycle, the drains included: a root that
/// exits while a descendant still holds its stdout or stderr open never
/// keeps the call waiting past it. No thread ever blocks in a pipe read —
/// each stream drains on its handle's readability source — so abandoning a
/// stream at the deadline needs no reader to return first.
enum BoundedProcess {
    /// What one stream gave back.
    struct Stream: Sendable {
        let data: Data
        /// More than `outputLimit` bytes arrived; `data` is their prefix.
        let truncated: Bool
        /// A read failed: `data` is what arrived before it.
        let error: String?
        /// The stream reached its end; false = abandoned at the deadline.
        var complete = true

        static let empty = Stream(data: Data(), truncated: false, error: nil)
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: Stream
        let stderr: Stream
        /// The deadline passed before the process exited and both streams
        /// ended: its tree was SIGKILLed and the streams abandoned.
        let timedOut: Bool
    }

    /// Launches `process` (its pipes and termination handler are replaced)
    /// and returns within `timeout` seconds plus a short grace for the kill.
    /// Throws only when the launch fails.
    static func run(_ process: Process, timeout: TimeInterval, outputLimit: Int) throws -> Output {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let streams = DispatchGroup()
        let stdout = Drain(out.fileHandleForReading, limit: outputLimit, group: streams)
        let stderr = Drain(err.fileHandleForReading, limit: outputLimit, group: streams)
        do {
            try process.run()
        } catch {
            stdout.abandon()
            stderr.abandon()
            throw error
        }

        let deadline = DispatchTime.now() + .milliseconds(Int(max(0, timeout) * 1000))
        var timedOut = streams.wait(timeout: deadline) == .timedOut
        if !timedOut { timedOut = exited.wait(timeout: deadline) == .timedOut }
        var status: Int32 = -1
        if timedOut {
            if process.isRunning {
                // Children first: a descendant must not be re-parented out of
                // reach while it still holds an inherited pipe writer.
                processTree(root: process.processIdentifier)
                    .filter { $0 > 1 }
                    .forEach { Darwin.kill($0, SIGKILL) }
            }
            // A descendant that escaped the tree (its root already exited)
            // cannot keep this call waiting: its next write meets EPIPE.
            stdout.abandon()
            stderr.abandon()
            if exited.wait(timeout: .now() + 2) == .success { status = process.terminationStatus }
        } else {
            status = process.terminationStatus
        }
        return Output(status: status, stdout: stdout.result(), stderr: stderr.result(), timedOut: timedOut)
    }

    /// One stream drained on its handle's readability source, retaining at
    /// most `limit` bytes and reading on past it so the child never blocks
    /// on a full pipe. A child is untrusted input even when the executable
    /// is local: a noisy one never grows this menu-bar app without bound.
    private final class Drain: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private let limit: Int
        private let group: DispatchGroup
        private var data = Data()
        private var truncated = false
        private var error: String?
        /// EOF or a read error ended it; no handler reads after.
        private var ended = false
        /// The deadline abandoned it before its end.
        private var abandoned = false

        init(_ handle: FileHandle, limit: Int, group: DispatchGroup) {
            self.handle = handle
            self.limit = limit
            self.group = group
            group.enter()
            handle.readabilityHandler = { [weak self] _ in self?.readable() }
        }

        /// One read(2) of what the pipe holds now: it never waits for more
        /// (unlike `FileHandle.read(upToCount:)`, which fills its count) and
        /// never raises (unlike `availableData`).
        private func readable() {
            lock.lock()
            defer { lock.unlock() }
            guard !ended else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let remaining = max(0, limit - data.count)
                if remaining > 0 { data.append(contentsOf: buffer.prefix(min(count, remaining))) }
                if count > remaining { truncated = true }
                return
            }
            if count < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN { return }
                error = String(cString: strerror(code))
            }
            ended = true
            handle.readabilityHandler = nil
            group.leave()
        }

        /// Stops draining and closes the read end. The flag flips under the
        /// lock, so a handler already reading finishes first and none reads
        /// after; the source is cancelled outside it.
        func abandon() {
            lock.lock()
            let open = !ended
            ended = true
            if open { abandoned = true }
            lock.unlock()
            guard open else { return }
            handle.readabilityHandler = nil
            try? handle.close()
            group.leave()
        }

        func result() -> Stream {
            lock.lock()
            defer { lock.unlock() }
            return Stream(data: data, truncated: truncated, error: error, complete: !abandoned)
        }
    }

    /// libproc gives us the direct children of an already-running Process.
    /// Walk them before signalling the root so descendants cannot be
    /// re-parented out of reach while still holding our pipe writers open.
    private static func processTree(root: pid_t) -> [pid_t] {
        guard root > 1 else { return [] }
        var seen = Set<pid_t>()
        var childrenFirst = [pid_t]()

        func visit(_ parent: pid_t) {
            var buffer = [pid_t](repeating: 0, count: 1024)
            let count = buffer.withUnsafeMutableBytes { bytes in
                proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
            }
            guard count > 0 else { return }
            for child in buffer.prefix(Int(count)) where child > 1 && seen.insert(child).inserted {
                visit(child)
                childrenFirst.append(child)
            }
        }

        seen.insert(root)
        visit(root)
        childrenFirst.append(root)
        return childrenFirst
    }
}
