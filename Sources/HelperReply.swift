import Foundation

/// One result shared between an XPC reply, its error handler and a bounded wait.
/// Late or duplicate callbacks cannot overwrite the result (including a timeout).
final class HelperReply<Value> {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var completed = false
    private var result: Value?

    func finish(_ value: Value?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Value? {
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finish(nil)
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
