import CCodeCore
import Foundation

/// Why the core did not answer: it refused (`failed`), a Rust panic was caught at the
/// boundary (`panicked`), or an argument was unusable (`invalid`).
public struct CodeCoreError: Error, LocalizedError, Equatable, Sendable {
    public enum Kind: String, Sendable { case failed, panicked, invalid }

    public let kind: Kind
    public let message: String

    public var errorDescription: String? { "code core (\(kind.rawValue)): \(message)" }
}

/// The C calling convention, in one place: every entry point returns a status and writes
/// its answer and an optional message through out parameters.
enum Core {
    /// `CODE_CORE_NONE` as the fields carry it.
    static let none = UInt32(CODE_CORE_NONE)

    /// Run one C call; throw what it reports, freeing its message.
    static func call(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> CodeCoreStatus) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = body(&message)
        defer { code_core_string_free(message) }
        guard status != CODE_CORE_OK else { return }
        let text = message.map { String(cString: $0) } ?? "no message"
        let kind: CodeCoreError.Kind = switch status {
        case CODE_CORE_FAILED: .failed
        case CODE_CORE_PANICKED: .panicked
        default: .invalid
        }
        throw CodeCoreError(kind: kind, message: text)
    }

    /// A question with no failure of its own (a column count, a path's language): a core bug
    /// is logged and answered with `fallback`, the way a lookup that cannot fail reads.
    static func answer<T>(_ what: String, fallback: T, _ body: () throws -> T) -> T {
        do {
            return try body()
        } catch {
            NSLog("code-core: %@ failed: %@", what, error.localizedDescription)
            return fallback
        }
    }

    /// A result's array, empty when it has no elements.
    static func buffer<T>(_ start: UnsafePointer<T>?, _ count: Int) -> UnsafeBufferPointer<T> {
        UnsafeBufferPointer(start: count > 0 ? start : nil, count: count)
    }

    /// The number a field carries, or nil for `CODE_CORE_NONE`.
    static func number(_ value: UInt32) -> Int? {
        value == none ? nil : Int(value)
    }

    /// Many texts at once, for a call taking an array of them: one buffer holds every byte.
    static func withTexts<R>(_ texts: [String], _ body: (UnsafeBufferPointer<CodeCoreStr>) throws -> R) rethrows -> R {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(texts.reduce(0) { $0 + $1.utf8.count })
        var spans: [(offset: Int, count: Int)] = []
        spans.reserveCapacity(texts.count)
        for text in texts {
            spans.append((bytes.count, text.utf8.count))
            bytes.append(contentsOf: text.utf8)
        }
        return try bytes.withUnsafeBufferPointer { all in
            let views = spans.map { span in
                CodeCoreStr(ptr: span.count > 0 ? all.baseAddress.map { $0 + span.offset } : nil, len: span.count)
            }
            return try views.withUnsafeBufferPointer(body)
        }
    }
}

extension String {
    /// The text as the core reads it, for the length of `body`.
    func withCore<R>(_ body: (CodeCoreStr) throws -> R) rethrows -> R {
        var text = self
        return try text.withUTF8 { try body(CodeCoreStr(ptr: $0.baseAddress, len: $0.count)) }
    }
}

extension CodeCoreStr {
    /// A result's text, copied out.
    var string: String {
        String(decoding: Core.buffer(ptr, len), as: UTF8.self)
    }
}
