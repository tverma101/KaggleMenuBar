import Foundation

/// What a finished command printed and how it ended.
struct ProcessResult: Sendable, Equatable {
    /// The exit status, or the negated signal number when a signal ended it.
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: TimeInterval = 0
    /// The runner stopped the command because it ran past its timeout.
    var timedOut = false

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Runs a command with stdout and stderr read separately and concurrently, so
/// neither pipe can fill and stall the child, and a hard deadline: SIGTERM at
/// the timeout, SIGKILL if it is still running a few seconds later.
enum ProcessRunner {
    static let killGrace: TimeInterval = 3
    /// How long to keep reading after the command exits. A grandchild that
    /// inherited the pipes must not hold the check open.
    static let drainLimit: TimeInterval = 2

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try Task.checkCancellation()
        let execution = ProcessExecution(executable: executable, arguments: arguments)
        let result = try await withTaskCancellationHandler {
            try await execution.run(timeout: timeout)
        } onCancel: {
            execution.stop()
        }
        try Task.checkCancellation()
        return result
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var openStreams = 2
    private var exited = false
    private var timedOut = false
    private var stopRequested = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func run(timeout: TimeInterval) async throws -> ProcessResult {
        let started = ContinuousClock.now
        read(stdoutPipe) { $0.stdoutData.append($1) }
        read(stderrPipe) { $0.stderrData.append($1) }
        process.terminationHandler = { [self] _ in
            lock.withLock { exited = true }
            finishIfDrained()
            // Stop waiting for output a grandchild may be holding open.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ProcessRunner.drainLimit) { [self] in
                finish()
            }
        }
        do {
            // Cancelled before launch: never start the command.
            if lock.withLock({ stopRequested }) { throw CancellationError() }
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let deadline = DispatchWorkItem { [self] in
            lock.withLock { timedOut = true }
            stop()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        await withCheckedContinuation { continuation in
            let alreadyFinished = lock.withLock {
                if finished { return true }
                self.continuation = continuation
                return false
            }
            if alreadyFinished { continuation.resume() }
        }
        deadline.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let status = process.terminationReason == .uncaughtSignal
            ? -process.terminationStatus
            : process.terminationStatus
        let elapsed = ContinuousClock.now - started
        return lock.withLock {
            ProcessResult(
                exitCode: status,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                duration: elapsed.seconds,
                timedOut: timedOut
            )
        }
    }

    /// SIGTERM now, SIGKILL after the grace period if the command ignores it.
    func stop() {
        lock.withLock { stopRequested = true }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ProcessRunner.killGrace) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func read(_ pipe: Pipe, append: @escaping @Sendable (ProcessExecution, Data) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lock.withLock { openStreams -= 1 }
                finishIfDrained()
            } else {
                lock.withLock { append(self, data) }
            }
        }
    }

    private func finishIfDrained() {
        let drained = lock.withLock { exited && openStreams <= 0 }
        if drained { finish() }
    }

    private func finish() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}
