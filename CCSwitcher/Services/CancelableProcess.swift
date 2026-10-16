import Foundation
import Darwin

/// Owns one CLI invocation; cancellation cannot race past process launch.
final class CancelableProcess: @unchecked Sendable {
    private let process: Process
    private let output: Pipe
    private let lock = NSLock()
    private var cancelled = false

    init(process: Process, output: Pipe) {
        self.process = process
        self.output = output
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            defer { lock.unlock() }
            // Never send a delayed signal to a PID after our child has exited.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func run() throws -> Data {
        try start()
        defer { output.fileHandleForReading.closeFile() }
        let data: Data
        do {
            data = try drainOutput()
        } catch {
            cancel()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        return data
    }

    private func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
    }

    private func drainOutput() throws -> Data {
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            guard errno == EAGAIN else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            lock.lock()
            let stopped = cancelled && !process.isRunning
            lock.unlock()
            // A descendant may retain the pipe. Once our cancelled child exits,
            // drain the buffered bytes without waiting for that descendant's EOF.
            if stopped { return data }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            if poll(&event, 1, 50) == -1 && errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }
}
