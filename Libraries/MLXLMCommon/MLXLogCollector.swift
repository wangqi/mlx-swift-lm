// Log collector for MLX generation events
// wangqi modified 2026-04-08

import Foundation

/// Thread-safe singleton that receives MLX generation lifecycle events and forwards them
/// to a registered Swift handler.
public final class MLXLogCollector: @unchecked Sendable {
    public static let shared = MLXLogCollector()

    private var _logHandler: ((String) -> Void)?
    private let lock = NSLock()

    private init() {}

    /// Set to receive log messages. May be called from background tasks — do not block.
    public var logHandler: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _logHandler }
        set { lock.lock(); defer { lock.unlock() }; _logHandler = newValue }
    }

    /// Fast check: whether a handler is installed. Zero-cost fast path — skips log call when disabled.
    // wangqi modified 2026-04-08
    public var hasHandler: Bool {
        lock.lock(); defer { lock.unlock() }; return _logHandler != nil
    }

    /// Emit a log message. Zero-cost when no handler is installed:
    /// string interpolation is never evaluated, lock → check nil → unlock → return.
    // wangqi modified 2026-04-08
    public func log(_ message: @autoclosure () -> String) {
        lock.lock()
        let handler = _logHandler
        lock.unlock()
        guard let handler else { return }
        handler(message())
    }
}
